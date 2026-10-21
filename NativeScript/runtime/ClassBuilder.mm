#include "ClassBuilder.h"
#include <Foundation/Foundation.h>
#include <objc/message.h>
#include <algorithm>
#include <numeric>
#include <set>
#include <sstream>
#include "ArgConverter.h"
#include "BuiltinLoader.h"
#include "Caches.h"
#include "ExternalMemory.h"
#include "FFICall.h"
#include "FastEnumerationAdapter.h"
#include "Helpers.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "TNSDerivedClass.h"

using namespace v8;

namespace tns {

namespace {
// Worker-created named classes must not claim process-global objc names:
// verbatim names are the main isolate's contract (storyboards,
// NSClassFromString and other name-based native lookups), and a worker
// winning the registration race for one would nondeterministically demote the
// main isolate's class to a collision suffix.
void ScopeClassNameToIsolate(std::string& name, int isolateId) {
  if (!name.empty() && Runtime::IsWorker()) {
    name += '_';
    name += std::to_string(isolateId);
  }
}

struct ESClassState {
  // Classes registered from plain ES `class X extends Native {}` constructors.
  robin_hood::unordered_set<Class> classes;
  // The ES class each class wrapped so far belongs to (nil for none), so an object's first wrap
  // costs one lookup. A negative entry stays valid: ES classes are always new classes, so no
  // class seen before one was registered can ever descend from it.
  robin_hood::unordered_map<Class, Class> esClassOf;
  robin_hood::unordered_map<Class, Global<v8::Function>> constructors;
  Global<Object> objectPrototype;
  // Handles every construction would otherwise create again.
  Global<Symbol> argsSymbol;
  Global<Symbol> nativeSymbol;
  Global<v8::String> selectorKey;
  Global<v8::String> argsKey;
  robin_hood::unordered_map<SEL, Global<v8::String>> selectorNames;
  robin_hood::unordered_map<const MethodMeta*, std::vector<Global<v8::String>>> tokenKeys;
};

Local<v8::String> CachedString(Isolate* isolate, Global<v8::String>& slot, const char* text) {
  if (slot.IsEmpty()) {
    slot.Reset(isolate, tns::ToV8String(isolate, text));
  }
  return slot.Get(isolate);
}

// API-registry symbols: shared by every context of an isolate, and unreachable through JS's
// Symbol.for, so interop.initializer is the only way to obtain them.
Local<Symbol> CachedApiSymbol(Isolate* isolate, Global<Symbol>* slot, const char* name) {
  if (slot == nullptr) {
    return Symbol::ForApi(isolate, tns::ToV8String(isolate, name));
  }
  if (slot->IsEmpty()) {
    slot->Reset(isolate, Symbol::ForApi(isolate, tns::ToV8String(isolate, name)));
  }
  return slot->Get(isolate);
}

Local<Symbol> InitializerArgsSymbol(Isolate* isolate) {
  ESClassState* state = Caches::StateFor<ESClassState>(isolate);
  return CachedApiSymbol(isolate, state != nullptr ? &state->argsSymbol : nullptr,
                         "interop.initializer.args");
}

Local<Symbol> InitializerNativeSymbol(Isolate* isolate) {
  ESClassState* state = Caches::StateFor<ESClassState>(isolate);
  return CachedApiSymbol(isolate, state != nullptr ? &state->nativeSymbol : nullptr,
                         "interop.initializer.native");
}

struct InitializerHook {
  InitializerHook(Isolate* isolate, const MethodMeta* meta, Class hookClass)
      : isolateWrapper(isolate), meta(meta), hookClass(hookClass) {}
  IsolateWrapper isolateWrapper;
  const MethodMeta* meta;
  // The class the hook is installed on. Its subclasses inherit the hook, so this, not the
  // receiver's class, is what the original implementation is looked up above.
  Class hookClass;
};

// A construction Objective-C started, waiting for the constructor's super(...) to claim it.
struct NativeConstruction {
  id self;
  Class klass;
  // Null when adopting an object an initializer without a hook already initialized.
  const InitializerHook* hook;
  ffi_cif* cif;
  void** argValues;
  Local<Object> info;
  Local<Value> prefill;
  bool consumed = false;
  bool initRan = false;
  id result = nil;
};

// An initializer and the constructor it triggers run synchronously on one thread, so neither
// list is ever read from another thread.
thread_local std::vector<id> objectsUnderInit;
thread_local std::vector<NativeConstruction*> nativeConstructions;

bool IsUnderInit(id object) {
  return std::find(objectsUnderInit.begin(), objectsUnderInit.end(), object) !=
         objectsUnderInit.end();
}

class UnderInitScope {
 public:
  explicit UnderInitScope(id object) { objectsUnderInit.push_back(object); }
  ~UnderInitScope() { objectsUnderInit.pop_back(); }
};

class NativeConstructionScope {
 public:
  explicit NativeConstructionScope(NativeConstruction* construction) {
    nativeConstructions.push_back(construction);
  }
  ~NativeConstructionScope() { nativeConstructions.pop_back(); }
};

// The ES class object belongs to: its own class, or the one a runtime-created dynamic subclass
// (KVO's NSKVONotifying_*) was made from. Nothing else can subclass a class the runtime
// registered, so the first one found walking up is it.
Class FindESClass(Isolate* isolate, id object) {
  ESClassState* state = Caches::StateFor<ESClassState>(isolate);
  if (state == nullptr) {
    return nil;
  }
  Class objectClass = object_getClass(object);
  auto memo = state->esClassOf.find(objectClass);
  if (memo != state->esClassOf.end()) {
    return memo->second;
  }

  Class esClass = nil;
  for (Class klass = objectClass; klass != nil; klass = class_getSuperclass(klass)) {
    if (state->classes.count(klass) != 0) {
      esClass = klass;
      break;
    }
  }
  state->esClassOf.emplace(objectClass, esClass);
  return esClass;
}

void CallSuperInitializer(ffi_cif* cif, void* retValue, void** argValues, Class hookClass) {
  SEL selector = *static_cast<SEL*>(argValues[1]);
  IMP imp = class_getMethodImplementation(class_getSuperclass(hookClass), selector);
  ffi_call(cif, FFI_FN(imp), retValue, argValues);
}

// The initializer's arguments as JS values, without the trailing NSError** an error-out
// initializer takes: neither constructor tokens nor JS callers ever see it.
std::vector<Local<Value>> NativeInitializerArgs(Local<Context> context, const MethodMeta* meta,
                                                void** argValues) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  int count = meta->encodings()->count - 1;
  if (meta->hasErrorOutParameter()) {
    count--;
  }
  std::vector<Local<Value>> args;
  const TypeEncoding* typeEncoding = meta->encodings()->first();
  for (int i = 0; i < count; i++) {
    typeEncoding = typeEncoding->next();
    BaseCall call(static_cast<uint8_t*>(argValues[i + 2]));
    Local<Value> value = Interop::GetResult(context, typeEncoding, &call, true);
    args.push_back(value.IsEmpty() ? Local<Value>(v8::Undefined(isolate)) : value);
  }
  return args;
}

Local<Object> NewInitializerInfo(Local<Context> context, ESClassState* state, SEL selector,
                                 std::vector<Local<Value>> args) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Value> selectorValue = v8::Null(isolate);
  if (selector != nullptr) {
    auto name = state->selectorNames.find(selector);
    if (name == state->selectorNames.end()) {
      name = state->selectorNames
                 .emplace(selector, Global<v8::String>(
                                        isolate, tns::ToV8String(isolate, sel_getName(selector))))
                 .first;
    }
    selectorValue = name->second.Get(isolate);
  }
  Local<Object> info = Object::New(isolate);
  bool success =
      info->CreateDataProperty(context, CachedString(isolate, state->selectorKey, "selector"),
                               selectorValue)
          .FromMaybe(false) &&
      info->CreateDataProperty(context, CachedString(isolate, state->argsKey, "args"),
                               v8::Array::New(isolate, args.data(), args.size()))
          .FromMaybe(false) &&
      info->SetIntegrityLevel(context, IntegrityLevel::kFrozen).FromMaybe(false);
  tns::Assert(success, isolate);
  return info;
}

Local<Object> NewTokensObject(Local<Context> context, ESClassState* state, const MethodMeta* meta,
                              const std::vector<Local<Value>>& args) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  auto keys = state->tokenKeys.find(meta);
  if (keys == state->tokenKeys.end()) {
    std::vector<Global<v8::String>> tokenKeys;
    for (const std::string& token : ArgConverter::ConstructorTokens(meta)) {
      tokenKeys.emplace_back(isolate, tns::ToV8String(isolate, token));
    }
    keys = state->tokenKeys.emplace(meta, std::move(tokenKeys)).first;
  }
  Local<Object> tokensObject = Object::New(isolate);
  // Every token is a key, even a parameterless initializer's (initWithEmpty -> { empty }), so a
  // copy of this object names the same initializer.
  for (size_t i = 0; i < keys->second.size(); i++) {
    Local<Value> value = i < args.size() ? args[i] : Local<Value>(v8::Undefined(isolate));
    tns::Assert(tokensObject->CreateDataProperty(context, keys->second[i].Get(isolate), value)
                    .FromMaybe(false),
                isolate);
  }
  return tokensObject;
}

