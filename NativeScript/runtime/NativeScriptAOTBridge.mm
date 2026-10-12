#include <Foundation/Foundation.h>
#include <dlfcn.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>

#include "AOTCalls.h"
#include "ArgConverter.h"
#include "Caches.h"
#include "DataWrapper.h"
#include "FFICall.h"
#include "Helpers.h"
#include "Interop.h"
#include "MetadataBuilder.h"
#include "MethodCallProfiler.h"
#include "NativeScriptAOT.h"
#include "NativeScriptException.h"
#include "Pointer.h"
#include "robin_hood.h"

using namespace v8;

namespace tns::aot {

struct ClassStubs {
  robin_hood::unordered_map<SEL, NSAOTCallHandler> instanceMembers;
  robin_hood::unordered_map<SEL, NSAOTCallHandler> staticMembers;
};

namespace {

using ClassStubsMap =
    std::unordered_map<std::string, ClassStubs, TransparentStringHash, TransparentStringEqual>;

// Written only while DiscoverExternalStubs' call_once runs, read-only after;
// call_once orders those writes before every runtime's template building.
ClassStubsMap& Registry() {
  static auto* registry = new ClassStubsMap();
  return *registry;
}
bool hasStubs = false;

std::mutex registrationMutex;
bool registrationOpen = false;
size_t duplicateRegistrations = 0;
std::string firstDuplicate;

std::atomic<uint64_t> servedCalls{0};
std::atomic<uint64_t> declinedCalls{0};

// What NSAOTCallInfo points to.
struct CallFrame {
  const FunctionCallbackInfo<Value>& info;
  // The method (or property getter) the stub is bound to.
  const MethodMeta* meta;
  // Set at static property getter sites, which always message the declaring
  // class rather than the receiver.
  const std::string* staticGetterClassName;
  // Cursor over meta's parameter encodings, so in-order argument reads walk
  // the encoding list once.
  mutable const TypeEncoding* paramEncoding = nullptr;
  mutable int paramIndex = -1;
};

inline const CallFrame& FrameOf(NSAOTCallInfo callInfo) {
  return *static_cast<const CallFrame*>(callInfo);
}

const TypeEncoding* ParameterEncoding(const CallFrame& frame, int index) {
  const auto* encodings = frame.meta->encodings();
  if (index < 0 || index >= encodings->count - 1) {
    return nullptr;
  }
  if (frame.paramIndex > index || frame.paramEncoding == nullptr) {
    frame.paramEncoding = encodings->first()->next();
    frame.paramIndex = 0;
  }
  while (frame.paramIndex < index) {
    frame.paramEncoding = frame.paramEncoding->next();
    frame.paramIndex++;
  }
  return frame.paramEncoding;
}

// Whether a class's instances must be messaged through objc_msgSendSuper,
// i.e. whether the class is in Caches::ClassPrototypes. ClassBuilder can run
// JS between allocating an extended class and entering it there, so the
// answers are dropped whenever ClassPrototypes grows.
struct AOTState {
  Caches* caches = nullptr;
  size_t classPrototypesSize = 0;
  robin_hood::unordered_map<Class, bool> callSuperByClass;
};

inline bool Dispatch(NSAOTCallHandler handler, const CallFrame& frame) {
  bool handled = handler(&frame);
  if (MethodCallProfiler::IsEnabled()) {
    (handled ? servedCalls : declinedCalls).fetch_add(1, std::memory_order_relaxed);
  }
  return handled;
}

bool Find(const StubScope& scope, bool isStatic, SEL selector, v8::FunctionCallback callback,
          Binding& out) {
  for (const ClassStubs* stubs : scope.classes) {
    const auto& members = isStatic ? stubs->staticMembers : stubs->instanceMembers;
    auto it = members.find(selector);
    if (it != members.end()) {
      out.callback = callback;
      out.handler = reinterpret_cast<void*>(it->second);
      return true;
    }
  }
  return false;
}

}  // namespace

struct Trampolines {
  template <typename T>
  static NSAOTCallHandler HandlerOf(const FunctionCallbackInfo<Value>& info,
                                    MetadataBuilder::CacheItem<T>*& item) {
    item = static_cast<MetadataBuilder::CacheItem<T>*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
    return reinterpret_cast<NSAOTCallHandler>(item->userData_);
  }

