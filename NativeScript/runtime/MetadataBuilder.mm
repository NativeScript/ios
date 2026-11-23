#include "MetadataBuilder.h"
#include <Foundation/Foundation.h>
#include <algorithm>
#include "ArgConverter.h"
#include "Caches.h"
#include "Constants.h"
#include "Helpers.h"
#include "InlineFunctions.h"
#include "Interop.h"
#include "LazyGlobals.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "SymbolIterator.h"
#include "SymbolLoader.h"
#include "Tasks.h"
#include "Worker.h"
#include "WrapperLifetime.h"
#include "WrapperLifetimeCanary.h"

using namespace v8;

namespace tns {

namespace {
struct StructTypeEntry {
  StructTypeWrapper* typeWrapper = nullptr;
  std::unique_ptr<Persistent<FunctionTemplate>> ctorTemplate;
  std::unique_ptr<Persistent<v8::Function>> ctor;
};

// Per-isolate struct constructor templates and functions, keyed by the
// process-wide StructInfo (see FFICall.h), whose address is stable for the
// lifetime of the process.
struct StructTypeState {
  robin_hood::unordered_map<const StructInfo*, StructTypeEntry> types;
};

// Swaps a Proxy receiver for the native object at the end of its chain, so the
// call dispatches as if made on that object directly. On failure a TypeError is
// thrown and false returned. `allowClass` admits a class constructor target.
bool ResolveProxyReceiver(Isolate* isolate, Local<Object>& receiver, const char* action,
                          const char* memberName, bool allowClass) {
  if (!receiver->IsProxy()) {
    return true;
  }

  Local<Value> target = tns::UnwrapProxy(receiver);
  const char* reason = nullptr;
  if (target.IsEmpty()) {
    reason = "on a revoked Proxy";
  } else {
    BaseDataWrapper* wrapper = tns::GetValue(isolate, target);
    bool isClass = allowClass && target->IsFunction() && wrapper != nullptr &&
                   wrapper->Type() == WrapperType::ObjCClass;
    bool isInstance = target.As<Object>()->InternalFieldCount() > 0 && wrapper != nullptr &&
                      (wrapper->Type() == WrapperType::ObjCObject ||
                       wrapper->Type() == WrapperType::ObjCAllocObject);
    if (!isClass && !isInstance) {
      if (tns::GetReleasedReason(target) != tns::ReleasedReason::kNone) {
        // A released wrapper: the call reports it the same way as on the
        // target directly.
        receiver = target.As<Object>();
        return true;
      }
      reason = "on a Proxy whose target is not a native object";
    }
  }

  if (reason != nullptr) {
    std::string message = std::string("Cannot ") + action + " '" + memberName + "' " + reason;
    isolate->ThrowException(Exception::TypeError(tns::ToV8String(isolate, message)));
    return false;
  }

  receiver = target.As<Object>();
  return true;
}

// Internal field layout: see StructWrapper. The parent<->view cycle is plain
// JS, so the collector can reclaim it.
constexpr int kStructParentField = StructWrapper::kParentField;
constexpr int kStructFirstViewField = StructWrapper::kFirstViewField;

// Accessor data: the field index in the low 16 bits, the view slot (0 for a
// field that is not a struct) above them.
constexpr int kStructViewSlotShift = 16;
constexpr int32_t kStructFieldIndexMask = (1 << kStructViewSlotShift) - 1;
}  // namespace

// The native property setters a native class's prototype was built with, for
// TrySetNativeProperty. JS can replace one only by defining the name on that
// prototype, which its definer sees, and a name the prototype's own handlers
// see defined or assigned is forgotten for good. A deleted accessor needs no
// such care: the prototype then no longer has the property.
struct NativeSetters {
  struct Entry {
    Global<v8::Name> name;
    MetadataBuilder::CacheItem<PropertyMeta>* item;
  };

  // In the order RegisterInstanceProperties installed them: a later accessor
  // of a name replaces the earlier one on the prototype.
  std::vector<std::pair<std::string, MetadataBuilder::CacheItem<PropertyMeta>*>> installed;
  // By the name's identity hash. Names reaching an interceptor are internalized,
  // so a lookup compares identities.
  robin_hood::unordered_map<int, std::vector<Entry>> byHash;

  Entry* Find(Local<v8::Name> name) {
    auto it = byHash.find(name->GetIdentityHash());
    if (it == byHash.end()) {
      return nullptr;
    }
    for (Entry& entry : it->second) {
      if (entry.name == name) {
        return &entry;
      }
    }
    return nullptr;
  }

  // Moves `installed` into `byHash`, keeping the last accessor of each name.
  void Index(Isolate* isolate) {
    for (const auto& [jsName, item] : installed) {
      Local<v8::Name> name =
          v8::String::NewFromUtf8(isolate, jsName.c_str(), NewStringType::kInternalized)
              .ToLocalChecked();
      MetadataBuilder::CacheItem<PropertyMeta>* setter = item->meta_->hasSetter() ? item : nullptr;
      if (Entry* entry = Find(name)) {
        entry->item = setter;
      } else if (setter != nullptr) {
        byHash[name->GetIdentityHash()].push_back({Global<v8::Name>(isolate, name), setter});
      }
    }
    installed.clear();
    installed.shrink_to_fit();
  }

  void Forget(Isolate* isolate, Local<v8::Name> name) {
    auto it = byHash.find(name->GetIdentityHash());
    if (it == byHash.end()) {
      return;
    }
    for (Entry& entry : it->second) {
      if (entry.name.Get(isolate)->StrictEquals(name)) {
        entry.item = nullptr;
      }
    }
  }
};

namespace {

// Per-isolate: each native class prototype carries its NativeSetters under a
// private key.
struct NativeSetterState {
  Global<Private> key;
  std::vector<std::unique_ptr<NativeSetters>> prototypes;
};

void PublishNativeSetters(Isolate* isolate, Local<Context> context, Local<Object> prototype,
                          std::unique_ptr<NativeSetters> setters) {
  NativeSetterState* state = Caches::StateFor<NativeSetterState>(isolate);
  if (state == nullptr) {
    return;
  }
  if (state->key.IsEmpty()) {
    state->key.Reset(isolate, Private::New(isolate, tns::ToV8String(isolate, "nativeSetters")));
  }
  setters->Index(isolate);
  bool marked = false;
  if (!prototype
           ->SetPrivate(context, state->key.Get(isolate),
                        External::New(isolate, setters.get(), v8::kExternalPointerTypeTagDefault))
           .To(&marked) ||
      !marked) {
    return;
  }
  state->prototypes.push_back(std::move(setters));
}

NativeSetters* NativeSettersOf(Isolate* isolate, Local<Context> context, Local<Object> prototype) {
  NativeSetterState* state = Caches::ExistingStateFor<NativeSetterState>(isolate);
  if (state == nullptr || state->key.IsEmpty()) {
    return nullptr;
  }
  Local<Value> marker;
  if (!prototype->GetPrivate(context, state->key.Get(isolate)).ToLocal(&marker) ||
      !marker->IsExternal()) {
    return nullptr;
  }
  return static_cast<NativeSetters*>(
      marker.As<External>()->Value(v8::kExternalPointerTypeTagDefault));
}

// From a native class prototype's own handlers, which see JS define or assign
// `property` on that prototype.
void ForgetNativeSetter(Isolate* isolate, Local<Object> prototype, Local<v8::Name> property) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  if (NativeSetters* setters = NativeSettersOf(isolate, isolate->GetCurrentContext(), prototype)) {
    setters->Forget(isolate, property);
  }
}

// The property the native member guard is defining on an object whose
// handlers already saw the write: a native class prototype's handlers must
// not swizzle twice, nor take a guard's accessor pair for a native property's.
// Only that object and name: JS the definition runs, such as a Proxy's
// defineProperty trap, can assign other members, which must still swizzle.
class DefiningGuardedMember {
 public:
  DefiningGuardedMember(Isolate* isolate, Local<Object> object, Local<v8::Name> name)
      : isolate_(isolate), object_(object), name_(name), previous_(current_) {
    current_ = this;
  }
  ~DefiningGuardedMember() { current_ = previous_; }

  // The innermost definition is `property` on `holder` itself.
  static bool Defines(Isolate* isolate, Local<Object> holder, Local<v8::Name> property) {
    const DefiningGuardedMember* defining = current_;
    return defining != nullptr && defining->isolate_ == isolate && defining->object_ == holder &&
           defining->name_->StrictEquals(property);
  }

 private:
  static thread_local const DefiningGuardedMember* current_;
  Isolate* isolate_;
  Local<Object> object_;
  Local<v8::Name> name_;
  const DefiningGuardedMember* previous_;
};

thread_local const DefiningGuardedMember* DefiningGuardedMember::current_ = nullptr;

struct NativeMemberGuardState {
  // (function (f) { return function () { return f; }; }): the getter is a JS
  // closure, since an API getter sends `super.m` loads to the slow path.
  Global<v8::Function> getterFactory;
  // Marks the getters MetadataBuilder::GuardNativeCalledMethods installs.
  Global<Private> nativeCalledGetter;
};

NativeMemberGuardState* GuardState(Isolate* isolate, Local<Context> context) {
  NativeMemberGuardState* state = Caches::StateFor<NativeMemberGuardState>(isolate);
  if (state == nullptr || !state->getterFactory.IsEmpty()) {
    return state;
  }
  Local<Script> script;
  Local<Value> factory;
  if (!Script::Compile(context, tns::ToV8String(isolate, "(function (f) { return function () { "
                                                         "return f; }; })"))
           .ToLocal(&script) ||
      !script->Run(context).ToLocal(&factory) || !factory->IsFunction()) {
    return nullptr;
  }
  state->getterFactory.Reset(isolate, factory.As<v8::Function>());
  state->nativeCalledGetter.Reset(isolate, Private::New(isolate));
  return state;
}

std::string DescribeMemberName(Isolate* isolate, Local<v8::Name> name) {
  if (name->IsSymbol()) {
    Local<Value> description = name.As<Symbol>()->Description(isolate);
    return "[" + (description->IsString() ? tns::ToString(isolate, description) : "") + "]";
  }
  return tns::ToString(isolate, name);
}

// A wrapper of a native object, a released one included, or a Proxy or
// `this.super` alias of one.
bool IsNativeObject(Isolate* isolate, Local<Object> receiver) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, receiver);
  return wrapper != nullptr ? wrapper->Type() == WrapperType::ObjCObject ||
                                  wrapper->Type() == WrapperType::ObjCAllocObject
                            : tns::GetReleasedReason(receiver) != ReleasedReason::kNone;
}

