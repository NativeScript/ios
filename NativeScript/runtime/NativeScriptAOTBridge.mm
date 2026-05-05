#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string>
#include <unordered_map>
#include "ArgConverter.h"
#include "Caches.h"
#include "FFICall.h"
#include "Helpers.h"
#include "Interop.h"
#include "MetadataBuilder.h"
#include "NativeScriptAOT.h"

using namespace v8;

namespace tns {

static std::unordered_map<std::string, NSAOTCallHandler>& ExternalAOTHandlers() {
  static std::unordered_map<std::string, NSAOTCallHandler> handlers;
  return handlers;
}

void ExternalAOTTrampoline(const FunctionCallbackInfo<Value>& info) {
  auto handler = reinterpret_cast<NSAOTCallHandler>(
      static_cast<MetadataBuilder::CacheItem<MethodMeta>*>(info.Data().As<External>()->Value())
          ->userData_);
  handler(&info);
}

v8::FunctionCallback GetExternalAOTCall(const char* className, const char* selectorName,
                                        bool isStatic, void** outHandler) {
  auto& handlers = ExternalAOTHandlers();
  std::string key = std::string(className) + "\t" + (isStatic ? "+" : "-") + "\t" + selectorName;
  auto it = handlers.find(key);
  if (it != handlers.end()) {
    if (outHandler) *outHandler = reinterpret_cast<void*>(it->second);
    return ExternalAOTTrampoline;
  }
  return nullptr;
}

void DiscoverExternalAOTStubs() {
  typedef void (*RegistrarFn)(void (*)(const char*, const char*, bool, NSAOTCallHandler));
  auto registrar = reinterpret_cast<RegistrarFn>(dlsym(RTLD_DEFAULT, "__ns_register_aot_calls"));
  if (registrar) {
    registrar(__ns_aot_register);
  }
}

}  // namespace tns

// --- C bridge implementation ---

using tns::BaseDataWrapper;
using tns::ObjCAllocDataWrapper;
using tns::ObjCClassWrapper;
using tns::ObjCDataWrapper;
using tns::WrapperType;

static tns::StructInfo* FindOrCreateStructInfo(const char* structName) {
  tns::StructInfo* cached = tns::FFICall::FindCachedStructInfo(structName);
  if (!cached) {
    const tns::Meta* meta = tns::ArgConverter::GetMeta(structName);
    if (meta && meta->type() == tns::MetaType::Struct) {
      tns::FFICall::GetStructInfo(static_cast<const tns::StructMeta*>(meta), structName);
      cached = tns::FFICall::FindCachedStructInfo(structName);
    }
  }
  return cached;
}

extern "C" {

id __ns_aot_get_target(NSAOTCallInfo _info, bool* outCallSuper) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
  if (wrapper == nullptr) {
    *outCallSuper = false;
    return nil;
  }

  id target = nil;
  *outCallSuper = false;

  if (wrapper->Type() == WrapperType::ObjCAllocObject) {
    target = [static_cast<ObjCAllocDataWrapper*>(wrapper)->Klass() alloc];
  } else if (wrapper->Type() == WrapperType::ObjCObject) {
    target = static_cast<ObjCDataWrapper*>(wrapper)->Data();
    std::string className = object_getClassName(target);
    auto cache = tns::Caches::Get(isolate);
    *outCallSuper = cache->ClassPrototypes.find(className) != cache->ClassPrototypes.end();
  }
  return target;
}

Class __ns_aot_get_static_class(NSAOTCallInfo _info) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  Local<Object> thiz = info.This();
  if (thiz->IsFunction()) {
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper && wrapper->Type() == WrapperType::ObjCClass) {
      return static_cast<ObjCClassWrapper*>(wrapper)->Klass();
    }
  }
  return nil;
}

id __ns_aot_arg_object(NSAOTCallInfo _info, int index) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  Local<Value> arg = info[index];

  if (!arg.IsEmpty() && arg->IsObject()) {
    BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
    if (wrapper) {
      switch (wrapper->Type()) {
        case WrapperType::ObjCObject:
        case WrapperType::ObjCClass:
        case WrapperType::ObjCProtocol:
          break;
        case WrapperType::ObjCAllocObject:
          return [static_cast<ObjCAllocDataWrapper*>(wrapper)->Klass() alloc];
        case WrapperType::Pointer:
          return (id) static_cast<tns::PointerWrapper*>(wrapper)->Data();
        default:
          return nil;
      }
    }
  }

  Local<Context> context = isolate->GetCurrentContext();
  return tns::Interop::ToObject(context, arg);
}