  static void Method(const FunctionCallbackInfo<Value>& info) {
    MetadataBuilder::CacheItem<MethodMeta>* item;
    NSAOTCallHandler handler = HandlerOf(info, item);
    if (!Dispatch(handler, CallFrame{info, item->meta_, nullptr}) &&
        !info.GetIsolate()->HasPendingException()) {
      MetadataBuilder::MethodCallback(info);
    }
  }

  static void InstanceGetter(const FunctionCallbackInfo<Value>& info) {
    MetadataBuilder::CacheItem<PropertyMeta>* item;
    NSAOTCallHandler handler = HandlerOf(info, item);
    if (!Dispatch(handler, CallFrame{info, item->meta_->getter(), nullptr}) &&
        !info.GetIsolate()->HasPendingException()) {
      MetadataBuilder::PropertyGetterCallback(info);
    }
  }

  static void StaticGetter(const FunctionCallbackInfo<Value>& info) {
    MetadataBuilder::CacheItem<PropertyMeta>* item;
    NSAOTCallHandler handler = HandlerOf(info, item);
    if (!Dispatch(handler, CallFrame{info, item->meta_->getter(), &item->className_}) &&
        !info.GetIsolate()->HasPendingException()) {
      MetadataBuilder::PropertyNameGetterCallback(info);
    }
  }
};

void DiscoverExternalStubs() {
  static std::once_flag once;
  std::call_once(once, [] {
    using Registrar = void (*)(void (*)(const char*, const char*, bool, NSAOTCallHandler));
    auto registrar = reinterpret_cast<Registrar>(dlsym(RTLD_DEFAULT, "__ns_register_aot_calls"));
    if (registrar == nullptr) {
      return;
    }

    {
      std::lock_guard<std::mutex> lock(registrationMutex);
      registrationOpen = true;
    }
    registrar(Register);
    {
      std::lock_guard<std::mutex> lock(registrationMutex);
      registrationOpen = false;
      if (duplicateRegistrations > 0) {
        Log(@"%zu duplicate AOT stub registration(s) ignored; the first registration wins "
            @"(first duplicate: %s)",
            duplicateRegistrations, firstDuplicate.c_str());
      }
    }
    hasStubs = !Registry().empty();
  });
}

void Register(const char* className, const char* selector, bool isStatic,
              NSAOTCallHandler handler) {
  if (className == nullptr || selector == nullptr || handler == nullptr) {
    return;
  }

  std::lock_guard<std::mutex> lock(registrationMutex);
  if (!registrationOpen) {
    Log(@"AOT stub for %s %c[%s] ignored: stubs register only through __ns_register_aot_calls",
        className, isStatic ? '+' : '-', selector);
    return;
  }

  ClassStubs& stubs = Registry()[className];
  auto& members = isStatic ? stubs.staticMembers : stubs.instanceMembers;
  if (!members.emplace(sel_registerName(selector), handler).second) {
    if (duplicateRegistrations++ == 0) {
      firstDuplicate = std::string(isStatic ? "+[" : "-[") + className + " " + selector + "]";
    }
  }
}

StubScope FindStubScope(const char* className) {
  StubScope scope;
  if (!hasStubs || className == nullptr) {
    return scope;
  }

  const auto& registry = Registry();
  auto add = [&](std::string_view name) {
    auto it = registry.find(name);
    if (it != registry.end()) {
      scope.classes.push_back(&it->second);
    }
  };

  add(className);
  Class klass = objc_getClass(className);
  for (klass = klass != nil ? class_getSuperclass(klass) : nil; klass != nil;
       klass = class_getSuperclass(klass)) {
    add(class_getName(klass));
  }
  return scope;
}

bool FindInstanceMethod(const StubScope& scope, SEL selector, Binding& out) {
  return Find(scope, false, selector, Trampolines::Method, out);
}

bool FindStaticMethod(const StubScope& scope, SEL selector, Binding& out) {
  return Find(scope, true, selector, Trampolines::Method, out);
}

bool FindInstanceGetter(const StubScope& scope, SEL getter, Binding& out) {
  return Find(scope, false, getter, Trampolines::InstanceGetter, out);
}

bool FindStaticGetter(const StubScope& scope, SEL getter, Binding& out) {
  return Find(scope, true, getter, Trampolines::StaticGetter, out);
}

uint64_t ServedCallCount() { return servedCalls.load(std::memory_order_relaxed); }

uint64_t DeclinedCallCount() { return declinedCalls.load(std::memory_order_relaxed); }

namespace {

void ThrowUnexpectedException(Isolate* isolate) {
  isolate->ThrowException(
      Exception::Error(tns::ToV8String(isolate, "Unexpected native error in an AOT call")));
}

bool IsNumeric(BinaryTypeEncodingType type) {
  switch (type) {
    case BinaryTypeEncodingType::BoolEncoding:
    case BinaryTypeEncodingType::UnicharEncoding:
      return true;
    default:
      return Interop::IsNumbericType(type);
  }
}

bool IsPointerSized(BinaryTypeEncodingType type) {
  switch (type) {
    case BinaryTypeEncodingType::IdEncoding:
    case BinaryTypeEncodingType::InterfaceDeclarationReference:
    case BinaryTypeEncodingType::InstanceTypeEncoding:
    case BinaryTypeEncodingType::ProtocolEncoding:
    case BinaryTypeEncodingType::ClassEncoding:
    case BinaryTypeEncodingType::SelectorEncoding:
    case BinaryTypeEncodingType::BlockEncoding:
    case BinaryTypeEncodingType::FunctionPointerEncoding:
    case BinaryTypeEncodingType::PointerEncoding:
    case BinaryTypeEncodingType::CStringEncoding:
    case BinaryTypeEncodingType::IncompleteArrayEncoding:
      return true;
    default:
      return false;
  }
}

bool IsStruct(BinaryTypeEncodingType type) {
  return type == BinaryTypeEncodingType::StructDeclarationReference ||
         type == BinaryTypeEncodingType::AnonymousStructEncoding;
}

// Converts argument `index` with Interop::WriteValue against the parameter's
// declared encoding, exactly as the generic path fills its ffi buffer. `dest`
// must be large enough for that encoding's type.
bool ConvertArgument(NSAOTCallInfo callInfo, int index, bool (*accepts)(BinaryTypeEncodingType),
                     void* dest, BinaryTypeEncodingType* outType) {
  const CallFrame& frame = FrameOf(callInfo);
  Isolate* isolate = frame.info.GetIsolate();
  const TypeEncoding* encoding = ParameterEncoding(frame, index);
  if (encoding == nullptr || !accepts(encoding->type)) {
    std::string message = std::string("AOT stub for ") + frame.meta->selectorAsString() +
                          " read argument " + std::to_string(index) +
                          " with a getter that does not match its declared type";
    isolate->ThrowException(Exception::TypeError(tns::ToV8String(isolate, message)));
    return false;
  }

  try {
    Interop::WriteValue(isolate->GetCurrentContext(), encoding, dest, frame.info[index]);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    return false;
  } catch (...) {
    ThrowUnexpectedException(isolate);
    return false;
  }
  if (outType != nullptr) {
    *outType = encoding->type;
  }
  return !isolate->HasPendingException();
}

template <typename T>
T Widen(BinaryTypeEncodingType type, const void* value) {
  switch (type) {
    case BinaryTypeEncodingType::BoolEncoding:
      return static_cast<T>(*static_cast<const bool*>(value));
    case BinaryTypeEncodingType::CharEncoding:
      return static_cast<T>(*static_cast<const char*>(value));
    case BinaryTypeEncodingType::UCharEncoding:
      return static_cast<T>(*static_cast<const unsigned char*>(value));
    case BinaryTypeEncodingType::ShortEncoding:
      return static_cast<T>(*static_cast<const short*>(value));
    case BinaryTypeEncodingType::UShortEncoding:
      return static_cast<T>(*static_cast<const unsigned short*>(value));
    case BinaryTypeEncodingType::UnicharEncoding:
      return static_cast<T>(*static_cast<const unichar*>(value));
    case BinaryTypeEncodingType::IntEncoding:
      return static_cast<T>(*static_cast<const int*>(value));
    case BinaryTypeEncodingType::UIntEncoding:
      return static_cast<T>(*static_cast<const unsigned int*>(value));
    case BinaryTypeEncodingType::LongEncoding:
      return static_cast<T>(*static_cast<const long*>(value));
    case BinaryTypeEncodingType::ULongEncoding:
      return static_cast<T>(*static_cast<const unsigned long*>(value));
    case BinaryTypeEncodingType::LongLongEncoding:
      return static_cast<T>(*static_cast<const long long*>(value));
    case BinaryTypeEncodingType::ULongLongEncoding:
      return static_cast<T>(*static_cast<const unsigned long long*>(value));
    case BinaryTypeEncodingType::FloatEncoding:
      return static_cast<T>(*static_cast<const float*>(value));
    case BinaryTypeEncodingType::DoubleEncoding:
      return static_cast<T>(*static_cast<const double*>(value));
    default:
      return T();
  }
}

template <typename T>
bool ReadNumber(NSAOTCallInfo callInfo, int index, T* out) {
  alignas(8) uint8_t value[8] = {};
  BinaryTypeEncodingType type;
  if (!ConvertArgument(callInfo, index, IsNumeric, value, &type)) {
    return false;
  }
  *out = Widen<T>(type, value);
  return true;
}

template <typename T>
bool ReadPointer(NSAOTCallInfo callInfo, int index, T* out) {
  void* value = nullptr;
  if (!ConvertArgument(callInfo, index, IsPointerSized, &value, nullptr)) {
    return false;
  }
  *out = (T)value;
  return true;
}

void SetReturnValue(const FunctionCallbackInfo<Value>& info, Local<Value> value) {
  if (!value.IsEmpty()) {
    info.GetReturnValue().Set(value);
  }
}

#ifdef DEBUG
// The generator derives `owned` and `marshalToPrimitive` from the same
// metadata the generic path reads; a mismatch means stale or wrong stubs.
void AssertReturnFlagsMatchMetadata(Isolate* isolate, const MethodMeta* meta, bool owned,
                                    bool marshalToPrimitive) {
  const TypeEncoding* returnEncoding = meta->encodings()->first();
  bool expectedOwned = meta->ownsReturnedCocoaObject() || meta->isInitializer();
  bool expectedMarshal = returnEncoding->type != BinaryTypeEncodingType::InstanceTypeEncoding;
  bool isMutableString =
      returnEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference &&
      std::strcmp(returnEncoding->details.declarationReference.name.valuePtr(),
                  "NSMutableString") == 0;
  bool marshalMatches =
      marshalToPrimitive == expectedMarshal || (isMutableString && !marshalToPrimitive);
  tns::Assert(
      owned == expectedOwned && marshalMatches, isolate,
      std::string("AOT stub return flags disagree with metadata for ") + meta->selectorAsString());
}
#endif

}  // namespace

}  // namespace tns::aot