// `reason` says why native code never sees the assignment.
void ThrowShadowing(Isolate* isolate, Local<Object> receiver, Local<v8::Name> name,
                    const char* reason) {
  // The JS class name: the native one can be a private class cluster member.
  std::string className;
  Local<Value> target = tns::UnwrapProxy(receiver);
  if (!target.IsEmpty() && target->IsObject()) {
    className = tns::ToString(isolate, target.As<Object>()->GetConstructorName());
  }
  std::string message =
      "Cannot assign '" + DescribeMemberName(isolate, name) + "' on an instance of " + className +
      ": " + reason + " (wrapperLifetime mode \"" +
      WrapperLifetimeModeName(GetWrapperLifetimeMode()) +
      "\", debug builds). Override the method on a class instead (extend() or a subclass), "
      "define a JS-only property with Object.defineProperty, or set \"wrapperLifetime\": { "
      "\"allowShadowingNativeMembers\": true } in the app config.";
  isolate->ThrowException(Exception::TypeError(tns::ToV8String(isolate, message)));
}

// The guard's setter: `info.Data()` is the member's name. An own property on a
// native object never reaches native code, which calls the class's
// implementation, so assigning a native method's name there throws. Any other
// receiver, such as a class prototype (whose handlers have swizzled already)
// or an object inheriting from a native one, gets the own data property an
// ordinary assignment would create.
void NativeMemberGuardSetter(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<v8::Name> name = info.Data().As<v8::Name>();
  Local<Object> receiver = info.This();
  if (IsNativeObject(isolate, receiver)) {
    ThrowShadowing(isolate, receiver, name,
                   "it would shadow the native method for JS callers only, since native code "
                   "never calls JS own properties of a native object");
    return;
  }
  DefiningGuardedMember defining(isolate, receiver, name);
  (void)receiver->CreateDataProperty(isolate->GetCurrentContext(), name,
                                     info.Length() > 0 ? info[0] : v8::Undefined(isolate));
}

// The setter of a JS-extended class's method native code calls
// (GuardNativeCalledMethods): `info.Data()` is the method's name. Native code
// calls the function the class captured when it was built, never an
// instance's own property, so assigning the name on a native object throws.
// Any other receiver, such as a subclass's prototype or an object inheriting
// from an instance, gets the own data property an ordinary assignment would
// create.
void NativeCalledMethodSetter(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<v8::Name> name = info.Data().As<v8::Name>();
  Local<Object> receiver = info.This();
  if (IsNativeObject(isolate, receiver)) {
    ThrowShadowing(isolate, receiver, name,
                   "native code calls the class's implementation of this method, so it would "
                   "never see the instance's own property, which would change the method for JS "
                   "callers only");
    return;
  }
  DefiningGuardedMember defining(isolate, receiver, name);
  (void)receiver->CreateDataProperty(isolate->GetCurrentContext(), name,
                                     info.Length() > 0 ? info[0] : v8::Undefined(isolate));
}

// Turns `prototype`'s own writable, configurable, function-valued data
// property `name` into an accessor pair whose getter returns that same
// function and whose setter is `setter`, with `name` as its data. Keeps the
// property's enumerability; configurable, so an assignment the setter allows
// can replace it. The getter, or empty when `name` is no such property.
Local<v8::Function> GuardMethod(Isolate* isolate, Local<Context> context,
                                NativeMemberGuardState* state, Local<Object> prototype,
                                Local<v8::Name> name, FunctionCallback setter) {
  PropertyAttribute attributes = PropertyAttribute::None;
  Local<Value> method;
  if (!prototype->HasRealNamedProperty(context, name).FromMaybe(false) ||
      prototype->HasRealNamedCallbackProperty(context, name).FromMaybe(true) ||
      !prototype->GetRealNamedPropertyAttributes(context, name).To(&attributes) ||
      (attributes & (ReadOnly | DontDelete)) != 0 ||
      !prototype->GetRealNamedProperty(context, name).ToLocal(&method) || !method->IsFunction()) {
    return Local<v8::Function>();
  }
  Local<Value> getter;
  Local<v8::Function> setterFunction;
  if (!state->getterFactory.Get(isolate)
           ->Call(context, v8::Undefined(isolate), 1, &method)
           .ToLocal(&getter) ||
      !v8::Function::New(context, setter, name, 1, ConstructorBehavior::kThrow)
           .ToLocal(&setterFunction)) {
    return Local<v8::Function>();
  }
  DefiningGuardedMember defining(isolate, prototype, name);
  prototype->SetAccessorProperty(name, getter.As<v8::Function>(), setterFunction,
                                 static_cast<PropertyAttribute>(attributes & DontEnum));
  return getter.As<v8::Function>();
}

// Turns each named own method of a native class prototype, and the symbol
// `iterator` when given, into a guarded accessor pair (GuardMethod).
void GuardNativeMembers(Isolate* isolate, Local<Context> context, Local<Object> prototype,
                        const std::vector<std::string>& names, Local<v8::Name> iterator) {
  NativeMemberGuardState* state = GuardState(isolate, context);
  if (state == nullptr) {
    return;
  }
  for (const std::string& name : names) {
    GuardMethod(isolate, context, state, prototype, tns::ToV8String(isolate, name),
                NativeMemberGuardSetter);
  }
  if (!iterator.IsEmpty()) {
    GuardMethod(isolate, context, state, prototype, iterator, NativeMemberGuardSetter);
  }
}

}  // namespace

void MetadataBuilder::RegisterConstantsOnGlobalObject(Isolate* isolate,
                                                      Local<ObjectTemplate> globalTemplate,
                                                      bool isWorkerThread) {
  GlobalHandlerContext* handlerContext = new GlobalHandlerContext(isWorkerThread);
  Caches::Get(isolate)->registerCacheBoundObject(handlerContext);
  Local<External> ext = External::New(isolate, handlerContext, v8::kExternalPointerTypeTagDefault);

  NamedPropertyHandlerConfiguration config(MetadataBuilder::GlobalPropertyGetter, nullptr, nullptr,
                                           nullptr, nullptr, ext,
                                           PropertyHandlerFlags::kNonMasking);
  globalTemplate->SetHandler(config);
}

v8::Intercepted MetadataBuilder::GlobalPropertyGetter(Local<v8::Name> property,
                                                      const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  std::string propName = tns::ToString(isolate, property);

  GlobalHandlerContext* ctx = static_cast<GlobalHandlerContext*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

  // Decline while this exact name is being defined as an own property below —
  // CreateDataProperty's lookup re-enters this interceptor before the property
  // exists on the global.
  if (ctx->definingProperty_ == propName && !propName.empty()) {
    return v8::Intercepted::kNo;
  }

  if (ctx->isWorkerThread_ &&
      std::find(Worker::GlobalFunctions.begin(), Worker::GlobalFunctions.end(), propName) !=
          Worker::GlobalFunctions.end()) {
    return v8::Intercepted::kNo;
  }

  // Globals the runtime owns: the eager ones inline-functions.js installs and
  // the lazy tier's, which are only accessors until first read and so would
  // otherwise lose the name to a metadata symbol that shares it.
  if (InlineFunctions::IsGlobalFunction(propName) || LazyGlobals::IsLazyGlobal(propName)) {
    return v8::Intercepted::kNo;
  }

  const Meta* meta = ArgConverter::GetMeta(propName);
  if (meta == nullptr || !meta->isAvailable()) {
    return v8::Intercepted::kNo;
  }

  Local<Context> context = isolate->GetCurrentContext();

  if (meta->type() == MetaType::Interface || meta->type() == MetaType::ProtocolType) {
    const BaseClassMeta* classMeta = static_cast<const BaseClassMeta*>(meta);
    Class knownClass = meta->type() == MetaType::Interface ? objc_getClass(meta->name()) : nil;
    KnownUnknownClassPair pair(knownClass);
    MetadataBuilder::GetOrCreateConstructorFunctionTemplate(context, classMeta, pair);

    bool isInterface = meta->type() == MetaType::Interface;
    std::string name = meta->name();
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (isInterface) {
      auto it = cache->CtorFuncs.find(name);
      if (it != cache->CtorFuncs.end()) {
        Local<v8::Function> func = it->second->Get(isolate);
        info.GetReturnValue().Set(func);
      }
    } else {
      auto it = cache->ProtocolCtorFuncs.find(name);
      if (it != cache->ProtocolCtorFuncs.end()) {
        Local<v8::Function> func = it->second->Get(isolate);
        info.GetReturnValue().Set(func);
      }
    }
  } else if (meta->type() == MetaType::Function) {
    auto cache = Caches::Get(isolate);
    std::string funcName = meta->name();
    auto it = cache->CFunctions.find(funcName);
    if (it != cache->CFunctions.end()) {
      Local<v8::Function> func = it->second->Get(isolate);
      info.GetReturnValue().Set(func);
      return v8::Intercepted::kYes;
    }

    const FunctionMeta* funcMeta = static_cast<const FunctionMeta*>(meta);
    void* functionPointer =
        SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
    // Metadata can list functions the running OS or linked binary doesn't export
    // (newer SDK, weak-linked or stripped symbol); expose those as undefined so
    // `typeof fn === "undefined"` works as feature detection.
    if (functionPointer == nullptr) {
      Log(@"Unable to load \"%s\" function", meta->name());
      return v8::Intercepted::kNo;
    }

    CacheItem<FunctionMeta>* item =
        new CacheItem<FunctionMeta>(funcMeta, std::string(), functionPointer);
    Caches::Get(isolate)->registerCacheBoundObject(item);
    Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
    Local<v8::Function> func;
    bool success = v8::Function::New(context, CFunctionCallback, ext).ToLocal(&func);
    tns::Assert(success, isolate);

    tns::SetValue(isolate, func, new FunctionWrapper(funcMeta));
    MetadataBuilder::DefineFunctionLengthProperty(context, funcMeta->encodings(), func);

    auto uniquePersistent = std::make_unique<Persistent<v8::Function>>(isolate, func);
    uniquePersistent->SetWrapperClassId(Constants::ClassTypes::DataWrapper);
    cache->CFunctions.emplace(funcName, std::move(uniquePersistent));

    info.GetReturnValue().Set(func);
  } else if (meta->type() == MetaType::Var) {
    void* dataSymbol =
        SymbolLoader::instance().loadDataSymbol(meta->topLevelModule(), meta->name());
    if (!dataSymbol) {
      return v8::Intercepted::kNo;
    }

    const VarMeta* varMeta = static_cast<const VarMeta*>(meta);

    BaseCall bc((uint8_t*)dataSymbol);
    const TypeEncoding* typeEncoding = varMeta->encoding();
    Local<Value> result = Interop::GetResult(context, typeEncoding, &bc, true);
    info.GetReturnValue().Set(result);
  } else if (meta->type() == MetaType::JsCode) {
    const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
    std::string jsCode = jsCodeMeta->jsCode();
    Local<Script> script;
    if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
      tns::Assert(false, isolate);
    }
    tns::Assert(!script.IsEmpty(), isolate);

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result)) {
      tns::Assert(false, isolate);
    }
    // Memoize the evaluated value as a real own property: the interceptor is
    // registered kNonMasking, so later reads of this global bypass it (and the
    // per-access recompilation of the meta's JS snippet) entirely.
    ctx->definingProperty_ = propName;
    bool memoized =
        context->Global()->CreateDataProperty(context, property, result).FromMaybe(false);
    (void)memoized;
    ctx->definingProperty_.clear();
    info.GetReturnValue().Set(result);
  } else if (meta->type() == MetaType::Struct) {
    const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
    const StructInfo& structInfo = FFICall::GetStructInfo(structMeta);
    Local<v8::Function> structCtorFunc =
        MetadataBuilder::GetOrCreateStructCtorFunction(context, structInfo);
    info.GetReturnValue().Set(structCtorFunc);
  }
  return v8::Intercepted::kYes;
}