BOOL __ns_aot_arg_bool(NSAOTCallInfo _info, int index) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  return tns::ToBool(info[index]);
}

double __ns_aot_arg_double(NSAOTCallInfo _info, int index) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  return tns::ToNumber(info.GetIsolate(), info[index]);
}

SEL __ns_aot_arg_selector(NSAOTCallInfo _info, int index) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  return sel_registerName(tns::ToString(info.GetIsolate(), info[index]).c_str());
}

Class __ns_aot_arg_class(NSAOTCallInfo _info, int index) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  BaseDataWrapper* wrapper = tns::GetValue(isolate, info[index]);
  if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass) {
    return static_cast<ObjCClassWrapper*>(wrapper)->Klass();
  }
  if (tns::IsString(info[index])) {
    return objc_getClass(tns::ToString(isolate, info[index]).c_str());
  }
  return nil;
}

void __ns_aot_arg_struct(NSAOTCallInfo _info, int index, void* dest, const char* structName) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  tns::StructInfo* cached = FindOrCreateStructInfo(structName);
  if (!cached) return;
  Local<Value> val = info[index];
  if (val.IsEmpty() || !val->IsObject()) return;
  Local<Object> obj = val.As<Object>();
  if (obj->InternalFieldCount() >= 1) {
    Local<Value> field = obj->GetInternalField(0);
    if (!field.IsEmpty() && field->IsExternal()) {
      BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(field.As<External>()->Value());
      if (wrapper && wrapper->Type() == WrapperType::Struct) {
        memcpy(dest, static_cast<tns::StructWrapper*>(wrapper)->Data(), cached->FFIType()->size);
        return;
      }
    }
  }
  tns::Interop::InitializeStruct(context, dest, cached->Fields(), obj);
}

void __ns_aot_return_string(NSAOTCallInfo _info, id value) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  if (value == nil) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  info.GetReturnValue().Set(tns::ToV8String(isolate, (NSString*)value));
}

void __ns_aot_return_id(NSAOTCallInfo _info, id value) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  if (value == nil) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if ([value isKindOfClass:[NSNull class]]) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  if ([value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSMutableString class]]) {
    info.GetReturnValue().Set(tns::ToV8String(isolate, (NSString*)value));
    return;
  }
  if ([value isKindOfClass:[NSNumber class]] && ![value isKindOfClass:[NSDecimalNumber class]]) {
    info.GetReturnValue().Set(Number::New(isolate, [(NSNumber*)value doubleValue]));
    return;
  }
  auto* wrapper = new ObjCDataWrapper(value);
  Local<Value> jsResult = tns::ArgConverter::ConvertArgument(context, wrapper);
  tns::DeleteWrapperIfUnused(isolate, jsResult, wrapper);
  info.GetReturnValue().Set(jsResult);
}

void __ns_aot_return_object(NSAOTCallInfo _info, id value) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  if (value == nil) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  auto* wrapper = new ObjCDataWrapper(value);
  Local<Value> jsResult = tns::ArgConverter::ConvertArgument(context, wrapper);
  tns::DeleteWrapperIfUnused(isolate, jsResult, wrapper);
  info.GetReturnValue().Set(jsResult);
}

void __ns_aot_return_bool(NSAOTCallInfo _info, BOOL value) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  info.GetReturnValue().Set(v8::Boolean::New(info.GetIsolate(), value));
}

void __ns_aot_return_double(NSAOTCallInfo _info, double value) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  info.GetReturnValue().Set(Number::New(info.GetIsolate(), value));
}

void __ns_aot_return_struct(NSAOTCallInfo _info, const void* data, const char* structName) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  tns::StructInfo* cached = FindOrCreateStructInfo(structName);
  if (!cached) {
    info.GetReturnValue().Set(Null(isolate));
    return;
  }
  Local<Value> result =
      tns::Interop::StructToValue(context, const_cast<void*>(data), *cached, nullptr);
  info.GetReturnValue().Set(result);
}

void __ns_aot_throw_exception(NSAOTCallInfo _info, id exception) {
  auto& info = *reinterpret_cast<const FunctionCallbackInfo<Value>*>(_info);
  Isolate* isolate = info.GetIsolate();
  NSString* message = [exception description];
  isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, [message UTF8String])));
}

void __ns_aot_register(const char* className, const char* selector, bool isStatic,
                       NSAOTCallHandler handler) {
  std::string key = std::string(className) + "\t" + (isStatic ? "+" : "-") + "\t" + selector;
  tns::ExternalAOTHandlers()[key] = handler;
}
}