// The class an ES class's initializers end up in: the superclass of the first ES class above
// its native (or legacy) base, which is where that class's hooks pass through to.
Class InitializerSuperclass(ESClassState* state, Class klass) {
  Class root = klass;
  for (Class c = class_getSuperclass(klass); c != nil && state->classes.count(c) != 0;
       c = class_getSuperclass(c)) {
    root = c;
  }
  return class_getSuperclass(root);
}

// An object literal or a spread of one; a class instance passed straight to super(...) is the
// positional form this contract replaces.
bool IsOptionsObject(Isolate* isolate, ESClassState* state, Local<Value> value) {
  // Native wrappers and struct objects are built from templates with an internal field.
  if (!value->IsObject() || value->IsFunction() || value->IsArray() || value->IsProxy() ||
      value.As<Object>()->InternalFieldCount() > 0) {
    return false;
  }
  if (state->objectPrototype.IsEmpty()) {
    state->objectPrototype.Reset(isolate, Object::New(isolate)->GetPrototype().As<Object>());
  }
  Local<Value> prototype = value.As<Object>()->GetPrototype();
  return prototype->IsNull() || prototype->StrictEquals(state->objectPrototype.Get(isolate));
}

void InitializerHookCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData) {
  InitializerHook* hook = static_cast<InitializerHook*>(userData);
  id self = *static_cast<const id*>(argValues[0]);
  if (IsUnderInit(self)) {
    CallSuperInitializer(cif, retValue, argValues, hook->hookClass);
    return;
  }

  Isolate* isolate = hook->isolateWrapper.Isolate();
  // Declared before all V8 scopes: an ObjC exception must never unwind through a live V8 scope.
  NSException* __strong pendingThrow = nil;
  id result = nil;
  {
    IsolatePin pin = hook->isolateWrapper.Pin();
    if (!pin || !hook->isolateWrapper.IsValid()) {
      CallSuperInitializer(cif, retValue, argValues, hook->hookClass);
      return;
    }
    v8::Locker locker(isolate);
    if (!hook->isolateWrapper.IsValid()) {
      CallSuperInitializer(cif, retValue, argValues, hook->hookClass);
      return;
    }
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    Local<Context> context = cache->GetContext();
    Context::Scope context_scope(context);

    ESClassState* state = Caches::StateFor<ESClassState>(isolate);
    Class klass = FindESClass(isolate, self);
    if (state == nullptr || klass == nil) {
      CallSuperInitializer(cif, retValue, argValues, hook->hookClass);
      return;
    }
    auto ctorIt = state->constructors.find(klass);
    if (ctorIt == state->constructors.end()) {
      CallSuperInitializer(cif, retValue, argValues, hook->hookClass);
      return;
    }
    Local<v8::Function> ctor = ctorIt->second.Get(isolate);

    std::vector<Local<Value>> args = NativeInitializerArgs(context, hook->meta, argValues);
    Local<Object> info = NewInitializerInfo(context, state, hook->meta->selector(), args);
    // Frozen: super(...) forwards Objective-C's own arguments while this object is passed on
    // unchanged, so an edit in place would be silently dropped. A replacement object is honored.
    Local<Object> prefill = NewTokensObject(context, state, hook->meta, args);
    tns::Assert(prefill->SetIntegrityLevel(context, IntegrityLevel::kFrozen).FromMaybe(false),
                isolate);
    Local<Object> options = Object::New(isolate);
    tns::Assert(options->CreateDataProperty(context, InitializerNativeSymbol(isolate), info)
                        .FromMaybe(false) &&
                    options->CreateDataProperty(context, InitializerArgsSymbol(isolate), prefill)
                        .FromMaybe(false),
                isolate);

    NativeConstruction construction{self, klass, hook, cif, argValues, info, prefill};
    bool constructed = false;
    {
      TryCatch tc(isolate);
      NativeConstructionScope scope(&construction);
      Local<Value> optionsValue = options;
      Local<Value> instance;
      constructed = ctor->CallAsConstructor(context, 1, &optionsValue).ToLocal(&instance);
      if (!constructed) {
        pendingThrow = ArgConverter::HandleBoundaryException(context, tc);
      } else if (!construction.consumed) {
        Local<Value> error = Exception::Error(tns::ToV8String(
            isolate, std::string("The constructor of ") + class_getName(klass) +
                         " finished without calling super(...), so " +
                         sel_getName(hook->meta->selector()) +
                         " never ran and the instance Objective-C allocated was discarded."));
        NativeScriptException::ReportToJsHandlersAndLog(isolate, error,
                                                        Exception::CreateMessage(isolate, error));
      }
    }

    if (constructed && construction.consumed && construction.result != nil) {
      result = construction.result;
    } else if (construction.initRan) {
      // The caller's reference; a JS instance bound to the object holds its own.
      [construction.result release];
    } else {
      // Never initialized: give back the caller's allocation, as a failing initializer does.
      [self release];
    }
  }  // all V8 scopes destruct here

  if (pendingThrow != nil) {
    @throw pendingThrow;
  }
  *static_cast<id*>(retValue) = result;
}

}  // namespace

static std::vector<const MethodMeta*> HookableInitializers(Isolate* isolate, Class nativeBase);
static void ThrowIfOverridesInitializer(Local<Context> context, Class nativeBase,
                                        Local<Object> implementationObject,
                                        const std::string& className);

Local<FunctionTemplate> ClassBuilder::GetExtendFunction(Isolate* isolate,
                                                        const InterfaceMeta* interfaceMeta) {
  CacheItem* item = new CacheItem(interfaceMeta, nullptr);
  Caches::Get(isolate)->registerCacheBoundObject(item);
  Local<External> ext = External::New(isolate, item, v8::kExternalPointerTypeTagDefault);
  return FunctionTemplate::New(isolate, ClassBuilder::ExtendCallback, ext);
}