Local<v8::Function> MetadataBuilder::GetOrCreateStructCtorFunction(Local<Context> context,
                                                                   const StructInfo& structInfo) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  StructTypeState* state = Caches::StateFor<StructTypeState>(isolate);
  if (state != nullptr) {
    auto it = state->types.find(&structInfo);
    if (it != state->types.end() && it->second.ctor != nullptr) {
      return it->second.ctor->Get(isolate);
    }
  }

  Local<FunctionTemplate> ctorTemplate =
      MetadataBuilder::GetOrCreateStructCtorTemplate(context, structInfo);
  Local<v8::Function> structCtorFunc;
  bool success = ctorTemplate->GetFunction(context).ToLocal(&structCtorFunc);
  tns::Assert(success, isolate);

  StructTypeWrapper* typeWrapper =
      state != nullptr ? state->types[&structInfo].typeWrapper : new StructTypeWrapper(structInfo);
  tns::SetValue(isolate, structCtorFunc, typeWrapper);

  Local<v8::Function> equalsFunc;
  success = v8::Function::New(context, StructEqualsCallback).ToLocal(&equalsFunc);
  tns::Assert(success, isolate);

  success =
      structCtorFunc->Set(context, tns::ToV8String(isolate, "equals"), equalsFunc).FromMaybe(false);
  tns::Assert(success, isolate);

  if (state != nullptr) {
    state->types[&structInfo].ctor =
        std::make_unique<Persistent<v8::Function>>(isolate, structCtorFunc);
  }

  return structCtorFunc;
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateStructCtorTemplate(
    Local<Context> context, const StructInfo& structInfo) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  StructTypeState* state = Caches::StateFor<StructTypeState>(isolate);
  if (state == nullptr) {
    // Teardown has begun: build without caching. Instances created in this
    // window do not share a prototype with earlier ones; only finalizer-driven
    // conversions can reach it.
    return MetadataBuilder::CreateStructCtorTemplate(isolate, new StructTypeWrapper(structInfo));
  }

  auto it = state->types.find(&structInfo);
  if (it != state->types.end() && it->second.ctorTemplate != nullptr) {
    return it->second.ctorTemplate->Get(isolate);
  }

  // Building the template allocates and may run a GC, so no reference into
  // `types` is held across the build.
  StructTypeWrapper* typeWrapper = new StructTypeWrapper(structInfo);
  Local<FunctionTemplate> ctorTemplate =
      MetadataBuilder::CreateStructCtorTemplate(isolate, typeWrapper);
  StructTypeEntry& entry = state->types[&structInfo];
  if (entry.ctorTemplate != nullptr) {
    delete typeWrapper;
    return entry.ctorTemplate->Get(isolate);
  }
  entry.typeWrapper = typeWrapper;
  entry.ctorTemplate = std::make_unique<Persistent<FunctionTemplate>>(isolate, ctorTemplate);
  return ctorTemplate;
}

Local<FunctionTemplate> MetadataBuilder::CreateStructCtorTemplate(Isolate* isolate,
                                                                  StructTypeWrapper* typeWrapper) {
  const StructInfo& structInfo = typeWrapper->StructInfo();
  Local<External> ext = External::New(isolate, typeWrapper, v8::kExternalPointerTypeTagDefault);
  Local<FunctionTemplate> ctorTemplate =
      FunctionTemplate::New(isolate, StructConstructorCallback, ext);
  // Like interface constructors, a struct constructor's prototype can be
  // extended but not replaced.
  ctorTemplate->ReadOnlyPrototype();

  Local<ObjectTemplate> instanceTemplate = ctorTemplate->InstanceTemplate();
  const std::vector<StructField>& fields = structInfo.Fields();
  tns::Assert(fields.size() <= kStructFieldIndexMask, isolate);
  int viewSlots = 0;
  // V8 instantiates template native-data properties in reverse definition
  // order; define them back to front so enumeration follows the C layout.
  for (size_t i = fields.size(); i-- > 0;) {
    const StructField& field = fields[i];
    BinaryTypeEncodingType type = field.Encoding()->type;
    int viewSlot = 0;
    if (type == BinaryTypeEncodingType::StructDeclarationReference ||
        type == BinaryTypeEncodingType::AnonymousStructEncoding) {
      viewSlot = kStructFirstViewField + viewSlots++;
    }
    Local<v8::String> name;
    bool success = v8::String::NewFromUtf8(isolate, field.Name().c_str(),
                                           NewStringType::kInternalized, (int)field.Name().size())
                       .ToLocal(&name);
    tns::Assert(success, isolate);
    int32_t data = static_cast<int32_t>(i) | (viewSlot << kStructViewSlotShift);
    instanceTemplate->SetNativeDataProperty(name, StructFieldGetterCallback,
                                            StructFieldSetterCallback,
                                            v8::Int32::New(isolate, data), DontDelete);
  }
  instanceTemplate->SetInternalFieldCount(kStructFirstViewField + viewSlots);

  return ctorTemplate;
}

StructWrapper* MetadataBuilder::AttachStructStorage(Isolate* isolate, Local<Object> instance,
                                                    const StructInfo& structInfo, void* data,
                                                    StructStorage storage) {
  // Darwin's malloc returns 16-byte-aligned blocks, which simd fields (e.g.
  // simd_float4) need; alignof(max_align_t) is only 8 on arm64.
  constexpr size_t kAlign = 16;
  constexpr size_t kHeaderSize = (sizeof(StructWrapper) + kAlign - 1) & ~(kAlign - 1);

  size_t byteSize = storage == StructStorage::kCopy ? structInfo.FFIType()->size : 0;
  void* block = malloc(kHeaderSize + byteSize);
  void* bytes = static_cast<uint8_t*>(block) + kHeaderSize;
  if (storage == StructStorage::kCopy) {
    if (data != nullptr) {
      memcpy(bytes, data, byteSize);
    } else {
      memset(bytes, 0, byteSize);
    }
  }
  StructWrapper* wrapper =
      new (block) StructWrapper(structInfo, storage == StructStorage::kCopy ? bytes : data);

  std::unique_ptr<BackingStore> backingStore = ArrayBuffer::NewBackingStore(
      block, kHeaderSize + byteSize,
      [](void* data, size_t, void*) {
        static_cast<StructWrapper*>(data)->~StructWrapper();
        free(data);
      },
      nullptr);
  instance->SetInternalField(StructWrapper::kStorageField,
                             ArrayBuffer::New(isolate, std::move(backingStore)));
  tns::SetValue(isolate, instance, wrapper);
  return wrapper;
}

Local<Object> MetadataBuilder::NewStructInstance(Local<Context> context,
                                                 const StructInfo& structInfo, void* data,
                                                 StructStorage storage, Local<Object> parent) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  StructTypeState* state = Caches::StateFor<StructTypeState>(isolate);
  if (state != nullptr) {
    auto it = state->types.find(&structInfo);
    if (it == state->types.end() || it->second.ctor == nullptr) {
      // `instance.constructor` must be the complete constructor (`equals`,
      // type metadata) even before JS has named the struct type.
      MetadataBuilder::GetOrCreateStructCtorFunction(context, structInfo);
    }
  }
  Local<FunctionTemplate> ctorTemplate =
      MetadataBuilder::GetOrCreateStructCtorTemplate(context, structInfo);
  Local<Object> instance;
  bool success = ctorTemplate->InstanceTemplate()->NewInstance(context).ToLocal(&instance);
  tns::Assert(success, isolate);

  MetadataBuilder::AttachStructStorage(isolate, instance, structInfo, data, storage);
  if (!parent.IsEmpty()) {
    instance->SetInternalField(kStructParentField, parent);
  }
  return instance;
}