using namespace tns;
using tns::aot::FrameOf;

extern "C" {

int __ns_aot_arg_count(NSAOTCallInfo callInfo) { return FrameOf(callInfo).info.Length(); }

// Mirrors ArgConverter::Invoke and Interop::CallFunctionInternal for an
// instance receiver.
id __ns_aot_get_target(NSAOTCallInfo callInfo, SEL selector, SEL* outSelector, bool* outCallSuper) {
  *outSelector = selector;
  *outCallSuper = false;

  const auto& info = FrameOf(callInfo).info;
  Local<Object> thiz = info.This();
  if (thiz->InternalFieldCount() < 1) {
    return nil;
  }

  Isolate* isolate = info.GetIsolate();
  BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
    return nil;
  }
  id target = static_cast<ObjCDataWrapper*>(wrapper)->Data();
  if (target == nil) {
    return nil;
  }

  auto* state = Caches::StateFor<aot::AOTState>(isolate);
  if (state == nullptr) {
    return nil;
  }
  if (state->caches == nullptr) {
    state->caches = Caches::Get(isolate).get();
  }
  auto& classPrototypes = state->caches->ClassPrototypes;
  if (classPrototypes.size() != state->classPrototypesSize) {
    state->callSuperByClass.clear();
    state->classPrototypesSize = classPrototypes.size();
  }

  Class klass = object_getClass(target);
  bool callSuper;
  auto it = state->callSuperByClass.find(klass);
  if (it != state->callSuperByClass.end()) {
    callSuper = it->second;
  } else {
    callSuper =
        classPrototypes.find(std::string_view(class_getName(klass))) != classPrototypes.end();
    state->callSuperByClass.emplace(klass, callSuper);
  }

  SEL swizzled = Interop::GetSwizzledMethodSelector(selector);
  if ([target respondsToSelector:swizzled]) {
    *outSelector = swizzled;
  }
  *outCallSuper = callSuper;
  return target;
}