void ClassBuilder::ExtendCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  tns::Assert(info.Length() > 0 && info[0]->IsObject() && info.This()->IsFunction(), isolate);

  try {
    Local<Context> context = isolate->GetCurrentContext();
    CacheItem* item = static_cast<CacheItem*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

    Local<Object> implementationObject = info[0].As<Object>();
    Local<v8::Function> baseFunc = info.This().As<v8::Function>();
    std::string baseClassName = tns::ToString(isolate, baseFunc->GetName());

    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, baseFunc);
    if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::ObjCClass) {
      ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(baseWrapper);
      if (classWrapper->ExtendedClass()) {
        throw NativeScriptException("Cannot extend an already extended class");
      }
    }

    Local<Object> nativeSignature;
    std::string staticClassName;
    if (info.Length() > 1 && info[1]->IsObject()) {
      nativeSignature = info[1].As<Object>();
      Local<Value> explicitClassName;
      tns::Assert(nativeSignature->Get(context, tns::ToV8String(isolate, "name"))
                      .ToLocal(&explicitClassName),
                  isolate);
      if (!explicitClassName.IsEmpty() && !explicitClassName->IsNullOrUndefined()) {
        staticClassName = tns::ToString(isolate, explicitClassName);
      }
    }
    auto cache = Caches::Get(isolate);
    auto isolateId = cache->getIsolateId();

    ScopeClassNameToIsolate(staticClassName, isolateId);
    Class extendedClass = ClassBuilder::GetExtendedClass(baseClassName, staticClassName, isolateId);
    tns::Assert(extendedClass != nil, isolate);
    class_addProtocol(extendedClass, @protocol(TNSDerivedClass));
    class_addProtocol(object_getClass(extendedClass), @protocol(TNSDerivedClass));

    if (!nativeSignature.IsEmpty()) {
      ClassBuilder::ExposeDynamicMembers(context, extendedClass, implementationObject,
                                         nativeSignature);
    } else {
      ClassBuilder::ExposeDynamicMethods(context, extendedClass, Local<Value>(), Local<Value>(),
                                         implementationObject);
    }

    Local<v8::Function> baseCtorFunc =
        cache->CtorFuncs.find(item->meta_->name())->second->Get(isolate);

    CacheItem* cacheItem = new CacheItem(nullptr, extendedClass);
    Caches::Get(isolate)->registerCacheBoundObject(cacheItem);
    Local<External> ext = External::New(isolate, cacheItem, v8::kExternalPointerTypeTagDefault);
    Local<FunctionTemplate> extendedClassCtorFuncTemplate =
        FunctionTemplate::New(isolate, ExtendedClassConstructorCallback, ext);
    extendedClassCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    Local<v8::Function> extendClassCtorFunc;
    if (!extendedClassCtorFuncTemplate->GetFunction(context).ToLocal(&extendClassCtorFunc)) {
      tns::Assert(false, isolate);
    }

    Local<Value> baseProto;
    bool success =
        baseCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&baseProto);
    tns::Assert(success, isolate);

    if (!implementationObject->SetPrototype(context, baseProto).To(&success) || !success) {
      tns::Assert(false, isolate);
    }
    Local<v8::Function> superGetter;
    if (!FunctionTemplate::New(isolate, SuperAccessorGetterCallback, ext)
             ->GetFunction(context)
             .ToLocal(&superGetter)) {
      tns::Assert(false, isolate);
    }
    // Must be a function-backed accessor: it needs the receiver, and
    // PropertyCallbackInfo no longer exposes it (Holder() is this object, not
    // the instance that inherits from it).
    implementationObject->SetAccessorProperty(tns::ToV8String(isolate, "super"), superGetter);

    extendClassCtorFunc->SetName(tns::ToV8String(isolate, class_getName(extendedClass)));
    Local<Value> extendFuncPrototypeValue;
    success = extendClassCtorFunc->Get(context, tns::ToV8String(isolate, "prototype"))
                  .ToLocal(&extendFuncPrototypeValue);
    tns::Assert(success && extendFuncPrototypeValue->IsObject(), isolate);
    Local<Object> extendFuncPrototype = extendFuncPrototypeValue.As<Object>();
    if (!extendFuncPrototype->SetPrototype(context, implementationObject).To(&success) ||
        !success) {
      tns::Assert(false, isolate);
    }

    if (!extendClassCtorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
      tns::Assert(false, isolate);
    }

    std::string extendedClassName = class_getName(extendedClass);
    ObjCClassWrapper* wrapper = new ObjCClassWrapper(extendedClass, true);
    tns::SetValue(isolate, extendClassCtorFunc, wrapper);

    auto extendedPersistent =
        std::make_unique<Persistent<v8::Function>>(isolate, extendClassCtorFunc);
    extendedPersistent->SetWrapperClassId(Constants::ClassTypes::DataWrapper);
    cache->CtorFuncs.emplace(extendedClassName, std::move(extendedPersistent));
    cache->ClassPrototypes.emplace(
        extendedClassName, std::make_unique<Persistent<Object>>(isolate, extendFuncPrototype));

    info.GetReturnValue().Set(extendClassCtorFunc);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();

  try {
    CacheItem* item = static_cast<CacheItem*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
    bool esDerived = false;
    Class klass =
        ClassBuilder::ResolveConstructedClass(context, info.NewTarget(), item->data_, &esDerived);

    ArgConverter::ConstructObject(context, info, klass, nullptr, esDerived);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void ClassBuilder::RegisterBaseTypeScriptExtendsFunction(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  auto cache = Caches::Get(isolate);
  if (cache->OriginalExtendsFunc.get() != nullptr) {
    return;
  }

  Local<Value> extendsFunc;
  tns::Assert(BuiltinLoader::RunBuiltin(context, BuiltinId::kClassExtends).ToLocal(&extendsFunc) &&
                  extendsFunc->IsFunction(),
              isolate);

  cache->OriginalExtendsFunc =
      std::make_unique<Persistent<v8::Function>>(isolate, extendsFunc.As<v8::Function>());
}

void ClassBuilder::RegisterNativeTypeScriptExtendsFunction(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();

  Local<v8::Function> extendsFunc =
      v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        IsolateWrapper isolateWrapper(isolate);
        tns::Assert(info.Length() == 2, isolate);
        Local<Context> context = isolate->GetCurrentContext();

        auto cache = Caches::Get(isolate);
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info[1].As<Object>());
        if (!wrapper) {
          // We are not extending a native object -> call the base __extends function
          Persistent<v8::Function>* poExtendsFunc = cache->OriginalExtendsFunc.get();
          tns::Assert(poExtendsFunc != nullptr, isolate);
          Local<v8::Function> originalExtendsFunc = poExtendsFunc->Get(isolate);
          Local<Value> args[] = {info[0], info[1]};
          originalExtendsFunc->Call(context, context->Global(), info.Length(), args)
              .ToLocalChecked();
          return;
        }

        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
        Class baseClass = classWrapper->Klass();
        std::string baseClassName = class_getName(baseClass);

        Local<v8::Function> extendedClassCtorFunc = info[0].As<v8::Function>();
        std::string extendedClassName = tns::ToString(isolate, extendedClassCtorFunc->GetName());

        auto isolateId = cache->getIsolateId();
        ScopeClassNameToIsolate(extendedClassName, isolateId);
        __block Class extendedClass =
            ClassBuilder::GetExtendedClass(baseClassName, extendedClassName, isolateId);
        tns::Assert(extendedClass != nil, isolate);
        class_addProtocol(extendedClass, @protocol(TNSDerivedClass));
        class_addProtocol(object_getClass(extendedClass), @protocol(TNSDerivedClass));

        extendedClassName = class_getName(extendedClass);

        tns::SetValue(isolate, extendedClassCtorFunc, new ObjCClassWrapper(extendedClass, true));

        const Meta* baseMeta = ArgConverter::FindMeta(baseClass);
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(baseMeta);
        Local<v8::Function> baseCtorFunc =
            cache->CtorFuncs.find(interfaceMeta->name())->second->Get(isolate);

        tns::Assert(extendedClassCtorFunc->SetPrototype(context, baseCtorFunc).ToChecked(),
                    isolate);

        Local<v8::String> prototypeProp = tns::ToV8String(isolate, "prototype");

        Local<Value> extendedClassCtorFuncPrototypeValue;
        bool success = extendedClassCtorFunc->Get(context, prototypeProp)
                           .ToLocal(&extendedClassCtorFuncPrototypeValue);
        tns::Assert(success && extendedClassCtorFuncPrototypeValue->IsObject(), isolate);
        Local<Object> extendedClassCtorFuncPrototype =
            extendedClassCtorFuncPrototypeValue.As<Object>();

        Local<Value> prototypePropValue;
        success = baseCtorFunc->Get(context, prototypeProp).ToLocal(&prototypePropValue);
        tns::Assert(success && prototypePropValue->IsObject(), isolate);

        success =
            extendedClassCtorFuncPrototype->SetPrototype(context, prototypePropValue.As<Object>())
                .FromMaybe(false);
        tns::Assert(success, isolate);

        cache->ClassPrototypes.emplace(
            extendedClassName,
            std::make_unique<Persistent<Object>>(isolate, extendedClassCtorFuncPrototype));

        Persistent<v8::Function>* poExtendedClassCtorFunc =
            new Persistent<v8::Function>(isolate, extendedClassCtorFunc);
        poExtendedClassCtorFunc->SetWrapperClassId(Constants::ClassTypes::DataWrapper);

        cache->CtorFuncs.emplace(extendedClassName, poExtendedClassCtorFunc);

        IMP newInitialize = imp_implementationWithBlock(^(id self) {
          if (!isolateWrapper.IsValid()) {
            return;
          }
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          Local<Context> context = Caches::Get(isolate)->GetContext();
          Local<v8::Function> extendedClassCtorFunc = poExtendedClassCtorFunc->Get(isolate);

          Local<Value> exposedMethods;
          bool success =
              extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "ObjCExposedMethods"))
                  .ToLocal(&exposedMethods);
          tns::Assert(success, isolate);

          Local<Value> implementationObject;
          success = extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "prototype"))
                        .ToLocal(&implementationObject);
          tns::Assert(success, isolate);

          if (implementationObject.IsEmpty() || exposedMethods.IsEmpty()) {
            return;
          }

          Local<Value> exposedProtocols;
          success = extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "ObjCProtocols"))
                        .ToLocal(&exposedProtocols);
          tns::Assert(success, isolate);

          ClassBuilder::ExposeDynamicMethods(context, extendedClass, exposedMethods,
                                             exposedProtocols, implementationObject.As<Object>());
        });
        class_addMethod(object_getClass(extendedClass), @selector(initialize), newInitialize,
                        "v@:");

        ClassBuilder::SwizzleRetainRelease(isolate, extendedClass);

        info.GetReturnValue().SetUndefined();
      }).ToLocalChecked();

  PropertyAttribute flags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete);
  bool success =
      global->DefineOwnProperty(context, tns::ToV8String(isolate, "__extends"), extendsFunc, flags)
          .FromMaybe(false);
  tns::Assert(success, isolate);
}

void ClassBuilder::SwizzleRetainRelease(Isolate* isolate, Class extendedClass) {
  IsolateWrapper isolateWrapper(isolate);

  /// We swizzle the retain and release methods for the following reason:
  /// When we instantiate a native class via a JavaScript call we add it to the object
  /// instances map thus incrementing the retainCount by 1. Then, when the native object is
  /// referenced somewhere else its count will become more than 1. Since we want to keep the
  /// corresponding JavaScript object alive even if it is not used anywhere, we call GcProtect
  /// on it. Whenever the native object is released so that its retainCount is 1 (the object
  /// instances map), we unprotect the corresponding JavaScript object in order to make both
  /// of them destroyable/GC-able. When the JavaScript object is GC-ed we release the native
  /// counterpart as well.
  id (*retain)(id, SEL) =
      (id (*)(id, SEL))FindNotOverridenMethod(extendedClass, @selector(retain));
  IMP newRetain = imp_implementationWithBlock(^id(id self) {
    if (!isolateWrapper.IsValid()) {
      return retain(self, @selector(retain));
    }
    if ([self retainCount] == 1) {
      auto runtime = Runtime::GetRuntime(isolate);
      auto runtimeLoop = runtime->RuntimeLoop();
      void* weakSelf = (__bridge void*)self;
      auto gcProtect = [isolateWrapper, weakSelf, isolate]() {
        auto innerCache = isolateWrapper.GetCache();
        auto it = innerCache->Instances.find((id)weakSelf);
        if (it != innerCache->Instances.end()) {
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          Local<Value> value = it->second->Get(isolate);
          BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
          if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
            ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            objcWrapper->GcProtect();
          }
        }
      };
      if (CFRunLoopGetCurrent() != runtimeLoop) {
        // bare entry: the closure does its own Locker ceremony, exactly
        // like the performed block it replaces
        runtime->GetEventLoop()->PostInternalBare(gcProtect);
      } else {
        gcProtect();
      }
    }

    return retain(self, @selector(retain));
  });
  class_addMethod(extendedClass, @selector(retain), newRetain, "@@:");

  void (*release)(id, SEL) =
      (void (*)(id, SEL))FindNotOverridenMethod(extendedClass, @selector(release));
  IMP newRelease = imp_implementationWithBlock(^(id self) {
    if (!isolateWrapper.IsValid()) {
      release(self, @selector(release));
      return;
    }

    if ([self retainCount] == 2) {
      void* weakSelf = (__bridge void*)self;
      auto gcUnprotect = [isolateWrapper, weakSelf, isolate]() {
        auto innerCache = isolateWrapper.GetCache();
        auto it = innerCache->Instances.find((id)weakSelf);
        if (it != innerCache->Instances.end()) {
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          if (it->second != nullptr) {
            Local<Value> value = it->second->Get(isolate);
            BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
            if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
              ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
              objcWrapper->GcUnprotect();
            }
          }
        }
      };
      auto runtime = Runtime::GetRuntime(isolate);
      auto runtimeLoop = runtime->RuntimeLoop();
      if (CFRunLoopGetCurrent() != runtimeLoop) {
        // bare entry: the closure does its own Locker ceremony, exactly
        // like the performed block it replaces
        runtime->GetEventLoop()->PostInternalBare(gcUnprotect);
      } else {
        auto innerCache = isolateWrapper.GetCache();
        auto it = innerCache->Instances.find(self);
        if (it != innerCache->Instances.end()) {
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          if (it->second != nullptr) {
            Local<Value> value = it->second->Get(isolate);
            BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
            if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
              ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
              objcWrapper->GcUnprotect();
            }
          }
        }
      }
    }

    release(self, @selector(release));
  });
  class_addMethod(extendedClass, @selector(release), newRelease, "v@:");
}