void MetadataBuilder::StructConstructorCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  try {
    StructTypeWrapper* typeWrapper = static_cast<StructTypeWrapper*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

    const StructInfo& structInfo = typeWrapper->StructInfo();

    Local<Object> result;
    if (info.IsConstructCall()) {
      // A new structure is allocated
      Local<Value> initializer = info.Length() > 0 ? info[0] : Local<Value>();
      // `this` was built from the struct type's instance template.
      result = info.This();
      StructWrapper* wrapper = MetadataBuilder::AttachStructStorage(isolate, result, structInfo,
                                                                    nullptr, StructStorage::kCopy);
      Interop::InitializeStruct(context, wrapper->Data(), structInfo.Fields(), initializer);
    } else {
      // The structure is not used as constructor and in this case we assume a pointer is passed to
      // the function This pointer will be used as backing memory for the structure
      BaseDataWrapper* wrapper = nullptr;
      if (info.Length() < 1 || !(wrapper = tns::GetValue(isolate, info[0])) ||
          wrapper->Type() != WrapperType::Pointer) {
        throw NativeScriptException(
            "A pointer instance must be passed to the structure initializer");
      }

      // The memory stays the pointer's; holding the pointer object keeps it
      // alive as long as the struct object.
      PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
      result = MetadataBuilder::NewStructInstance(context, structInfo, pw->Data(),
                                                  StructStorage::kAlias, info[0].As<Object>());
    }

    info.GetReturnValue().Set(result);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void MetadataBuilder::StructEqualsCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  tns::Assert(info.Length() == 2, isolate);

  Local<Value> value1 = tns::UnwrapProxy(info[0]);
  Local<Value> value2 = tns::UnwrapProxy(info[1]);
  if (value1.IsEmpty() || !value1->IsObject() || value2.IsEmpty() || !value2->IsObject()) {
    info.GetReturnValue().Set(false);
    return;
  }
  Local<Object> arg1 = value1.As<Object>();
  Local<Object> arg2 = value2.As<Object>();

  BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
  if (wrapper == nullptr || wrapper->Type() != WrapperType::StructType) {
    info.GetReturnValue().Set(false);
    return;
  }

  StructTypeWrapper* structTypeWrapper = static_cast<StructTypeWrapper*>(wrapper);
  const StructInfo& structInfo = structTypeWrapper->StructInfo();

  std::pair<ffi_type*, void*> pair1 = MetadataBuilder::GetStructData(context, arg1, structInfo);
  std::pair<ffi_type*, void*> pair2 = MetadataBuilder::GetStructData(context, arg2, structInfo);

  if (pair1.first == nullptr || pair1.second == nullptr || pair2.first == nullptr ||
      pair2.second == nullptr) {
    info.GetReturnValue().Set(false);
    return;
  }

  ffi_type* ffiType1 = pair1.first;
  void* arg1Data = pair1.second;
  void* arg2Data = pair2.second;

  int result = memcmp(arg1Data, arg2Data, ffiType1->size);
  bool areEqual = result == 0;

  // these were created by GetStructData
  if (arg1->InternalFieldCount() < 1) {
    free(arg1Data);
  }
  if (arg2->InternalFieldCount() < 1) {
    free(arg2Data);
  }

  info.GetReturnValue().Set(areEqual);
}

std::pair<ffi_type*, void*> MetadataBuilder::GetStructData(Local<Context> context,
                                                           Local<Object> initializer,
                                                           const StructInfo& structInfo) {
  ffi_type* ffiType = nullptr;
  void* data = nullptr;

  if (initializer->InternalFieldCount() < 1) {
    ffiType = structInfo.FFIType();
    data = malloc(ffiType->size);
    Interop::InitializeStruct(context, data, structInfo.Fields(), initializer);
  } else {
    Isolate* isolate = v8::Isolate::GetCurrent();
    BaseDataWrapper* wrapper = tns::GetValueOrReport(isolate, initializer, "struct initializer");
    if (wrapper == nullptr || wrapper->Type() != WrapperType::Struct) {
      return std::make_pair(ffiType, data);
    }

    StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
    data = structWrapper->Data();
    ffiType = structWrapper->StructInfo().FFIType();
  }

  return std::make_pair(ffiType, data);
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplate(
    Local<Context> context, const BaseClassMeta* meta, KnownUnknownClassPair pair,
    const std::vector<std::string>& additionalProtocols) {
  robin_hood::unordered_map<std::string, uint8_t> instanceMembers;
  robin_hood::unordered_map<std::string, uint8_t> staticMembers;
  return MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(
      context, meta, pair, instanceMembers, staticMembers, additionalProtocols);
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(
    Local<Context> context, const BaseClassMeta* meta, KnownUnknownClassPair pair,
    robin_hood::unordered_map<std::string, uint8_t>& instanceMembers,
    robin_hood::unordered_map<std::string, uint8_t>& staticMembers,
    const std::vector<std::string>& additionalProtocols) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<FunctionTemplate> ctorFuncTemplate;
  auto cache = Caches::Get(isolate);

  if (!additionalProtocols.empty()) {
    return MetadataBuilder::GetOrCreateProtocolBindingTemplate(context, meta, pair,
                                                               additionalProtocols);
  }

  auto cached = cache->CtorFuncTemplates.find(meta);
  if (cached != cache->CtorFuncTemplates.end()) {
    ctorFuncTemplate = cached->second->Get(isolate);
    return ctorFuncTemplate;
  }

  std::string className;
  CacheItem<BaseClassMeta>* item = new CacheItem<BaseClassMeta>(meta, className);
  Caches::Get(isolate)->registerCacheBoundObject(item);
  Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);

  ctorFuncTemplate = FunctionTemplate::New(isolate, ClassConstructorCallback, ext);
  ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
  if (WrapperLifetimeCanary::NativeInstancesIntercept()) {
    WrapperLifetimeCanary::ConfigureInstanceTemplate(ctorFuncTemplate->InstanceTemplate());
  }
  ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, meta->name()));

  Local<v8::Function> baseCtorFunc;

  if (meta->type() == MetaType::Interface) {
    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    const InterfaceMeta* currentMeta = interfaceMeta;
    while (true) {
      const char* baseName = currentMeta->baseName();
      if (baseName != nullptr) {
        const Meta* baseClassMeta = ArgConverter::GetMeta(baseName);
        if (baseClassMeta == nullptr || baseClassMeta->type() != MetaType::Interface) {
          break;
        }

        if (!baseClassMeta->isAvailable()) {
          // Skip base classes that are not available in the current iOS version
          currentMeta = static_cast<const InterfaceMeta*>(baseClassMeta);
          continue;
        }

        const InterfaceMeta* baseMeta = static_cast<const InterfaceMeta*>(baseClassMeta);
        if (baseMeta != nullptr) {
          Local<FunctionTemplate> baseCtorFuncTemplate =
              MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(
                  context, baseMeta, pair, instanceMembers, staticMembers);
          ctorFuncTemplate->Inherit(baseCtorFuncTemplate);
          auto it = cache->CtorFuncs.find(baseMeta->name());
          if (it != cache->CtorFuncs.end()) {
            baseCtorFunc = it->second->Get(isolate);
          }
        }
      }
      break;
    }
  }

  std::unique_ptr<NativeSetters> setters;
  if (GetWrapperLifetimeMode() == WrapperLifetimeMode::kCanary) {
    setters = std::make_unique<NativeSetters>();
  }
  std::vector<std::string> guardedMethods;
  std::vector<std::string>* guarded = GuardsNativeMembers() ? &guardedMethods : nullptr;
  MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, meta, meta->name(), pair,
                                              instanceMembers, setters.get());
  MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, meta, pair, instanceMembers,
                                           guarded);
  MetadataBuilder::RegisterInstanceProtocols(context, ctorFuncTemplate, meta, meta->name(), pair,
                                             instanceMembers, setters.get(), guarded);
  ctorFuncTemplate->PrototypeTemplate()->Set(
      tns::ToV8String(isolate, "toString"),
      FunctionTemplate::New(isolate, MetadataBuilder::ToStringFunctionCallback));
  if (guarded != nullptr) {
    guarded->push_back("toString");
  }
  Local<v8::Name> guardedIterator;
  if (meta->type() == MetaType::Interface && strcmp(meta->name(), "NSArray") == 0) {
    SymbolIterator::Install(isolate, ctorFuncTemplate->PrototypeTemplate());
    if (guarded != nullptr) {
      guardedIterator = Symbol::GetIterator(isolate);
    }
  }

  if (meta->type() == MetaType::Interface) {
    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    MetadataBuilder::RegisterAllocMethod(isolate, ctorFuncTemplate, interfaceMeta);
    ctorFuncTemplate->Set(tns::ToV8String(isolate, "extend"),
                          ClassBuilder::GetExtendFunction(isolate, interfaceMeta));
  }

  NamedPropertyHandlerConfiguration config(nullptr, MetadataBuilder::SwizzledInstanceMethodCallback,
                                           nullptr, nullptr, nullptr,
                                           MetadataBuilder::SwizzledPropertyCallback, nullptr, ext);
  ctorFuncTemplate->PrototypeTemplate()->SetHandler(config);

  Local<v8::Function> ctorFunc;
  bool success = ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc);
  tns::Assert(success, isolate);

  cache->CtorFuncTemplates.emplace(
      meta, std::make_unique<Persistent<FunctionTemplate>>(isolate, ctorFuncTemplate));

  if (meta->type() == MetaType::ProtocolType) {
    const ProtocolMeta* protoMeta = static_cast<const ProtocolMeta*>(meta);
    tns::SetValue(isolate, ctorFunc,
                  new ObjCProtocolWrapper(objc_getProtocol(meta->name()), protoMeta));
    cache->ProtocolCtorFuncs.emplace(meta->name(), new Persistent<v8::Function>(isolate, ctorFunc));
  } else {
    Class klass = objc_getClass(meta->name());
    if (klass == nil) {
      SymbolLoader::instance().ensureModule(meta->topLevelModule());
      klass = objc_getClass(meta->name());
    }
    tns::SetValue(isolate, ctorFunc, new ObjCClassWrapper(klass));
    cache->CtorFuncs.emplace(meta->name(),
                             std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc));
  }
  ObjectManager::Register(context, ctorFunc);

  Local<Value> prototypeValue;
  success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
  tns::Assert(success, isolate);
  Local<Object> prototype = prototypeValue.As<Object>();

  if (guarded != nullptr) {
    GuardNativeMembers(isolate, context, prototype, guardedMethods, guardedIterator);
  }

  Persistent<Value>* poPrototype = new Persistent<Value>(isolate, prototype);
  cache->Prototypes.emplace(meta, poPrototype);
  // Before the constructor is exposed: a JS accessor on the global can run
  // during the Set and redefine prototype members, which must find the tracker.
  if (setters != nullptr) {
    PublishNativeSetters(isolate, context, prototype, std::move(setters));
  }

  Local<Object> global = context->Global();
  auto jsNameV8String = tns::ToV8String(isolate, meta->jsName());
  auto maybeSet = global->Set(context, jsNameV8String, ctorFunc);
  success = maybeSet.FromMaybe(false);
  tns::Assert(success, isolate);

  if (!baseCtorFunc.IsEmpty()) {
    bool success;
    if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
      tns::Assert(false, isolate);
    }
  }

  MetadataBuilder::RegisterStaticMethods(context, ctorFunc, meta, pair, staticMembers);
  MetadataBuilder::RegisterStaticProperties(context, ctorFunc, meta, meta->name(), pair,
                                            staticMembers);
  MetadataBuilder::RegisterStaticProtocols(context, ctorFunc, meta, meta->name(), pair,
                                           staticMembers);

  return ctorFuncTemplate;
}