// Mirrors MetadataBuilder::MethodCallback (class from the receiver) and
// PropertyNameGetterCallback (class the property was registered on).
Class __ns_aot_get_static_class(NSAOTCallInfo callInfo) {
  const auto& frame = FrameOf(callInfo);
  if (frame.staticGetterClassName != nullptr) {
    return objc_getClass(frame.staticGetterClassName->c_str());
  }

  Local<Object> thiz = frame.info.This();
  if (!thiz->IsFunction()) {
    return nil;
  }
  BaseDataWrapper* wrapper = tns::GetValue(frame.info.GetIsolate(), thiz);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCClass) {
    return nil;
  }
  return static_cast<ObjCClassWrapper*>(wrapper)->Klass();
}

bool __ns_aot_arg_object(NSAOTCallInfo info, int index, id* out) {
  return aot::ReadPointer(info, index, out);
}

bool __ns_aot_arg_bool(NSAOTCallInfo info, int index, BOOL* out) {
  return aot::ReadNumber(info, index, out);
}

bool __ns_aot_arg_int64(NSAOTCallInfo info, int index, int64_t* out) {
  return aot::ReadNumber(info, index, out);
}

bool __ns_aot_arg_uint64(NSAOTCallInfo info, int index, uint64_t* out) {
  return aot::ReadNumber(info, index, out);
}