void ClassBuilder::RegisterNativeClassFunction(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();

  Local<v8::Function> registerFunc =
      v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();

        if (info.Length() < 1 || !info[0]->IsFunction()) {
          info.GetReturnValue().Set(false);
          return;
        }

        // Eager registration exists so the class answers to its source name
        // (storyboards, NSClassFromString, UIApplicationMain). A worker's
        // classes are isolate-suffixed, so there is no name to claim and the
        // request is dropped; the class still registers lazily on first use.
        if (Runtime::IsWorker()) {
          info.GetReturnValue().Set(false);
          return;
        }

        try {
          Class klass = ClassBuilder::EnsureExtendedClass(context, info[0].As<v8::Function>());
          info.GetReturnValue().Set(klass != nil);
        } catch (NativeScriptException& ex) {
          ex.ReThrowToV8(isolate);
        }
      }).ToLocalChecked();

  PropertyAttribute flags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::DontEnum);
  bool success = global
                     ->DefineOwnProperty(context, tns::ToV8String(isolate, "__registerNativeClass"),
                                         registerFunc, flags)
                     .FromMaybe(false);
  tns::Assert(success, isolate);
}

Class ClassBuilder::EnsureExtendedClass(Local<Context> context, Local<v8::Function> ctorFunc) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  // Already registered (or a native/extended constructor that carries a class wrapper)
  BaseDataWrapper* existingWrapper = tns::GetValue(isolate, ctorFunc);
  if (existingWrapper != nullptr) {
    if (existingWrapper->Type() == WrapperType::ObjCClass) {
      return static_cast<ObjCClassWrapper*>(existingWrapper)->Klass();
    }
    return nil;
  }

  Local<Value> parentValue = ctorFunc->GetPrototype();
  if (parentValue.IsEmpty() || !parentValue->IsFunction()) {
    return nil;
  }

  // The parent is native, legacy `.extend()`-created, already registered, or an
  // ES class that is registered here first so it can be this class's superclass.
  Class baseClass = ClassBuilder::EnsureExtendedClass(context, parentValue.As<v8::Function>());
  if (baseClass == nil) {
    return nil;
  }

  auto cache = Caches::Get(isolate);
  auto isolateId = cache->getIsolateId();

  std::string baseClassName = class_getName(baseClass);

  BaseDataWrapper* parentWrapper = tns::GetValue(isolate, parentValue);
  bool parentIsESClass = parentWrapper != nullptr &&
                         parentWrapper->Type() == WrapperType::ObjCClass &&
                         static_cast<ObjCClassWrapper*>(parentWrapper)->ESDerivedClass();

  Local<Value> prototypeValue;
  bool success =
      ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
  tns::Assert(success && !prototypeValue.IsEmpty() && prototypeValue->IsObject(), isolate);
  Local<Object> implementationObject = prototypeValue.As<Object>();

  Class nativeBase = class_conformsToProtocol(baseClass, @protocol(TNSDerivedClass))
                         ? ClassBuilder::GetNativeSuperclass(baseClass)
                         : baseClass;
  ThrowIfOverridesInitializer(context, nativeBase, implementationObject,
                              tns::ToString(isolate, ctorFunc->GetName()));

  // An explicit name survives minification, which mangles the inferred ctor
  // name and with it any name-based native lookup.
  // Own property only: an inherited ObjCClassName would make a subclass try to
  // register under its base's name.
  std::string className;
  Local<v8::Name> classNameKey = tns::ToV8String(isolate, "ObjCClassName");
  bool hasOwnName = false;
  if (ctorFunc->HasOwnProperty(context, classNameKey.As<v8::String>()).To(&hasOwnName) &&
      hasOwnName) {
    Local<Value> explicitName;
    if (ctorFunc->Get(context, classNameKey).ToLocal(&explicitName) && !explicitName.IsEmpty() &&
        explicitName->IsString()) {
      className = tns::ToString(isolate, explicitName);
    }
  }
  if (className.empty()) {
    className = tns::ToString(isolate, ctorFunc->GetName());
  }

  ScopeClassNameToIsolate(className, isolateId);
  Class extendedClass = ClassBuilder::GetExtendedClass(baseClassName, className, isolateId);
  tns::Assert(extendedClass != nil, isolate);
  class_addProtocol(extendedClass, @protocol(TNSDerivedClass));
  class_addProtocol(object_getClass(extendedClass), @protocol(TNSDerivedClass));

  // Statics like ObjCProtocols/ObjCExposedMethods are read through the constructor, so they
  // inherit through the static chain like class statics do: a subclass overriding a method
  // declared there still finds its signature.
  Local<Value> exposedMethods;
  success = ctorFunc->Get(context, tns::ToV8String(isolate, "ObjCExposedMethods"))
                .ToLocal(&exposedMethods);
  tns::Assert(success, isolate);

  Local<Value> exposedProtocols;
  success =
      ctorFunc->Get(context, tns::ToV8String(isolate, "ObjCProtocols")).ToLocal(&exposedProtocols);
  tns::Assert(success, isolate);

  ClassBuilder::ExposeDynamicMethods(context, extendedClass, exposedMethods, exposedProtocols,
                                     implementationObject);

  tns::SetValue(isolate, ctorFunc, new ObjCClassWrapper(extendedClass, true, true));

  std::string extendedClassName = class_getName(extendedClass);

  auto extendedPersistent = std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc);
  extendedPersistent->SetWrapperClassId(Constants::ClassTypes::DataWrapper);
  cache->CtorFuncs.emplace(extendedClassName, std::move(extendedPersistent));
  if (ESClassState* esClasses = Caches::StateFor<ESClassState>(isolate)) {
    esClasses->classes.insert(extendedClass);
    esClasses->esClassOf[extendedClass] = extendedClass;
    esClasses->constructors.emplace(extendedClass, Global<v8::Function>(isolate, ctorFunc));
  }

  cache->ClassPrototypes.emplace(
      extendedClassName, std::make_unique<Persistent<Object>>(isolate, implementationObject));

  ClassBuilder::SwizzleRetainRelease(isolate, extendedClass);

  // Installed once, on the first ES class above the native (or legacy) base; ES subclasses
  // inherit the hooks and construct through them.
  if (!parentIsESClass) {
    ClassBuilder::InstallInitializerHooks(isolate, extendedClass);
  }

  return extendedClass;
}

bool ClassBuilder::MayBeESClass(Local<Value> function) {
  return !function.IsEmpty() && function->IsFunction() &&
         function.As<v8::Function>()->ScriptId() != UnboundScript::kNoScriptId;
}

Class ClassBuilder::ResolveConstructedClass(Local<Context> context, Local<Value> newTarget,
                                            Class fallback, bool* esDerived) {
  if (esDerived != nullptr) {
    *esDerived = false;
  }
  if (!MayBeESClass(newTarget)) {
    return fallback;
  }

  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> newTargetFunc = newTarget.As<v8::Function>();

  BaseDataWrapper* wrapper = tns::GetValue(isolate, newTargetFunc);
  if (wrapper == nullptr) {
    if (ClassBuilder::EnsureExtendedClass(context, newTargetFunc) == nil) {
      return fallback;
    }
    wrapper = tns::GetValue(isolate, newTargetFunc);
  }
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCClass) {
    return fallback;
  }
  ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
  if (esDerived != nullptr) {
    *esDerived = classWrapper->ESDerivedClass();
  }
  return classWrapper->Klass();
}