namespace {

// Keyed by the object's runtime class: optional protocol members are bound
// only when that class implements them.
struct ProtocolBindings {
  struct Binding {
    const BaseClassMeta* meta;
    std::vector<std::string> protocols;
    Global<FunctionTemplate> bindingTemplate;
  };
  robin_hood::unordered_map<Class, std::vector<Binding>> byClass;
};

// The instance members the bindings of `meta`'s class chain are guaranteed to
// have, with the property accessor counts RegisterInstanceProperties compares
// against: a protocol property replaces the class's only where it adds an
// accessor, and a protocol method never replaces one the class chain has.
// Each level is checked against its own class, the one class that every class
// whose wrapping could have built that level's binding descends from.
void CollectInstanceMemberNames(const BaseClassMeta* meta, Class klass, bool ownMembers,
                                robin_hood::unordered_map<std::string, uint8_t>& names) {
  KnownUnknownClassPair pair(klass);
  if (ownMembers) {
    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
      const MethodMeta* methodMeta = (*it).valuePtr();
      if (methodMeta->isAvailableInClasses(pair, false)) {
        names.emplace(methodMeta->name(), 0);
      }
    }
    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
      const PropertyMeta* propMeta = (*it).valuePtr();
      if (!propMeta->isAvailableInClasses(pair, false)) {
        continue;
      }
      uint8_t accessors = (propMeta->hasGetter() ? 1 : 0) + (propMeta->hasSetter() ? 1 : 0);
      if (accessors == 0) {
        continue;
      }
      uint8_t& seen = names[propMeta->name()];
      seen = std::max(seen, accessors);
    }
    for (auto it = meta->protocols->begin(); it != meta->protocols->end(); it++) {
      const Meta* protocolMeta = ArgConverter::GetMeta((*it).valuePtr());
      if (protocolMeta != nullptr && protocolMeta->type() == MetaType::ProtocolType) {
        CollectInstanceMemberNames(static_cast<const BaseClassMeta*>(protocolMeta), klass, true,
                                   names);
      }
    }
  }
  if (meta->type() != MetaType::Interface) {
    return;
  }
  const char* baseName = static_cast<const InterfaceMeta*>(meta)->baseName();
  if (baseName == nullptr) {
    return;
  }
  const Meta* baseMeta = ArgConverter::GetMeta(baseName);
  if (baseMeta != nullptr && baseMeta->type() == MetaType::Interface) {
    // A nil class would count every member as implemented.
    Class baseClass = objc_getClass(baseMeta->name());
    CollectInstanceMemberNames(static_cast<const BaseClassMeta*>(baseMeta),
                               baseClass != nil ? baseClass : klass, baseMeta->isAvailable(),
                               names);
  }
}

}  // namespace

Local<FunctionTemplate> MetadataBuilder::GetOrCreateProtocolBindingTemplate(
    Local<Context> context, const BaseClassMeta* meta, KnownUnknownClassPair pair,
    const std::vector<std::string>& additionalProtocols) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Class runtimeClass = pair.realClass();

  ProtocolBindings* bindings = Caches::StateFor<ProtocolBindings>(isolate);
  auto findBinding = [&]() -> Local<FunctionTemplate> {
    if (bindings != nullptr) {
      auto it = bindings->byClass.find(runtimeClass);
      if (it != bindings->byClass.end()) {
        for (const ProtocolBindings::Binding& binding : it->second) {
          if (binding.meta == meta && binding.protocols == additionalProtocols) {
            return binding.bindingTemplate.Get(isolate);
          }
        }
      }
    }
    return Local<FunctionTemplate>();
  };
  Local<FunctionTemplate> cached = findBinding();
  if (!cached.IsEmpty()) {
    return cached;
  }

  Local<FunctionTemplate> classTemplate =
      MetadataBuilder::GetOrCreateConstructorFunctionTemplate(context, meta, pair);
  // Seeded from the metadata's classes, never the runtime class: a member the
  // class chain's bindings may lack is left to the protocols to bind.
  robin_hood::unordered_map<std::string, uint8_t> names;
  CollectInstanceMemberNames(meta, pair.known, true, names);

  Local<FunctionTemplate> bindingTemplate = FunctionTemplate::New(isolate);
  bindingTemplate->InstanceTemplate()->SetInternalFieldCount(1);
  bindingTemplate->SetClassName(tns::ToV8String(isolate, meta->name()));
  bindingTemplate->Inherit(classTemplate);
  std::vector<std::string> guardedMethods;
  MetadataBuilder::RegisterAdditionalProtocols(context, bindingTemplate, pair, additionalProtocols,
                                               names,
                                               GuardsNativeMembers() ? &guardedMethods : nullptr);

  Local<v8::Function> bindingFunc;
  Local<v8::Function> classFunc;
  Local<Value> prototype;
  bool success = bindingTemplate->GetFunction(context).ToLocal(&bindingFunc) &&
                 classTemplate->GetFunction(context).ToLocal(&classFunc) &&
                 bindingFunc->Get(context, tns::ToV8String(isolate, "prototype"))
                     .ToLocal(&prototype) &&
                 prototype->IsObject();
  tns::Assert(success, isolate);
  // Instances report the class's constructor, which is the one published
  // globally and the one subclasses extend.
  prototype.As<Object>()
      ->DefineOwnProperty(context, tns::ToV8String(isolate, "constructor"), classFunc,
                          PropertyAttribute::DontEnum)
      .FromMaybe(false);
  if (!guardedMethods.empty()) {
    GuardNativeMembers(isolate, context, prototype.As<Object>(), guardedMethods, Local<v8::Name>());
  }

  // Building the class's binding can wrap objects of this class first.
  cached = findBinding();
  if (!cached.IsEmpty()) {
    return cached;
  }
  if (bindings != nullptr) {
    bindings->byClass[runtimeClass].push_back(ProtocolBindings::Binding{
        meta, additionalProtocols, Global<FunctionTemplate>(isolate, bindingTemplate)});
  }
  return bindingTemplate;
}

void MetadataBuilder::ToStringFunctionCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> thiz = info.This();
  if (!ResolveProxyReceiver(isolate, thiz, "call native method", "toString", false)) {
    return;
  }
  BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);

  if (wrapper == nullptr) {
    tns::ReleasedReason releasedReason = tns::GetReleasedReason(thiz);
    if (releasedReason != tns::ReleasedReason::kNone) {
      // String coercion (logging, template literals) still gets a string under
      // the report policy.
      if (tns::ReportReleasedObject(isolate, thiz, releasedReason, "toString receiver", true)) {
        std::string name = tns::ToString(isolate, thiz->GetConstructorName());
        info.GetReturnValue().Set(tns::ToV8String(isolate, "[released " + name + "]"));
      }
      return;
    }
  }

  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
    info.GetReturnValue().Set(thiz);
    return;
  }

  ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
  id target = dataWrapper->Data();
  if (target == nil) {
    info.GetReturnValue().Set(thiz);
    return;
  }

  Local<v8::String> returnValue = tns::ToV8String(info.GetIsolate(), [target description]);
  info.GetReturnValue().Set(returnValue);
}

void MetadataBuilder::RegisterAllocMethod(Isolate* isolate,
                                          Local<FunctionTemplate> ctorFuncTemplate,
                                          const InterfaceMeta* interfaceMeta) {
  std::string className;
  CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, className);
  Caches::Get(isolate)->registerCacheBoundObject(item);
  Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
  Local<FunctionTemplate> allocFuncTemplate = FunctionTemplate::New(isolate, AllocCallback, ext);
  ctorFuncTemplate->Set(tns::ToV8String(isolate, "alloc"), allocFuncTemplate);
}