bool __ns_aot_arg_double(NSAOTCallInfo info, int index, double* out) {
  return aot::ReadNumber(info, index, out);
}

bool __ns_aot_arg_selector(NSAOTCallInfo info, int index, SEL* out) {
  return aot::ReadPointer(info, index, out);
}

bool __ns_aot_arg_class(NSAOTCallInfo info, int index, Class* out) {
  return aot::ReadPointer(info, index, out);
}

bool __ns_aot_arg_pointer(NSAOTCallInfo info, int index, void** out) {
  return aot::ReadPointer(info, index, out);
}

bool __ns_aot_arg_struct(NSAOTCallInfo info, int index, NSAOTStructType type, void* dest) {
  (void)type;
  return aot::ConvertArgument(info, index, aot::IsStruct, dest, nullptr);
}

void __ns_aot_return_object(NSAOTCallInfo callInfo, id value, bool owned, bool marshalToPrimitive) {
  const auto& frame = FrameOf(callInfo);
  Isolate* isolate = frame.info.GetIsolate();
#ifdef DEBUG
  aot::AssertReturnFlagsMatchMetadata(isolate, frame.meta, owned, marshalToPrimitive);
#endif
  try {
    aot::SetReturnValue(frame.info, Interop::ObjectToJsValue(isolate->GetCurrentContext(), value,
                                                             frame.meta->encodings()->first(),
                                                             marshalToPrimitive, owned, false));
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  } catch (...) {
    aot::ThrowUnexpectedException(isolate);
  }
}

void __ns_aot_return_bool(NSAOTCallInfo callInfo, BOOL value) {
  const auto& info = FrameOf(callInfo).info;
  info.GetReturnValue().Set(v8::Boolean::New(info.GetIsolate(), value));
}