void ClassBuilder::ConstructESObject(Local<Context> context,
                                     const FunctionCallbackInfo<Value>& info, Class klass) {
  Isolate* isolate = info.GetIsolate();
  auto cache = Caches::Get(isolate);

  Local<Object> options;
  ESClassState* state = Caches::StateFor<ESClassState>(isolate);
  if (state == nullptr) {
    throw NativeScriptException("The runtime is shutting down");
  }

  if (info.Length() > 0 && !(info.Length() == 1 && info[0]->IsUndefined())) {
    if (info.Length() > 1 || !IsOptionsObject(isolate, state, info[0])) {
      throw NativeScriptException(
          std::string("super(...) in ") + class_getName(klass) +
          " takes no arguments or a single options object; choose the initializer with "
          "super({ [interop.initializer.args]: { frame } }). Positional arguments are not "
          "supported.");
    }
    options = info[0].As<Object>();
  }

  Local<Value> selection;
  Local<Value> nativeInfo;
  if (!options.IsEmpty()) {
    TryCatch tc(isolate);
    if (!options->Get(context, InitializerArgsSymbol(isolate)).ToLocal(&selection) ||
        !options->Get(context, InitializerNativeSymbol(isolate)).ToLocal(&nativeInfo)) {
      throw NativeScriptException(isolate, tc, "Cannot read the super(...) options");
    }
  }
  bool hasSelection = !selection.IsEmpty() && !selection->IsUndefined();
  bool hasNativeInfo = !nativeInfo.IsEmpty() && !nativeInfo->IsUndefined();

  NativeConstruction* construction = nullptr;
  if (!nativeConstructions.empty()) {
    NativeConstruction* top = nativeConstructions.back();
    if (!top->consumed && top->klass == klass &&
        (!hasNativeInfo || nativeInfo->StrictEquals(top->info))) {
      construction = top;
    }
  }
  if (construction == nullptr && hasNativeInfo) {
    throw NativeScriptException(
        "[interop.initializer.native] belongs to the construction Objective-C started; it "
        "cannot be passed on to another one.");
  }

  if (construction == nullptr && !options.IsEmpty() && !hasSelection) {
    std::vector<Local<Value>> unused;
    const MethodMeta* lookalike =
        ArgConverter::FindInitializerByTokens(context, klass, options, unused, false);
    if (lookalike != nullptr && strlen(lookalike->constructorTokens()) > 0) {
      throw NativeScriptException(
          std::string("super({ ... }) does not choose an initializer by its keys. To run ") +
          lookalike->selectorAsString() +
          ", pass them as super({ [interop.initializer.args]: { ... } }).");
    }
  }

  id self = construction != nullptr ? construction->self : [klass alloc];
  if (construction != nullptr) {
    construction->consumed = true;
  }
  if (ArgConverter::FindCachedInstance(isolate, cache, self) != nullptr) {
    if (construction == nullptr) {
      [self release];
    }
    throw NativeScriptException(
        std::string("This ") + class_getName(klass) +
        " instance already has a JS object; it cannot be constructed twice.");
  }

  // Bound before any initializer runs: overrides it calls find `self` in Instances and so see
  // the instance under construction.
  Local<Object> thiz = info.This();
  ObjCDataWrapper* wrapper = new ObjCDataWrapper(self);
  tns::SetValue(isolate, thiz, wrapper);
  std::shared_ptr<Persistent<Value>> poThiz = ObjectManager::Register(context, thiz);
  cache->Instances.emplace(self, poThiz);
  auto unbind = [&](id object) {
    cache->Instances.erase(object);
    tns::SetValue(isolate, thiz, nullptr);
    delete wrapper;
  };

  id result = self;
  bool adopting = construction != nullptr && construction->hook == nullptr;
  if (!adopting) {
    // Once an initializer raised, who owns `self` is unknowable; leaking it beats an
    // over-release.
    bool initRaised = false;
    try {
      UnderInitScope underInit(self);
      @try {
        // Sent straight to the implementation the hooks pass through to: going through
        // objc_msgSend would land in the hook only to be forwarded there again.
        Class superclass = construction != nullptr
                               ? class_getSuperclass(construction->hook->hookClass)
                               : InitializerSuperclass(state, klass);
        if (construction != nullptr &&
            (!hasSelection || selection->StrictEquals(construction->prefill))) {
          // The initializer Objective-C sent, with its own arguments.
          SEL selector = *static_cast<SEL*>(construction->argValues[1]);
          ffi_arg returned = 0;
          ffi_call(construction->cif, FFI_FN(class_getMethodImplementation(superclass, selector)),
                   &returned, construction->argValues);
          result = reinterpret_cast<id>(static_cast<uintptr_t>(returned));
        } else if (!hasSelection) {
          struct objc_super sup = {self, superclass};
          result = reinterpret_cast<id (*)(struct objc_super*, SEL)>(objc_msgSendSuper)(
              &sup, @selector(init));
        } else {
          if (!selection->IsObject() || selection.As<Object>()->InternalFieldCount() > 0) {
            throw NativeScriptException(
                "[interop.initializer.args] must be an object of initializer tokens, e.g. "
                "{ frame }.");
          }
          std::vector<Local<Value>> args;
          const MethodMeta* initializer = ArgConverter::FindInitializerByTokens(
              context, klass, selection.As<Object>(), args, true);
          V8VectorArgs vectorArgs(args);
          result =
              Interop::CallInitializer(context, initializer, self, klass, vectorArgs, superclass);
        }
      } @catch (NSException* e) {
        initRaised = true;
        Interop::ThrowAsJSError(e);
      }
    } catch (NativeScriptException&) {
      unbind(self);
      if (initRaised) {
        if (construction != nullptr) {
          construction->initRan = true;
        }
      } else if (construction == nullptr) {
        // Never initialized. A hook gives back its caller's allocation itself.
        [self release];
      }
      throw;
    }
    if (construction != nullptr) {
      construction->initRan = true;
    }
  }

  if (result == nil) {
    unbind(self);
    throw NativeScriptException(std::string("The initializer of ") + class_getName(klass) +
                                " returned nil.");
  }

  if (result != self) {
    cache->Instances.erase(self);
    auto existing = ArgConverter::FindCachedInstance(isolate, cache, result);
    if (existing != nullptr) {
      // An initializer that answered with an already wrapped object (a singleton, a cached
      // instance): that object is the result of super(...).
      tns::SetValue(isolate, thiz, nullptr);
      delete wrapper;
      if (construction != nullptr) {
        construction->result = result;
      } else {
        [result release];
      }
      info.GetReturnValue().Set(existing->Get(isolate));
      return;
    }
    delete wrapper;
    wrapper = new ObjCDataWrapper(result);
    tns::SetValue(isolate, thiz, wrapper);
    cache->Instances.emplace(result, poThiz);
  }

  if (construction != nullptr) {
    // The Instances entry needs its own reference; the caller keeps the one the initializer
    // returned (or, when adopting, the one it already held).
    [result retain];
    construction->result = result;
  }

  ExternalMemory::ChargeEstimatedSize(isolate, thiz);
}

bool ClassBuilder::TryAdoptNativeInstance(Local<Context> context, id target, Local<Value>& result) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  // Runs for every object's first wrap; set lookups keep that path flat.
  Class klass = FindESClass(isolate, target);
  if (klass == nil || IsUnderInit(target)) {
    return false;
  }
  for (NativeConstruction* construction : nativeConstructions) {
    if (construction->self == target) {
      return false;
    }
  }

  ESClassState* state = Caches::StateFor<ESClassState>(isolate);
  if (state == nullptr) {
    return false;
  }
  auto ctorIt = state->constructors.find(klass);
  if (ctorIt == state->constructors.end()) {
    return false;
  }
  Local<v8::Function> ctor = ctorIt->second.Get(isolate);

  Local<Object> info = NewInitializerInfo(context, state, nullptr, {});
  Local<Object> options = Object::New(isolate);
  tns::Assert(
      options->CreateDataProperty(context, InitializerNativeSymbol(isolate), info).FromMaybe(false),
      isolate);

  NativeConstruction construction{target, klass, nullptr, nullptr, nullptr, info, Local<Value>()};
  {
    // Runs wherever an object first crosses into JS, including inside callbacks from native
    // code, where nothing could catch a rethrow: a failing constructor is reported instead.
    TryCatch tc(isolate);
    NativeConstructionScope scope(&construction);
    Local<Value> optionsValue = options;
    Local<Value> instance;
    if (!ctor->CallAsConstructor(context, 1, &optionsValue).ToLocal(&instance) && tc.HasCaught()) {
      NativeScriptException::ReportToJsHandlersAndLog(isolate, tc.Exception(), tc.Message());
      tc.Reset();
    }
  }

  if (!construction.consumed) {
    Local<Value> error = Exception::Error(tns::ToV8String(
        isolate, std::string("The constructor of ") + class_getName(klass) +
                     " finished without calling super(...), so the instance Objective-C "
                     "created reaches JS unconstructed."));
    NativeScriptException::ReportToJsHandlersAndLog(isolate, error,
                                                    Exception::CreateMessage(isolate, error));
    return false;
  }
  auto cached = ArgConverter::FindCachedInstance(isolate, Caches::Get(isolate), target);
  if (cached == nullptr) {
    return false;
  }
  result = cached->Get(isolate);
  return true;
}