void MetadataBuilder::RegisterInstanceMethods(
    Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta,
    KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names,
    std::vector<std::string>* guarded) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

  for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
    const MethodMeta* methodMeta = (*it).valuePtr();
    if (!methodMeta->isAvailableInClasses(pair, false)) {
      continue;
    }

    std::string methodName = methodMeta->name();
    auto methodsIt = names.find(methodName);
    if (methodsIt == names.end()) {
      CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name());
      Caches::Get(isolate)->registerCacheBoundObject(item);
      Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
      Local<FunctionTemplate> instanceMethodTemplate =
          FunctionTemplate::New(isolate, MethodCallback, ext);
      proto->Set(tns::ToV8String(isolate, methodMeta->jsName()), instanceMethodTemplate);
      if (guarded != nullptr) {
        guarded->push_back(methodMeta->jsName());
      }
      names.emplace(methodName, 0);
    }
  }
}

void MetadataBuilder::RegisterInstanceProperties(
    Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta,
    const std::string className, KnownUnknownClassPair pair,
    robin_hood::unordered_map<std::string, uint8_t>& names, NativeSetters* setters) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

  for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
    const PropertyMeta* propMeta = (*it).valuePtr();
    if (!propMeta->isAvailableInClasses(pair, false)) {
      continue;
    }

    uint8_t accessors = 0;
    if (propMeta->hasGetter()) {
      accessors++;
    }
    if (propMeta->hasSetter()) {
      accessors++;
    }

    std::string propertyName = propMeta->name();
    auto propertiesIt = names.find(propertyName);
    if (accessors > 0 && (propertiesIt == names.end() || propertiesIt->second < accessors)) {
      CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className);
      Caches::Get(isolate)->registerCacheBoundObject(item);
      Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
      Local<FunctionTemplate> getter = FunctionTemplate::New(isolate, PropertyGetterCallback, ext);
      Local<FunctionTemplate> setter = FunctionTemplate::New(isolate, PropertySetterCallback, ext);
      proto->SetAccessorProperty(tns::ToV8String(isolate, propMeta->jsName()), getter, setter,
                                 PropertyAttribute::None);
      if (setters != nullptr) {
        setters->installed.emplace_back(propMeta->jsName(), item);
      }
      names.emplace(propertyName, accessors);
    }
  }
}

void MetadataBuilder::RegisterInstanceProtocols(
    Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta,
    const std::string className, KnownUnknownClassPair pair,
    robin_hood::unordered_map<std::string, uint8_t>& names, NativeSetters* setters,
    std::vector<std::string>* guarded) {
  if (meta->type() == MetaType::ProtocolType) {
    MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, meta, pair, names, guarded);
    MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, meta, className, pair,
                                                names, setters);
  }

  for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
    std::string protocolName = (*itProto).valuePtr();
    const Meta* m = ArgConverter::GetMeta(protocolName.c_str());
    if (m != nullptr) {
      const BaseClassMeta* protoMeta = static_cast<const BaseClassMeta*>(m);
      MetadataBuilder::RegisterInstanceProtocols(context, ctorFuncTemplate, protoMeta, className,
                                                 pair, names, setters, guarded);
    }
  }
}

void MetadataBuilder::RegisterAdditionalProtocols(
    Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, KnownUnknownClassPair pair,
    const std::vector<std::string>& additionalProtocols,
    robin_hood::unordered_map<std::string, uint8_t>& names, std::vector<std::string>* guarded) {
  for (std::string protocolName : additionalProtocols) {
    const Meta* meta = ArgConverter::GetMeta(protocolName.c_str());
    if (meta != nullptr) {
      const BaseClassMeta* baseMeta = static_cast<const BaseClassMeta*>(meta);
      MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, baseMeta, pair, names,
                                               guarded);
      MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, baseMeta,
                                                  baseMeta->name(), pair, names);

      std::vector<std::string> metaProtocols;
      for (auto it = baseMeta->protocols->begin(); it != baseMeta->protocols->end(); it++) {
        std::string name = (*it).valuePtr();
        metaProtocols.push_back(name);
      }

      MetadataBuilder::RegisterAdditionalProtocols(context, ctorFuncTemplate, pair, metaProtocols,
                                                   names, guarded);
    }
  }
}

void MetadataBuilder::RegisterStaticMethods(
    Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta,
    KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  for (auto it = meta->staticMethods->begin(); it != meta->staticMethods->end(); it++) {
    const MethodMeta* methodMeta = (*it).valuePtr();
    if (!methodMeta->isAvailableInClasses(pair, true)) {
      continue;
    }

    std::string methodName = methodMeta->name();
    auto methodsIt = names.find(methodName);
    if (methodsIt == names.end()) {
      CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name());
      Caches::Get(isolate)->registerCacheBoundObject(item);
      Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
      Local<FunctionTemplate> staticMethodTemplate =
          FunctionTemplate::New(isolate, MethodCallback, ext);
      Local<v8::Function> staticMethod;
      if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
        tns::Assert(false, isolate);
      }

      DefineFunctionLengthProperty(context, methodMeta->encodings(), staticMethod);

      if (!ctorFunc->Has(context, tns::ToV8String(isolate, methodMeta->jsName())).FromJust()) {
        bool success =
            ctorFunc->Set(context, tns::ToV8String(isolate, methodMeta->jsName()), staticMethod)
                .FromMaybe(false);
        tns::Assert(success, isolate);
      }

      names.emplace(methodName, 0);
    }
  }
}

void MetadataBuilder::RegisterStaticProperties(
    Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta,
    const std::string className, KnownUnknownClassPair pair,
    robin_hood::unordered_map<std::string, uint8_t>& names) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  for (auto it = meta->staticProps->begin(); it != meta->staticProps->end(); it++) {
    const PropertyMeta* propMeta = (*it).valuePtr();
    if (!propMeta->isAvailableInClasses(pair, true)) {
      continue;
    }

    uint8_t accessors = 0;
    if (propMeta->hasGetter()) {
      accessors++;
    }

    if (propMeta->hasSetter()) {
      accessors++;
    }

    std::string propertyName = propMeta->name();
    auto propertiesIt = names.find(propertyName);
    if (accessors > 0 && (propertiesIt == names.end() || propertiesIt->second < accessors)) {
      CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className);
      Caches::Get(isolate)->registerCacheBoundObject(item);
      Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);

      Local<v8::String> propName = tns::ToV8String(isolate, propMeta->jsName());
      // A real accessor pair, not SetNativeDataProperty: a derived class
      // inherits this from the base constructor, and assigning through the
      // derived one must reach the setter instead of shadowing it with an own
      // data property.
      Local<v8::Function> propGetter;
      Local<v8::Function> propSetter;
      if (!FunctionTemplate::New(isolate, PropertyNameGetterCallback, ext)
               ->GetFunction(context)
               .ToLocal(&propGetter) ||
          !FunctionTemplate::New(isolate, PropertyNameSetterCallback, ext)
               ->GetFunction(context)
               .ToLocal(&propSetter)) {
        tns::Assert(false, isolate);
      }
      ctorFunc->SetAccessorProperty(propName, propGetter, propSetter,
                                    PropertyAttribute::DontDelete);
      names.emplace(propertyName, accessors);
    }
  }
}

void MetadataBuilder::RegisterStaticProtocols(
    Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta,
    const std::string className, KnownUnknownClassPair pair,
    robin_hood::unordered_map<std::string, uint8_t>& names) {
  if (meta->type() == MetaType::ProtocolType) {
    MetadataBuilder::RegisterStaticMethods(context, ctorFunc, meta, pair, names);
    MetadataBuilder::RegisterStaticProperties(context, ctorFunc, meta, className, pair, names);
  }

  const GlobalTable<GlobalTableType::ByJsName>* globalTable = MetaFile::instance()->globalTableJs();
  for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
    std::string protocolName = (*itProto).valuePtr();
    const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());
    if (protoMeta != nullptr) {
      MetadataBuilder::RegisterStaticProtocols(context, ctorFunc, protoMeta, className, pair,
                                               names);
    }
  }
}

void MetadataBuilder::ClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  tns::Assert(info.IsConstructCall(), isolate);
  try {
    CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
    Class klass = objc_getClass(item->meta_->name());

    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(item->meta_);
    ArgConverter::ConstructObject(context, info, klass, interfaceMeta,
                                  WrapperLifetimeCanary::NativeInstancesIntercept());
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  tns::Assert(info.Length() == 0, isolate);

  try {
    Local<Object> thiz = info.This();
    Class klass;

    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass) {
      ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
      klass = classWrapper->Klass();
    } else {
      CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(
          info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
      const InterfaceMeta* meta = item->meta_;
      klass = objc_getClass(meta->name());
    }

    Local<Context> context = isolate->GetCurrentContext();
    ObjCAllocDataWrapper* allocWrapper = new ObjCAllocDataWrapper(klass);
    Local<Value> result = ArgConverter::CreateJsWrapper(context, allocWrapper, Local<Object>());
    info.GetReturnValue().Set(result);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  CacheItem<MethodMeta>* item = static_cast<CacheItem<MethodMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

  Local<Object> thiz = info.This();
  if (!ResolveProxyReceiver(isolate, thiz, "call native method", item->meta_->jsName(), true)) {
    return;
  }

  bool instanceMethod = thiz->InternalFieldCount() > 0;
  V8FunctionCallbackArgs args(info);

  // A class-side call through a subclass constructor targets that subclass,
  // not the class the metadata item was registered for.
  Class klass = item->ResolveClass();

  if (thiz->IsFunction()) {
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass) {
      ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
      klass = classWrapper->Klass();
    }
  }

  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result =
      instanceMethod
          ? MetadataBuilder::InvokeMethod(context, item->meta_, thiz, args, klass, true)
          : MetadataBuilder::InvokeMethod(context, item->meta_, Local<Object>(), args, klass, true);

  if (!result.IsEmpty()) {
    info.GetReturnValue().Set(result);
  }
}

void MetadataBuilder::PropertyGetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  Local<Object> receiver = info.This();
  if (!ResolveProxyReceiver(isolate, receiver, "read native property", item->meta_->jsName(),
                            false)) {
    return;
  }

  if (receiver->InternalFieldCount() < 1) {
    return;
  }

  if (!item->meta_->hasGetter()) {
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Property is not readable."));
    isolate->ThrowException(error);
    return;
  }

  V8EmptyValueArgs args;
  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result = MetadataBuilder::InvokeMethod(context, item->meta_->getter(), receiver,
                                                      args, item->ResolveClass(), true);
  if (!result.IsEmpty()) {
    info.GetReturnValue().Set(result);
  }
}