void __ns_aot_return_int64(NSAOTCallInfo callInfo, int64_t value) {
  const auto& info = FrameOf(callInfo).info;
  info.GetReturnValue().Set(Number::New(info.GetIsolate(), static_cast<double>(value)));
}

void __ns_aot_return_uint64(NSAOTCallInfo callInfo, uint64_t value) {
  const auto& info = FrameOf(callInfo).info;
  info.GetReturnValue().Set(Number::New(info.GetIsolate(), static_cast<double>(value)));
}

void __ns_aot_return_double(NSAOTCallInfo callInfo, double value) {
  const auto& info = FrameOf(callInfo).info;
  info.GetReturnValue().Set(Number::New(info.GetIsolate(), value));
}

void __ns_aot_return_selector(NSAOTCallInfo callInfo, SEL value) {
  const auto& info = FrameOf(callInfo).info;
  Isolate* isolate = info.GetIsolate();
  if (value == nullptr) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  info.GetReturnValue().Set(tns::ToV8String(isolate, sel_getName(value)));
}

void __ns_aot_return_class(NSAOTCallInfo callInfo, Class value) {
  const auto& info = FrameOf(callInfo).info;
  Isolate* isolate = info.GetIsolate();
  try {
    aot::SetReturnValue(info, Interop::ClassToJsValue(isolate->GetCurrentContext(), value));
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  } catch (...) {
    aot::ThrowUnexpectedException(isolate);
  }
}

void __ns_aot_return_pointer(NSAOTCallInfo callInfo, void* value) {
  const auto& info = FrameOf(callInfo).info;
  Isolate* isolate = info.GetIsolate();
  if (value == nullptr) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  try {
    aot::SetReturnValue(info, Pointer::NewInstance(isolate->GetCurrentContext(), value));
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  } catch (...) {
    aot::ThrowUnexpectedException(isolate);
  }
}

void __ns_aot_return_struct(NSAOTCallInfo callInfo, NSAOTStructType type, const void* data) {
  const auto& info = FrameOf(callInfo).info;
  Isolate* isolate = info.GetIsolate();
  const auto* structInfo = static_cast<const StructInfo*>(type);
  try {
    aot::SetReturnValue(
        info, Interop::StructToValue(isolate->GetCurrentContext(), const_cast<void*>(data),
                                     *structInfo, nullptr));
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  } catch (...) {
    aot::ThrowUnexpectedException(isolate);
  }
}

NSAOTStructType __ns_aot_struct_type(const char* name) {
  if (name == nullptr) {
    return nullptr;
  }

  try {
    const Meta* meta = ArgConverter::GetMeta(name);
    if (meta == nullptr || meta->type() != MetaType::Struct) {
      return nullptr;
    }
    // The struct-info cache owns each StructInfo for the process lifetime, so
    // its address is a stable handle.
    return &FFICall::GetStructInfo(static_cast<const StructMeta*>(meta));
  } catch (...) {
    return nullptr;
  }
}

// Mirrors the NSException handling in Interop::CallFunctionInternal and its
// rethrow from MetadataBuilder::InvokeMethod.
void __ns_aot_throw_exception(NSAOTCallInfo callInfo, id exception) {
  const auto& info = FrameOf(callInfo).info;
  Isolate* isolate = info.GetIsolate();
  try {
    if (![exception isKindOfClass:[NSException class]]) {
      NativeScriptException(tns::ToString(isolate, [exception description] ?: @"nil"))
          .ReThrowToV8(isolate);
      return;
    }

    std::string message;
    Local<Value> jsError =
        Interop::NSExceptionToJsError(isolate->GetCurrentContext(), exception, message);
    if (jsError.IsEmpty()) {
      NativeScriptException(tns::ToString(isolate, [exception description])).ReThrowToV8(isolate);
    } else {
      NativeScriptException(isolate, jsError, message).ReThrowToV8(isolate);
    }
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  } catch (...) {
    aot::ThrowUnexpectedException(isolate);
  }
}

}  // extern "C"