void ClassBuilder::RegisterInitializerSymbols(Local<Context> context, Local<Object> interop) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> initializer = Object::New(isolate);
  bool success =
      initializer->Set(context, tns::ToV8String(isolate, "args"), InitializerArgsSymbol(isolate))
          .FromMaybe(false) &&
      initializer
          ->Set(context, tns::ToV8String(isolate, "native"), InitializerNativeSymbol(isolate))
          .FromMaybe(false) &&
      initializer->SetIntegrityLevel(context, IntegrityLevel::kFrozen).FromMaybe(false) &&
      interop->Set(context, tns::ToV8String(isolate, "initializer"), initializer).FromMaybe(false);
  tns::Assert(success, isolate);
}

// Initializers the metadata lists for nativeBase's chain that nativeBase actually implements;
// optional protocol initializers it does not implement must not start answering
// respondsToSelector: on a subclass. Variadic ones cannot be forwarded by a fixed-signature
// hook.
static std::vector<const MethodMeta*> HookableInitializers(Isolate* isolate, Class nativeBase) {
  std::vector<const MethodMeta*> result;
  const Meta* meta = ArgConverter::FindMeta(nativeBase);
  if (meta == nullptr || meta->type() != MetaType::Interface) {
    return result;
  }
  auto cache = Caches::Get(isolate);
  std::set<SEL> seen;
  for (const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
       interfaceMeta != nullptr; interfaceMeta = interfaceMeta->baseMeta()) {
    for (const MethodMeta* initializer : ArgConverter::GetInitializers(
             cache.get(), objc_getClass(interfaceMeta->name()), interfaceMeta)) {
      SEL selector = initializer->selector();
      if (initializer->isVariadic() || !seen.insert(selector).second ||
          class_getInstanceMethod(nativeBase, selector) == nullptr) {
        continue;
      }
      result.push_back(initializer);
    }
  }
  return result;
}

void ClassBuilder::InstallInitializerHooks(Isolate* isolate, Class extendedClass) {
  Class nativeBase = class_getSuperclass(extendedClass);
  for (const MethodMeta* initializer : HookableInitializers(isolate, nativeBase)) {
    SEL selector = initializer->selector();
    InitializerHook* hook = new InitializerHook(isolate, initializer, extendedClass);
    IMP imp =
        Interop::CreateMethod(2, initializer->encodings()->count - 1,
                              initializer->encodings()->first(), InitializerHookCallback, hook);
    // The implemented method's own type string: exact for every signature, where one
    // rebuilt from metadata cannot express all of them.
    Method method = class_getInstanceMethod(nativeBase, selector);
    class_addMethod(extendedClass, selector, imp, method_getTypeEncoding(method));
  }
}

// The constructor runs for every initializer, so a JS method of the same name would replace the
// hook that runs it.
static void ThrowIfOverridesInitializer(Local<Context> context, Class nativeBase,
                                        Local<Object> implementationObject,
                                        const std::string& className) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  for (const MethodMeta* initializer : HookableInitializers(isolate, nativeBase)) {
    bool own = false;
    if (!implementationObject
             ->HasOwnProperty(context, tns::ToV8String(isolate, initializer->jsName()))
             .To(&own) ||
        !own) {
      continue;
    }
    throw NativeScriptException(
        "Class " + className + " defines " + initializer->jsName() +
        "(), which overrides the initializer " + initializer->selectorAsString() +
        ". A class extending a native type runs its constructor for every initializer: move "
        "this logic to the constructor, and choose the super initializer with "
        "super({ [interop.initializer.args]: { ... } }).");
  }
}

void ClassBuilder::ExposeDynamicMembers(v8::Local<v8::Context> context, Class extendedClass,
                                        Local<Object> implementationObject,
                                        Local<Object> nativeSignature) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Value> exposedMethods;
  bool success = nativeSignature->Get(context, tns::ToV8String(isolate, "exposedMethods"))
                     .ToLocal(&exposedMethods);
  tns::Assert(success, isolate);

  Local<Value> exposedProtocols;
  success = nativeSignature->Get(context, tns::ToV8String(isolate, "protocols"))
                .ToLocal(&exposedProtocols);
  tns::Assert(success, isolate);

  ClassBuilder::ExposeDynamicMethods(context, extendedClass, exposedMethods, exposedProtocols,
                                     implementationObject);
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding) {
  BinaryTypeEncodingType type = typeEncoding->type;
  switch (type) {
    case BinaryTypeEncodingType::VoidEncoding: {
      return @encode(void);
    }
    case BinaryTypeEncodingType::BoolEncoding: {
      return @encode(bool);
    }
    case BinaryTypeEncodingType::UnicharEncoding:
    case BinaryTypeEncodingType::UShortEncoding: {
      return @encode(ushort);
    }
    case BinaryTypeEncodingType::ShortEncoding: {
      return @encode(short);
    }
    case BinaryTypeEncodingType::UIntEncoding: {
      return @encode(uint);
    }
    case BinaryTypeEncodingType::IntEncoding: {
      return @encode(int);
    }
#if defined(__LP64__)
    case BinaryTypeEncodingType::ULongEncoding: {
      return @encode(uint64_t);
    }
    case BinaryTypeEncodingType::LongEncoding: {
      return @encode(int64_t);
    }
#else
    case BinaryTypeEncodingType::ULongEncoding: {
      return @encode(uint32_t);
    }
    case BinaryTypeEncodingType::LongEncoding: {
      return @encode(int32_t);
    }
#endif
    case BinaryTypeEncodingType::ULongLongEncoding: {
      return @encode(unsigned long long);
    }
    case BinaryTypeEncodingType::LongLongEncoding: {
      return @encode(long long);
    }
    case BinaryTypeEncodingType::UCharEncoding: {
      return @encode(unsigned char);
    }
    case BinaryTypeEncodingType::CharEncoding: {
      return @encode(char);
    }
    case BinaryTypeEncodingType::FloatEncoding: {
      return @encode(float);
    }
    case BinaryTypeEncodingType::DoubleEncoding: {
      return @encode(double);
    }
    case BinaryTypeEncodingType::CStringEncoding: {
      return @encode(char*);
    }
    case BinaryTypeEncodingType::ClassEncoding: {
      return @encode(Class);
    }
    case BinaryTypeEncodingType::SelectorEncoding: {
      return @encode(SEL);
    }
    case BinaryTypeEncodingType::BlockEncoding: {
      return @encode(dispatch_block_t);
    }
    case BinaryTypeEncodingType::StructDeclarationReference: {
      const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
      const Meta* meta = ArgConverter::GetMeta(structName);
      tns::Assert(meta != nullptr && meta->type() == MetaType::Struct);
      const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
      const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

      std::stringstream ss;
      ss << "{" << structName << "=";
      for (int i = 0; i < structMeta->fieldsCount(); i++) {
        ss << GetTypeEncoding(fieldEncoding);
        fieldEncoding = fieldEncoding->next();
      }
      ss << "}";
      return ss.str();
    }
    case BinaryTypeEncodingType::PointerEncoding: {
      std::stringstream ss;
      ss << "^";
      const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();
      ss << GetTypeEncoding(innerType);
      return ss.str();
    }
    case BinaryTypeEncodingType::ConstantArrayEncoding: {
      const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
      std::stringstream ss;
      ss << "[";
      ss << typeEncoding->details.constantArray.size << GetTypeEncoding(innerType);
      ss << "]";
      return ss.str();
    }
    case BinaryTypeEncodingType::IncompleteArrayEncoding: {
      const TypeEncoding* innerType = typeEncoding->details.incompleteArray.getInnerType();
      std::stringstream ss;
      ss << "^";
      ss << GetTypeEncoding(innerType);
      return ss.str();
    }
    case BinaryTypeEncodingType::ProtocolEncoding:
    case BinaryTypeEncodingType::InterfaceDeclarationReference:
    case BinaryTypeEncodingType::InstanceTypeEncoding:
    case BinaryTypeEncodingType::IdEncoding: {
      return "@";
    }

    default:
      // TODO: Handle the other possible types
      tns::Assert(false);
      return "";
  }
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding, int argsCount) {
  std::stringstream compilerEncoding;
  compilerEncoding << GetTypeEncoding(typeEncoding);
  compilerEncoding << "@:";  // id self, SEL _cmd

  for (int i = 0; i < argsCount; i++) {
    typeEncoding = typeEncoding->next();
    compilerEncoding << GetTypeEncoding(typeEncoding);
  }

  return compilerEncoding.str();
}

BinaryTypeEncodingType ClassBuilder::GetTypeEncodingType(Isolate* isolate, Local<Value> value) {
  if (BaseDataWrapper* wrapper = tns::GetValue(isolate, value)) {
    if (wrapper->Type() == WrapperType::ObjCClass) {
      return BinaryTypeEncodingType::IdEncoding;
    } else if (wrapper->Type() == WrapperType::ObjCProtocol) {
      return BinaryTypeEncodingType::IdEncoding;
    } else if (wrapper->Type() == WrapperType::Primitive) {
      PrimitiveDataWrapper* pdw = static_cast<PrimitiveDataWrapper*>(wrapper);
      return pdw->TypeEncoding()->type;
    } else if (wrapper->Type() == WrapperType::ObjCObject) {
      return BinaryTypeEncodingType::IdEncoding;
    } else if (wrapper->Type() == WrapperType::PointerType) {
      return BinaryTypeEncodingType::PointerEncoding;
    }
  }

  //  TODO: Unknown encoding type
  tns::Assert(false, isolate);
  return BinaryTypeEncodingType::VoidEncoding;
}