void MetadataBuilder::PropertySetterCallback(const FunctionCallbackInfo<Value>& info) {
  CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  SetNativeProperty(info.GetIsolate(), item, info.This(), info[0]);
}

void MetadataBuilder::SetNativeProperty(Isolate* isolate, CacheItem<PropertyMeta>* item,
                                        Local<Object> receiver, Local<Value> value) {
  if (!item->meta_->hasSetter()) {
    Local<Value> error =
        Exception::Error(tns::ToV8String(isolate, "Attempted to assign to readonly property."));
    isolate->ThrowException(error);
    return;
  }

  if (!ResolveProxyReceiver(isolate, receiver, "set native property", item->meta_->jsName(),
                            false)) {
    return;
  }
  V8SimpleValueArgs args(value);
  Local<Context> context = isolate->GetCurrentContext();
  MetadataBuilder::InvokeMethod(context, item->meta_->setter(), receiver, args,
                                item->ResolveClass(), true);
}

void MetadataBuilder::GuardNativeCalledMethods(Local<Context> context, Local<Object> prototype,
                                               const std::vector<std::string>& names,
                                               bool iterator) {
  if (!GuardsNativeMembers()) {
    return;
  }
  Isolate* isolate = v8::Isolate::GetCurrent();
  HandleScope scope(isolate);
  NativeMemberGuardState* state = GuardState(isolate, context);
  if (state == nullptr) {
    return;
  }
  Local<Private> marker = state->nativeCalledGetter.Get(isolate);
  auto guard = [&](Local<v8::Name> name) {
    Local<v8::Function> getter =
        GuardMethod(isolate, context, state, prototype, name, NativeCalledMethodSetter);
    if (!getter.IsEmpty()) {
      (void)getter->SetPrivate(context, marker, v8::True(isolate));
    }
  };
  for (const std::string& name : names) {
    guard(tns::ToV8String(isolate, name));
  }
  if (iterator) {
    guard(Symbol::GetIterator(isolate));
  }
}

Local<Value> MetadataBuilder::GuardedNativeCalledMethod(Local<Context> context,
                                                        Local<Value> getter) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  NativeMemberGuardState* state = Caches::ExistingStateFor<NativeMemberGuardState>(isolate);
  Local<Value> marked;
  Local<Value> method;
  if (state == nullptr || state->nativeCalledGetter.IsEmpty() || !getter->IsFunction() ||
      !getter.As<Object>()
           ->GetPrivate(context, state->nativeCalledGetter.Get(isolate))
           .ToLocal(&marked) ||
      !marked->IsTrue() ||
      !getter.As<v8::Function>()
           ->Call(context, v8::Undefined(isolate), 0, nullptr)
           .ToLocal(&method)) {
    return Local<Value>();
  }
  return method;
}

bool MetadataBuilder::TrySetNativeProperty(Isolate* isolate, Local<Context> context,
                                           Local<Object> owner, Local<v8::Name> property,
                                           Local<Object> receiver, Local<Value> value) {
  NativeSetters* setters = NativeSettersOf(isolate, context, owner);
  if (setters == nullptr) {
    return false;
  }
  NativeSetters::Entry* entry = setters->Find(property);
  if (entry == nullptr || entry->item == nullptr) {
    return false;
  }
  SetNativeProperty(isolate, entry->item, receiver, value);
  return true;
}

void MetadataBuilder::PropertyNameGetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  if (!item->meta_->hasGetter()) {
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Property is not readable."));
    isolate->ThrowException(error);
    return;
  }

  V8EmptyValueArgs args;
  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result = MetadataBuilder::InvokeMethod(
      context, item->meta_->getter(), Local<Object>(), args, item->ResolveClass(), false);
  if (!result.IsEmpty()) {
    info.GetReturnValue().Set(result);
  }
}

void MetadataBuilder::PropertyNameSetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> value = info[0];
  CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  if (!item->meta_->hasSetter()) {
    Local<Value> error =
        Exception::Error(tns::ToV8String(isolate, "Attempted to assign to readonly property."));
    isolate->ThrowException(error);
    return;
  }

  V8SimpleValueArgs args(value);
  Local<Context> context = isolate->GetCurrentContext();
  MetadataBuilder::InvokeMethod(context, item->meta_->setter(), Local<Object>(), args,
                                item->ResolveClass(), false);
}

void MetadataBuilder::StructFieldGetterCallback(Local<v8::Name> property,
                                                const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> thiz = info.Holder();
  int32_t data = info.Data().As<v8::Int32>()->Value();
  int viewSlot = data >> kStructViewSlotShift;

  if (viewSlot != 0) {
    Local<Data> cached = thiz->GetInternalField(viewSlot);
    if (cached->IsValue() && cached.As<Value>()->IsObject()) {
      info.GetReturnValue().Set(cached.As<Value>());
      return;
    }
  }

  BaseDataWrapper* baseWrapper = tns::GetValueOrReport(isolate, thiz, "struct property get");
  if (baseWrapper == nullptr) {
    info.GetReturnValue().SetUndefined();
    return;
  }
  tns::Assert(baseWrapper->Type() == WrapperType::Struct, isolate);
  StructWrapper* wrapper = static_cast<StructWrapper*>(baseWrapper);

  const StructField& field = wrapper->StructInfo().Fields()[data & kStructFieldIndexMask];
  BaseCall call((uint8_t*)wrapper->Data(), field.Offset());

  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result = Interop::GetResult(context, field.Encoding(), &call, false,
                                           viewSlot != 0 ? thiz : Local<Object>(), true);
  if (viewSlot != 0) {
    thiz->SetInternalField(viewSlot, result);
  }

  info.GetReturnValue().Set(result);
}

void MetadataBuilder::StructFieldSetterCallback(Local<v8::Name> property, Local<Value> value,
                                                const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> thiz = info.Holder();
  int32_t data = info.Data().As<v8::Int32>()->Value();

  BaseDataWrapper* baseWrapper = tns::GetValueOrReport(isolate, thiz, "struct property set");
  if (baseWrapper == nullptr) {
    return;
  }
  tns::Assert(baseWrapper->Type() == WrapperType::Struct, isolate);
  StructWrapper* wrapper = static_cast<StructWrapper*>(baseWrapper);

  const StructField& field = wrapper->StructInfo().Fields()[data & kStructFieldIndexMask];
  try {
    Interop::SetStructPropertyValue(isolate->GetCurrentContext(), wrapper, field, value);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void MetadataBuilder::DefineFunctionLengthProperty(Local<Context> context,
                                                   const TypeEncodingsList<ArrayCount>* encodings,
                                                   Local<v8::Function> func) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(
      PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  int paramsCount = std::max(0, encodings->count - 1);
  bool success = func->DefineOwnProperty(context, tns::ToV8String(isolate, "length"),
                                         Number::New(isolate, paramsCount), readOnlyFlags)
                     .FromMaybe(false);
  tns::Assert(success, isolate);
}

Local<Value> MetadataBuilder::InvokeMethod(Local<Context> context, const MethodMeta* meta,
                                           Local<Object> receiver, V8Args& args, Class klass,
                                           bool isMethodCallback) {
  // TODO: Find out if the isMethodCallback property can be determined based on a
  // UITableViewController.prototype.viewDidLoad.call(this) or super.viewDidLoad() call

#ifdef DEBUG
  id value = Runtime::GetAppConfigValue("logRuntimeDetail");
  bool logRuntimeDetail = value ? [value boolValue] : false;
  if (logRuntimeDetail) {
    // NOTE: stringWithFormat is slow, perhaps use different c string concatenation?
    NSString* message = [NSString
        stringWithFormat:@"MetadataBuilder::InvokeMethod: class {%s}, selector {%s}, "
                         @"isInitializer {%s}, type {%s}, lib {%s}",
                         klass ? class_getName(klass) : "<unknown>", meta->selectorAsString(),
                         meta->isInitializer() ? "true" : "false", meta->typeName(),
                         meta->topLevelModule()->getName()];
    Log(@"%@", message);
  }
#endif

  try {
    return ArgConverter::Invoke(context, klass, receiver, args, meta, isMethodCallback);
  } catch (NativeScriptException& ex) {
    Isolate* isolate = v8::Isolate::GetCurrent();
    ex.ReThrowToV8(isolate);
    return Local<Value>();
  }
}

void MetadataBuilder::CFunctionCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  try {
    CacheItem<FunctionMeta>* item = static_cast<CacheItem<FunctionMeta>*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

    if (strcmp(item->meta_->jsName(), "UIApplicationMain") == 0) {
      std::vector<std::shared_ptr<Persistent<Value>>> args;
      for (int i = 0; i < info.Length(); i++) {
        args.push_back(std::make_shared<Persistent<Value>>(isolate, info[i]));
      }

      Tasks::Register([isolate, item, args]() {
        v8::Locker locker(isolate);
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        std::vector<Local<Value>> localArgs;
        localArgs.reserve(args.size());
        for (int i = 0; i < args.size(); i++) {
          Local<Value> arg = args[i]->Get(isolate);
          localArgs.push_back(arg);
        }
        const TypeEncoding* typeEncoding = item->meta_->encodings()->first();
        V8VectorArgs vectorArgs(localArgs);
        Local<Context> context = Caches::Get(isolate)->GetContext();
        v8::Unlocker unlocker(isolate);
        CMethodCall methodCall(context, item->userData_, typeEncoding, vectorArgs,
                               item->meta_->ownsReturnedCocoaObject(), false);
        Interop::CallFunction(methodCall);
      });

      return;
    }

    V8FunctionCallbackArgs args(info);
    const TypeEncoding* typeEncoding = item->meta_->encodings()->first();
    Local<Context> context = isolate->GetCurrentContext();
    const FunctionMeta* funcMeta = item->meta_;
    CMethodCall methodCall(context, item->userData_, typeEncoding, args,
                           funcMeta->ownsReturnedCocoaObject(), funcMeta->returnsUnmanaged());
    Local<Value> result = Interop::CallFunction(methodCall);

    if (typeEncoding->type != BinaryTypeEncodingType::VoidEncoding) {
      info.GetReturnValue().Set(result);
    }
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

namespace {

// The native implementation `klass` answered `selector` with stays reachable
// under the swizzled-prefixed selector that native calls from JS prefer. A
// class that only inherits `selector` below a replaced ancestor takes that
// ancestor's alias: its selector resolves to the ancestor's JS replacement,
// and an alias naming a native override in between would be re-entered when
// that override calls super. Every replaced class gets an alias of its own,
// which a later replacement keeps, so it never names an earlier replacement.
void ReplaceKeepingOriginal(Class klass, SEL selector, const char* selectorName, IMP imp,
                            const char* types) {
  SEL alias = sel_registerName((Constants::SwizzledPrefix + selectorName).c_str());
  bool inheritsAlias =
      !ClassBuilder::ImplementsItself(klass, selector) && class_respondsToSelector(klass, alias);
  Method method = class_getInstanceMethod(klass, inheritsAlias ? alias : selector);
  IMP original = method != nullptr ? method_getImplementation(method) : nullptr;
  class_replaceMethod(klass, selector, WrapperLifetimeCanary::WrapDealloc(selector, imp), types);
  if (original != nullptr) {
    class_addMethod(klass, alias, original, types);
  }
}

}  // namespace

v8::Intercepted MetadataBuilder::SwizzledInstanceMethodCallback(
    Local<v8::Name> property, Local<Value> value, const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  if (DefiningGuardedMember::Defines(isolate, info.Holder(), property)) {
    return v8::Intercepted::kNo;
  }
  ForgetNativeSetter(isolate, info.Holder(), property);
  std::string methodName = tns::ToString(isolate, property);

  CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  const BaseClassMeta* meta = item->meta_;

  Class klass = objc_getClass(meta->name());
  if (klass == nil) {
    return v8::Intercepted::kNo;
  }

  int index = meta->instanceMethods->binarySearch([methodName](const PtrTo<MethodMeta>& current) {
    const MethodMeta* methodMeta = current.valuePtr();
    return strcmp(methodMeta->jsName(), methodName.c_str());
  });

  if (index < 0) {
    return v8::Intercepted::kNo;
  }

  const MethodMeta* methodMeta = meta->instanceMethods->operator[](index).valuePtr();

  const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
  int argsCount = methodMeta->encodings()->count - 1;
  std::string compilerEncoding = ClassBuilder::GetTypeEncoding(typeEncoding, argsCount);
  std::shared_ptr<Persistent<Value>> poCallback =
      std::make_shared<Persistent<Value>>(isolate, value);
  MethodCallbackWrapper* userData = new MethodCallbackWrapper(
      isolate, poCallback, 2, argsCount, typeEncoding,
      ArgConverter::ReturnOwnership(methodMeta->selector(), methodMeta),
      Interop::ConsumedObjectArgumentIndex(methodMeta->selector(), typeEncoding, argsCount));
  IMP methodBody =
      Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
  ReplaceKeepingOriginal(klass, methodMeta->selector(), methodMeta->selectorAsString(), methodBody,
                         compilerEncoding.c_str());
  // Not intercepted: the native write is done, but V8 must still perform
  // the ordinary store, which is what the old void-returning callback did
  // by falling through without setting a return value.
  return v8::Intercepted::kNo;
}

v8::Intercepted MetadataBuilder::SwizzledPropertyCallback(
    Local<v8::Name> property, const PropertyDescriptor& desc,
    const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  if (DefiningGuardedMember::Defines(isolate, info.Holder(), property)) {
    return v8::Intercepted::kNo;
  }
  ForgetNativeSetter(isolate, info.Holder(), property);
  std::string propertyName = tns::ToString(isolate, property);

  CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  const BaseClassMeta* meta = item->meta_;

  Class klass = objc_getClass(meta->name());
  if (klass == nil) {
    return v8::Intercepted::kNo;
  }

  int index = meta->instanceProps->binarySearch([propertyName](const PtrTo<PropertyMeta>& current) {
    const PropertyMeta* propertyMeta = current.valuePtr();
    return strcmp(propertyMeta->jsName(), propertyName.c_str());
  });

  if (index < 0) {
    return v8::Intercepted::kNo;
  }

  const PropertyMeta* propertyMeta = meta->instanceProps->operator[](index).valuePtr();

  if (desc.has_get()) {
    FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues,
                                          void* userData) {
      PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
      Isolate* isolate = context->isolateWrapper_.Isolate();
      // Scopes-before-@throw: capture a branded escape and @throw only after
      // the inner block's V8 scopes destruct.
      NSException* __strong pendingThrow = nil;
      {
        // This IMP stays on the native class after the isolate that installed
        // it is gone. Validity is checked before and again after taking the
        // Locker, for the reasons given in ArgConverter::MethodCallback.
        IsolatePin pin = context->isolateWrapper_.Pin();
        if (!pin || !context->isolateWrapper_.IsValid()) {
          memset(retValue, 0, cif->rtype->size);
          return;
        }
        v8::Locker locker(isolate);
        if (!context->isolateWrapper_.IsValid()) {
          memset(retValue, 0, cif->rtype->size);
          return;
        }
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        Local<v8::Function> getterFunc = context->callback_->Get(isolate);
        Local<Value> res;

        id thiz = *static_cast<const id*>(argValues[0]);
        Local<Context> v8Context = Caches::Get(isolate)->GetContext();
        Local<Object> self_ = ArgConverter::WrapCallbackSelf(v8Context, thiz);
        TryCatch tc(isolate);
        if (!getterFunc->Call(v8Context, self_, 0, nullptr).ToLocal(&res)) {
          NSException* ex = ArgConverter::HandleBoundaryException(v8Context, tc);
          if (ex != nil) {
            pendingThrow = ex;
          }
          memset(retValue, 0, cif->rtype->size);
        } else {
          const MethodMeta* getterMeta = context->meta_->getter();
          const TypeEncoding* typeEncoding = getterMeta->encodings()->first();
          bool writtenUnowned =
              ArgConverter::SetValue(v8Context, retValue, cif->rtype->size, res, typeEncoding);
          ArgConverter::RetainOwnedResult(
              ArgConverter::ReturnOwnership(*static_cast<SEL*>(argValues[1]), getterMeta),
              argValues, retValue, writtenUnowned);
        }
      }
      if (pendingThrow != nil) {
        @throw pendingThrow;
      }
    };

    const TypeEncoding* typeEncoding = propertyMeta->getter()->encodings()->first();
    std::string compilerEncoding = ClassBuilder::GetAccessorTypeEncoding(typeEncoding, 0, "@@:");

    Local<Value> getter = desc.get();
    std::shared_ptr<Persistent<v8::Function>> poGetterFunc =
        std::make_shared<Persistent<v8::Function>>(isolate, getter.As<v8::Function>());
    PropertyCallbackContext* userData =
        new PropertyCallbackContext(isolate, poGetterFunc, propertyMeta);
    IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback, userData);
    ReplaceKeepingOriginal(klass, propertyMeta->getter()->selector(),
                           propertyMeta->getter()->selectorAsString(), impGetter,
                           compilerEncoding.c_str());
  }

  if (desc.has_set()) {
    FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues,
                                          void* userData) {
      PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
      Isolate* isolate = context->isolateWrapper_.Isolate();
      NSException* __strong pendingThrow = nil;
      {
        IsolatePin pin = context->isolateWrapper_.Pin();
        if (!pin || !context->isolateWrapper_.IsValid()) {
          return;
        }
        v8::Locker locker(isolate);
        if (!context->isolateWrapper_.IsValid()) {
          return;
        }
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        Local<v8::Function> setterFunc = context->callback_->Get(isolate);
        Local<Value> res;

        Local<Context> v8Context = Caches::Get(isolate)->GetContext();

        id thiz = *static_cast<const id*>(argValues[0]);
        Local<Object> self_ = ArgConverter::WrapCallbackSelf(v8Context, thiz);

        uint8_t* argBuffer = (uint8_t*)argValues[2];
        const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
        BaseCall call(argBuffer);
        Local<Value> jsWrapper = Interop::GetResult(v8Context, typeEncoding, &call, true);
        Local<Value> params[1] = {jsWrapper};

        TryCatch tc(isolate);
        if (!setterFunc->Call(v8Context, self_, 1, params).ToLocal(&res)) {
          NSException* ex = ArgConverter::HandleBoundaryException(v8Context, tc);
          if (ex != nil) {
            pendingThrow = ex;
          }
          // Setter returns void; nothing to write on a JS throw.
        }
      }
      if (pendingThrow != nil) {
        @throw pendingThrow;
      }
    };

    const TypeEncoding* typeEncoding = propertyMeta->setter()->encodings()->first();
    Local<Value> setter = desc.set();
    std::shared_ptr<Persistent<v8::Function>> poSetterFunc =
        std::make_shared<Persistent<v8::Function>>(isolate, setter.As<v8::Function>());
    PropertyCallbackContext* userData =
        new PropertyCallbackContext(isolate, poSetterFunc, propertyMeta);
    IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

    std::string compilerEncoding = ClassBuilder::GetAccessorTypeEncoding(typeEncoding, 1, "v@:@");
    ReplaceKeepingOriginal(klass, propertyMeta->setter()->selector(),
                           propertyMeta->setter()->selectorAsString(), impSetter,
                           compilerEncoding.c_str());
  }
  // Not intercepted: the native write is done, but V8 must still perform
  // the ordinary store, which is what the old void-returning callback did
  // by falling through without setting a return value.
  return v8::Intercepted::kNo;
}

}  // namespace tns