void ClassBuilder::ExposeDynamicMethods(Local<Context> context, Class extendedClass,
                                        Local<Value> exposedMethods, Local<Value> exposedProtocols,
                                        Local<Object> implementationObject) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  // A subclass of a JS-defined class inherits its parent's implementations through the
  // Objective-C hierarchy; installing what it only inherits in JS would duplicate them.
  bool inheritsJsClass =
      class_conformsToProtocol(class_getSuperclass(extendedClass), @protocol(TNSDerivedClass));
  auto isOwnMember = [&](Local<v8::Name> key) {
    bool own = false;
    return !inheritsJsClass || (implementationObject->HasOwnProperty(context, key).To(&own) && own);
  };
  std::vector<const ProtocolMeta*> protocols;
  if (!exposedProtocols.IsEmpty() && exposedProtocols->IsArray()) {
    Local<v8::Array> protocolsArray = exposedProtocols.As<v8::Array>();
    for (uint32_t i = 0; i < protocolsArray->Length(); i++) {
      Local<Value> element;
      bool success = protocolsArray->Get(context, i).ToLocal(&element);
      tns::Assert(success && !element.IsEmpty() && element->IsFunction(), isolate);

      Local<v8::Function> protoObj = element.As<v8::Function>();
      BaseDataWrapper* wrapper = tns::GetValue(isolate, protoObj);
      tns::Assert(wrapper && wrapper->Type() == WrapperType::ObjCProtocol, isolate);
      ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrapper);
      Protocol* proto = protoWrapper->Proto();
      if (proto != nil && !class_conformsToProtocol(extendedClass, proto)) {
        class_addProtocol(extendedClass, proto);
        class_addProtocol(object_getClass(extendedClass), proto);
      }

      protocols.push_back(protoWrapper->ProtoMeta());
    }
  }

  if (!exposedMethods.IsEmpty() && exposedMethods->IsObject()) {
    Local<v8::Array> methodNames;
    if (!exposedMethods.As<Object>()->GetOwnPropertyNames(context).ToLocal(&methodNames)) {
      tns::Assert(false, isolate);
    }

    for (int i = 0; i < methodNames->Length(); i++) {
      Local<Value> methodName;
      bool success = methodNames->Get(context, i).ToLocal(&methodName);
      tns::Assert(success, isolate);

      if (!methodName->IsName() || !isOwnMember(methodName.As<v8::Name>())) {
        continue;
      }

      Local<Value> methodSignature;
      success = exposedMethods.As<Object>()->Get(context, methodName).ToLocal(&methodSignature);
      tns::Assert(success && methodSignature->IsObject(), isolate);

      Local<Value> method;
      success = implementationObject->Get(context, methodName).ToLocal(&method);
      tns::Assert(success, isolate);

      if (method.IsEmpty() || !method->IsFunction()) {
        Log(@"No implementation found for exposed method \"%s\"",
            tns::ToString(isolate, methodName).c_str());
        continue;
      }

      Local<Value> returnsVal;
      success = methodSignature.As<Object>()
                    ->Get(context, tns::ToV8String(isolate, "returns"))
                    .ToLocal(&returnsVal);
      tns::Assert(success, isolate);

      Local<Value> paramsVal;
      success = methodSignature.As<Object>()
                    ->Get(context, tns::ToV8String(isolate, "params"))
                    .ToLocal(&paramsVal);
      tns::Assert(success, isolate);

      if (returnsVal.IsEmpty() || !returnsVal->IsObject()) {
        // Incorrect exposedMethods definition: missing returns property
        tns::Assert(false, isolate);
      }

      int argsCount = 0;
      if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
        argsCount = paramsVal.As<v8::Array>()->Length();
      }

      BinaryTypeEncodingType returnType = GetTypeEncodingType(isolate, returnsVal);

      std::string methodNameStr = tns::ToString(isolate, methodName);
      SEL selector = sel_registerName(methodNameStr.c_str());

      // TODO: Investigate and maybe find a way to free this
      // Currently this is added to the meta cache by the Interop::CreateMethod
      // but when the isolate dies we might need to free it? Or maybe this is cached throughout all
      // isolates
      TypeEncoding* typeEncoding =
          reinterpret_cast<TypeEncoding*>(calloc((argsCount + 1), sizeof(TypeEncoding)));
      typeEncoding->type = returnType;

      if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
        Local<v8::Array> params = paramsVal.As<v8::Array>();
        TypeEncoding* next = typeEncoding;
        for (int i = 0; i < params->Length(); i++) {
          next = const_cast<TypeEncoding*>(next->next());
          Local<Value> param;
          success = params->Get(context, i).ToLocal(&param);
          tns::Assert(success, isolate);

          next->type = GetTypeEncodingType(isolate, param);
        }
      }

      std::shared_ptr<Persistent<Value>> poCallback =
          std::make_shared<Persistent<Value>>(isolate, method);
      MethodCallbackWrapper* userData =
          new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
      IMP methodBody =
          Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
      std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
      tns::Assert(class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str()), isolate);
    }
  }

  const Meta* m = ArgConverter::FindMeta(extendedClass);
  if (m == nullptr) {
    return;
  }

  const BaseClassMeta* extendedClassMeta = static_cast<const BaseClassMeta*>(m);

  Local<v8::Array> propertyNames;

  Local<Value> symbolIterator;
  bool success =
      implementationObject->Get(context, Symbol::GetIterator(isolate)).ToLocal(&symbolIterator);
  tns::Assert(success, isolate);

  if (!symbolIterator.IsEmpty() && symbolIterator->IsFunction() &&
      isOwnMember(Symbol::GetIterator(isolate))) {
    Local<v8::Function> symbolIteratorFunc = symbolIterator.As<v8::Function>();

    class_addProtocol(extendedClass, @protocol(NSFastEnumeration));
    class_addProtocol(object_getClass(extendedClass), @protocol(NSFastEnumeration));

    Persistent<v8::Function>* poIteratorFunc =
        new Persistent<v8::Function>(isolate, symbolIteratorFunc);
    IMP imp = imp_implementationWithBlock(^NSUInteger(id self, NSFastEnumerationState* state,
                                                      __unsafe_unretained id buffer[],
                                                      NSUInteger length) {
      return tns::FastEnumerationAdapter(isolate, self, state, buffer, length, poIteratorFunc);
    });

    struct objc_method_description fastEnumerationMethodDescription = protocol_getMethodDescription(
        @protocol(NSFastEnumeration), @selector(countByEnumeratingWithState:objects:count:), YES,
        YES);
    tns::Assert(
        class_addMethod(extendedClass, @selector(countByEnumeratingWithState:objects:count:), imp,
                        fastEnumerationMethodDescription.types),
        isolate);
  }

  // Use ALL_PROPERTIES so that non-enumerable members are picked up too - methods and accessors
  // declared with ES class syntax are non-enumerable, unlike the plain object literals passed to
  // the legacy `.extend()` API.
  PropertyFilter propertyFilter =
      static_cast<PropertyFilter>(PropertyFilter::ALL_PROPERTIES | PropertyFilter::SKIP_SYMBOLS);
  tns::Assert(
      implementationObject->GetOwnPropertyNames(context, propertyFilter).ToLocal(&propertyNames),
      isolate);
  for (uint32_t i = 0; i < propertyNames->Length(); i++) {
    Local<Value> key;
    bool success = propertyNames->Get(context, i).ToLocal(&key);
    tns::Assert(success, isolate);
    if (!key->IsName()) {
      continue;
    }

    std::string methodName = tns::ToString(isolate, key);

    if (methodName == "constructor") {
      continue;
    }

    Local<Value> propertyDescriptor;
    tns::Assert(implementationObject->GetOwnPropertyDescriptor(context, key.As<v8::Name>())
                    .ToLocal(&propertyDescriptor),
                isolate);
    if (propertyDescriptor.IsEmpty() || propertyDescriptor->IsNullOrUndefined()) {
      continue;
    }

    Local<Value> getter;
    success = propertyDescriptor.As<Object>()
                  ->Get(context, tns::ToV8String(isolate, "get"))
                  .ToLocal(&getter);
    tns::Assert(success, isolate);

    Local<Value> setter;
    success = propertyDescriptor.As<Object>()
                  ->Get(context, tns::ToV8String(isolate, "set"))
                  .ToLocal(&setter);
    tns::Assert(success, isolate);

    if ((!getter.IsEmpty() || !setter.IsEmpty()) &&
        (getter->IsFunction() || setter->IsFunction())) {
      std::vector<const PropertyMeta*> propertyMetas;
      VisitProperties(methodName, extendedClassMeta, propertyMetas, protocols);
      ExposeProperties(isolate, extendedClass, propertyMetas, implementationObject, getter, setter);
      continue;
    }

    Local<Value> method;
    success = propertyDescriptor.As<Object>()
                  ->Get(context, tns::ToV8String(isolate, "value"))
                  .ToLocal(&method);
    tns::Assert(success, isolate);

    if (method.IsEmpty() || !method->IsFunction()) {
      continue;
    }

    std::vector<const MethodMeta*> methodMetas;
    VisitMethods(extendedClass, methodName, extendedClassMeta, methodMetas, protocols);

    for (int j = 0; j < methodMetas.size(); j++) {
      const MethodMeta* methodMeta = methodMetas[j];
      std::shared_ptr<Persistent<Value>> poCallback =
          std::make_shared<Persistent<Value>>(isolate, method);
      const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
      uint8_t argsCount = methodMeta->encodings()->count - 1;
      MethodCallbackWrapper* userData =
          new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
      SEL selector = methodMeta->selector();
      IMP methodBody =
          Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
      std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
      class_replaceMethod(extendedClass, selector, methodBody, typeInfo.c_str());
    }
  }
}

void ClassBuilder::VisitProperties(std::string propertyName, const BaseClassMeta* meta,
                                   std::vector<const PropertyMeta*>& propertyMetas,
                                   std::vector<const ProtocolMeta*> exposedProtocols) {
  for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
    const PropertyMeta* propertyMeta = (*it).valuePtr();
    if (propertyMeta->jsName() == propertyName &&
        std::find(propertyMetas.begin(), propertyMetas.end(), propertyMeta) ==
            propertyMetas.end()) {
      propertyMetas.push_back(propertyMeta);
    }
  }

  for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
    const char* protocolName = (*protoIt).valuePtr();
    const Meta* m = ArgConverter::GetMeta(protocolName);
    if (!m) {
      continue;
    }
    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
    VisitProperties(propertyName, protocolMeta, propertyMetas, exposedProtocols);
  }

  for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
    const ProtocolMeta* protocolMeta = *it;
    VisitProperties(propertyName, protocolMeta, propertyMetas, std::vector<const ProtocolMeta*>());
  }

  if (meta->type() == MetaType::Interface) {
    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
    if (baseMeta != nullptr) {
      VisitProperties(propertyName, baseMeta, propertyMetas, exposedProtocols);
    }
  }
}

void ClassBuilder::VisitMethods(Class extendedClass, std::string methodName,
                                const BaseClassMeta* meta,
                                std::vector<const MethodMeta*>& methodMetas,
                                std::vector<const ProtocolMeta*> exposedProtocols) {
  for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
    const MethodMeta* methodMeta = (*it).valuePtr();
    if (methodMeta->jsName() == methodName) {
      if (std::find(methodMetas.begin(), methodMetas.end(), methodMeta) == methodMetas.end()) {
        methodMetas.push_back(methodMeta);
      }
    }
  }

  for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
    const char* protocolName = (*protoIt).valuePtr();
    const Meta* m = ArgConverter::GetMeta(protocolName);
    if (!m) {
      continue;
    }
    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
    VisitMethods(extendedClass, methodName, protocolMeta, methodMetas, exposedProtocols);
  }

  for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
    const ProtocolMeta* protocolMeta = *it;
    VisitMethods(extendedClass, methodName, protocolMeta, methodMetas,
                 std::vector<const ProtocolMeta*>());
  }

  if (meta->type() == MetaType::Interface) {
    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
    if (baseMeta != nullptr) {
      VisitMethods(extendedClass, methodName, interfaceMeta->baseMeta(), methodMetas,
                   exposedProtocols);
    }
  }
}

void ClassBuilder::ExposeProperties(Isolate* isolate, Class extendedClass,
                                    std::vector<const PropertyMeta*> propertyMetas,
                                    Local<Object> implementationObject, Local<Value> getter,
                                    Local<Value> setter) {
  for (int j = 0; j < propertyMetas.size(); j++) {
    const PropertyMeta* propertyMeta = propertyMetas[j];
    std::string propertyName = propertyMeta->name();

    bool hasGetter = !getter.IsEmpty() && getter->IsFunction() && propertyMeta->hasGetter();
    bool hasSetter = !setter.IsEmpty() && setter->IsFunction() && propertyMeta->hasSetter();

    std::shared_ptr<Persistent<Object>> poImplementationObject;
    if (hasGetter || hasSetter) {
      poImplementationObject = std::make_shared<Persistent<Object>>(isolate, implementationObject);
    }

    if (hasGetter) {
      std::shared_ptr<Persistent<v8::Function>> poGetterFunc =
          std::make_shared<Persistent<v8::Function>>(isolate, getter.As<v8::Function>());
      PropertyCallbackContext* userData =
          new PropertyCallbackContext(isolate, poGetterFunc, poImplementationObject, propertyMeta);

      FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues,
                                            void* userData) {
        PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
        Isolate* isolate = context->isolate_;
        // Scopes-before-@throw: a branded escape is captured and @thrown only
        // after every V8 scope in the inner block has destructed.
        NSException* __strong pendingThrow = nil;
        {
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          Local<v8::Function> getterFunc = context->callback_->Get(isolate);
          Local<Value> res;

          id thiz = *static_cast<const id*>(argValues[0]);
          auto cache = Caches::Get(isolate);
          auto it = cache->Instances.find(thiz);
          Local<Object> self_ = it != cache->Instances.end()
                                    ? it->second->Get(isolate).As<Object>()
                                    : context->implementationObject_->Get(isolate);
          Local<Context> v8Context = Caches::Get(isolate)->GetContext();
          TryCatch tc(isolate);
          if (!getterFunc->Call(v8Context, self_, 0, nullptr).ToLocal(&res)) {
            NSException* ex = ArgConverter::HandleBoundaryException(v8Context, tc);
            if (ex != nil) {
              pendingThrow = ex;
            }
            // Default getter result on a JS throw: zeroed return buffer.
            memset(retValue, 0, cif->rtype->size);
          } else {
            const TypeEncoding* typeEncoding = context->meta_->getter()->encodings()->first();
            ArgConverter::SetValue(v8Context, retValue, cif->rtype->size, res, typeEncoding);
          }
        }
        if (pendingThrow != nil) {
          @throw pendingThrow;
        }
      };
      const TypeEncoding* typeEncoding = propertyMeta->getter()->encodings()->first();
      IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback, userData);

      class_addMethod(extendedClass, propertyMeta->getter()->selector(), impGetter, "@@:");
    }

    if (hasSetter) {
      std::shared_ptr<Persistent<v8::Function>> poSetterFunc =
          std::make_shared<Persistent<v8::Function>>(isolate, setter.As<v8::Function>());
      PropertyCallbackContext* userData =
          new PropertyCallbackContext(isolate, poSetterFunc, poImplementationObject, propertyMeta);

      FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues,
                                            void* userData) {
        PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
        Isolate* isolate = context->isolate_;
        NSException* __strong pendingThrow = nil;
        {
          v8::Locker locker(isolate);
          Isolate::Scope isolate_scope(isolate);
          HandleScope handle_scope(isolate);
          Local<v8::Function> setterFunc = context->callback_->Get(isolate);
          Local<Value> res;

          id thiz = *static_cast<const id*>(argValues[0]);
          auto cache = Caches::Get(isolate);
          auto it = cache->Instances.find(thiz);
          Local<Object> self_ = it != cache->Instances.end()
                                    ? it->second->Get(isolate).As<Object>()
                                    : context->implementationObject_->Get(isolate);

          uint8_t* argBuffer = (uint8_t*)argValues[2];
          const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
          BaseCall call(argBuffer);
          Local<Context> v8Context = Caches::Get(isolate)->GetContext();
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
      IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

      class_addMethod(extendedClass, propertyMeta->setter()->selector(), impSetter, "v@:@");
    }
  }
}

void ClassBuilder::SuperAccessorGetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> thiz = info.This();

  // Resolved from the class that owns this accessor, not from the receiver: an ES subclass of a
  // legacy class puts more prototypes between the instance and the implementation object.
  CacheItem* item = static_cast<CacheItem*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  auto cache = Caches::Get(isolate);
  auto it = cache->ClassPrototypes.find(std::string_view(class_getName(item->data_)));
  tns::Assert(it != cache->ClassPrototypes.end(), isolate);
  Local<Object> implementationObject = it->second->Get(isolate)->GetPrototype().As<Object>();

  std::shared_ptr<Persistent<Value>> poValue = ArgConverter::CreateEmptyObject(context);
  Local<Object> superValue = poValue->Get(isolate).As<Object>();

  superValue->SetPrototype(context, implementationObject->GetPrototype()).ToChecked();
  superValue->SetInternalField(0, thiz->GetInternalField(0));
  superValue->SetInternalField(1, tns::ToV8String(isolate, "super"));

  info.GetReturnValue().Set(superValue);
}

Class ClassBuilder::GetNativeSuperclass(Class klass) {
  // Every native call on an extended instance asks this, and a class's superclass chain never
  // changes once registered, so the walk over each level's protocol list runs once per class.
  // Per thread, so the hot path takes no lock.
  thread_local robin_hood::unordered_map<Class, Class> nativeSuperclasses;
  auto it = nativeSuperclasses.find(klass);
  if (it != nativeSuperclasses.end()) {
    return it->second;
  }

  Class rootmostDerived = nil;
  for (Class c = klass; c != nil; c = class_getSuperclass(c)) {
    if (class_conformsToProtocol(c, @protocol(TNSDerivedClass))) {
      rootmostDerived = c;
    }
  }
  Class nativeSuperclass = class_getSuperclass(rootmostDerived != nil ? rootmostDerived : klass);
  nativeSuperclasses.emplace(klass, nativeSuperclass);
  return nativeSuperclass;
}

IMP ClassBuilder::FindNotOverridenMethod(Class klass, SEL method) {
  while (class_conformsToProtocol(klass, @protocol(TNSDerivedClass))) {
    klass = class_getSuperclass(klass);
  }

  return class_getMethodImplementation(klass, method);
}

std::atomic<unsigned long long> ClassBuilder::classNameCounter_{0};

}  // namespace tns
