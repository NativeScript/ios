#include "ClassBuilder.h"
#include "WrapperLifetime.h"
#include <Foundation/Foundation.h>
#include <numeric>
#include <sstream>
#include <unordered_set>
#include "ArgConverter.h"
#include "BuiltinLoader.h"
#include "Caches.h"
#include "FastEnumerationAdapter.h"
#include "Helpers.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "TNSDerivedClass.h"
#include "WrapperLifetimeCanary.h"

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

// The classes an isolate gave the -retain/-release pair that protects and
// unprotects an instance's wrapper. The pair looks the wrapper up in that
// isolate only, so another isolate's wrapper of the same instance is never
// unprotected by it.
struct RetainTrackedClasses {
  std::unordered_set<void*> classes;
};
}  // namespace

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
    WrapperLifetimeCanary::InstallDeallocHook(extendedClass);

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
    WrapperLifetimeCanary::ConfigureInstanceTemplate(
        extendedClassCtorFuncTemplate->InstanceTemplate());

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
    Class klass = item->data_;

    ArgConverter::ConstructObject(context, info, klass);
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
        WrapperLifetimeCanary::InstallDeallocHook(extendedClass);

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

        // The rooted lifetime mode reads native ownership from retain counts
        // when a major collection starts, so it needs no swizzle.
        if (GetWrapperLifetimeMode() == WrapperLifetimeMode::kResurrecting) {
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
                    if (objcWrapper->OwnershipState() != nullptr) {
                      ObjectManager::ReconcileOwnership(isolate, objcWrapper);
                    } else {
                      objcWrapper->GcProtect();
                    }
                  }
                }
              };
              // After the retain: reconciling reads the new retain count.
              id result = retain(self, @selector(retain));
              if (CFRunLoopGetCurrent() != runtimeLoop) {
                // bare entry: the closure does its own Locker ceremony, exactly
                // like the performed block it replaces
                runtime->GetEventLoop()->PostInternalBare(gcProtect);
              } else {
                gcProtect();
              }
              return result;
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
                      if (objcWrapper->OwnershipState() != nullptr) {
                        ObjectManager::ReconcileOwnership(isolate, objcWrapper);
                      } else {
                        objcWrapper->GcUnprotect();
                      }
                    }
                  }
                }
              };
              auto runtime = Runtime::GetRuntime(isolate);
              auto runtimeLoop = runtime->RuntimeLoop();
              // After the release: reconciling reads the new retain count, and
              // the Instances entry still holds the object.
              release(self, @selector(release));
              if (CFRunLoopGetCurrent() != runtimeLoop) {
                // bare entry: the closure does its own Locker ceremony, exactly
                // like the performed block it replaces
                runtime->GetEventLoop()->PostInternalBare(gcUnprotect);
              } else {
                gcUnprotect();
              }
              return;
            }

            release(self, @selector(release));
          });
          class_addMethod(extendedClass, @selector(release), newRelease, "v@:");
          if (auto* tracked = Caches::StateFor<RetainTrackedClasses>(isolate)) {
            tracked->classes.insert((__bridge void*)extendedClass);
          }
        }

        info.GetReturnValue().SetUndefined();
      }).ToLocalChecked();

  PropertyAttribute flags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete);
  bool success =
      global->DefineOwnProperty(context, tns::ToV8String(isolate, "__extends"), extendsFunc, flags)
          .FromMaybe(false);
  tns::Assert(success, isolate);
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

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding, bool* encodable,
                                          bool expandStructures, bool expandPointedToStructures) {
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
      if (!expandStructures) {
        return std::string("{") + structName + "}";
      }
      const Meta* meta = ArgConverter::GetMeta(structName);
      if (encodable != nullptr && (meta == nullptr || meta->type() != MetaType::Struct)) {
        *encodable = false;
        return "";
      }
      tns::Assert(meta != nullptr && meta->type() == MetaType::Struct);
      const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
      const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

      std::stringstream ss;
      ss << "{" << structName << "=";
      for (int i = 0; i < structMeta->fieldsCount(); i++) {
        ss << GetTypeEncoding(fieldEncoding, encodable, true, false);
        fieldEncoding = fieldEncoding->next();
      }
      ss << "}";
      return ss.str();
    }
    case BinaryTypeEncodingType::PointerEncoding: {
      std::stringstream ss;
      ss << "^";
      const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();
      ss << GetTypeEncoding(innerType, encodable, expandPointedToStructures, false);
      return ss.str();
    }
    case BinaryTypeEncodingType::ConstantArrayEncoding: {
      const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
      std::stringstream ss;
      ss << "[";
      ss << typeEncoding->details.constantArray.size
         << GetTypeEncoding(innerType, encodable, expandStructures, false);
      ss << "]";
      return ss.str();
    }
    case BinaryTypeEncodingType::IncompleteArrayEncoding: {
      const TypeEncoding* innerType = typeEncoding->details.incompleteArray.getInnerType();
      std::stringstream ss;
      ss << "^";
      ss << GetTypeEncoding(innerType, encodable, expandStructures, false);
      return ss.str();
    }
    case BinaryTypeEncodingType::FunctionPointerEncoding: {
      return "^?";
    }
    case BinaryTypeEncodingType::ProtocolEncoding:
    case BinaryTypeEncodingType::InterfaceDeclarationReference:
    case BinaryTypeEncodingType::InstanceTypeEncoding:
    case BinaryTypeEncodingType::IdEncoding: {
      return "@";
    }

    default:
      // TODO: Handle the other possible types
      if (encodable != nullptr) {
        *encodable = false;
        return "";
      }
      tns::Assert(false);
      return "";
  }
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding, int argsCount,
                                          bool* encodable) {
  std::stringstream compilerEncoding;
  compilerEncoding << GetTypeEncoding(typeEncoding, encodable);
  compilerEncoding << "@:";  // id self, SEL _cmd

  for (int i = 0; i < argsCount; i++) {
    typeEncoding = typeEncoding->next();
    compilerEncoding << GetTypeEncoding(typeEncoding, encodable);
  }

  return compilerEncoding.str();
}

std::string ClassBuilder::GetAccessorTypeEncoding(const TypeEncoding* typeEncoding, int argsCount,
                                                  const char* fallback) {
  bool encodable = true;
  std::string encoding = GetTypeEncoding(typeEncoding, argsCount, &encodable);
  return encodable ? encoding : fallback;
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
      MethodCallbackWrapper* userData = new MethodCallbackWrapper(
          isolate, poCallback, 2, argsCount, typeEncoding,
          ArgConverter::ReturnOwnership(selector, nullptr),
          Interop::ConsumedObjectArgumentIndex(selector, typeEncoding, argsCount));
      IMP methodBody =
          Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
      std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
      IMP installed = WrapperLifetimeCanary::WrapDealloc(selector, methodBody);
      if (installed != methodBody) {
        // Replaces the canary dealloc hook the class already carries.
        class_replaceMethod(extendedClass, selector, installed, typeInfo.c_str());
      } else {
        tns::Assert(class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str()),
                    isolate);
      }
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

  if (!symbolIterator.IsEmpty() && symbolIterator->IsFunction()) {
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

  tns::Assert(implementationObject->GetOwnPropertyNames(context).ToLocal(&propertyNames), isolate);
  for (uint32_t i = 0; i < propertyNames->Length(); i++) {
    Local<Value> key;
    bool success = propertyNames->Get(context, i).ToLocal(&key);
    tns::Assert(success, isolate);
    if (!key->IsName()) {
      continue;
    }

    std::string methodName = tns::ToString(isolate, key);

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
      ExposeProperties(isolate, extendedClass, propertyMetas, getter, setter);
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
      SEL selector = methodMeta->selector();
      MethodCallbackWrapper* userData = new MethodCallbackWrapper(
          isolate, poCallback, 2, argsCount, typeEncoding,
          ArgConverter::ReturnOwnership(selector, methodMeta),
          Interop::ConsumedObjectArgumentIndex(selector, typeEncoding, argsCount));
      IMP methodBody =
          Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
      std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
      class_replaceMethod(extendedClass, selector,
                          WrapperLifetimeCanary::WrapDealloc(selector, methodBody),
                          typeInfo.c_str());
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

// Reads the class's own method list: class_getInstanceMethod asks the class to
// resolve a selector nothing implements, which initializes a class that is
// still being built.
bool ClassBuilder::ImplementsItself(Class klass, SEL selector) {
  unsigned int count = 0;
  Method* methods = class_copyMethodList(klass, &count);
  bool found = false;
  for (unsigned int i = 0; i < count && !found; i++) {
    found = method_getName(methods[i]) == selector;
  }
  free(methods);
  return found;
}

void ClassBuilder::ExposeProperties(Isolate* isolate, Class extendedClass,
                                    std::vector<const PropertyMeta*> propertyMetas,
                                    Local<Value> getter, Local<Value> setter) {
  for (int j = 0; j < propertyMetas.size(); j++) {
    const PropertyMeta* propertyMeta = propertyMetas[j];
    std::string propertyName = propertyMeta->name();

    // An accessor the class already implements itself came from an earlier
    // metadata entry or exposedMethods; class_addMethod would refuse it.
    bool hasGetter = !getter.IsEmpty() && getter->IsFunction() && propertyMeta->hasGetter() &&
                     !ImplementsItself(extendedClass, propertyMeta->getter()->selector());
    bool hasSetter = !setter.IsEmpty() && setter->IsFunction() && propertyMeta->hasSetter() &&
                     !ImplementsItself(extendedClass, propertyMeta->setter()->selector());

    if (hasGetter) {
      std::shared_ptr<Persistent<v8::Function>> poGetterFunc =
          std::make_shared<Persistent<v8::Function>>(isolate, getter.As<v8::Function>());
      PropertyCallbackContext* userData =
          new PropertyCallbackContext(isolate, poGetterFunc, propertyMeta);

      FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues,
                                            void* userData) {
        PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
        Isolate* isolate = context->isolateWrapper_.Isolate();
        // Scopes-before-@throw: a branded escape is captured and @thrown only
        // after every V8 scope in the inner block has destructed.
        NSException* __strong pendingThrow = nil;
        {
          // Validity is checked before and again after taking the Locker, for
          // the reasons given in ArgConverter::MethodCallback.
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

          Local<Context> v8Context = Caches::Get(isolate)->GetContext();
          Context::Scope context_scope(v8Context);
          NativeCallbackSelf receiver(v8Context, *static_cast<const id*>(argValues[0]));
          TryCatch tc(isolate);
          if (!getterFunc->Call(v8Context, receiver.Get(), 0, nullptr).ToLocal(&res)) {
            NSException* ex = ArgConverter::HandleBoundaryException(v8Context, tc);
            if (ex != nil) {
              pendingThrow = ex;
            }
            // Default getter result on a JS throw: zeroed return buffer.
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
      IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback, userData);
      std::string types = GetAccessorTypeEncoding(typeEncoding, 0, "@@:");

      class_addMethod(extendedClass, propertyMeta->getter()->selector(), impGetter, types.c_str());
    }

    if (hasSetter) {
      std::shared_ptr<Persistent<v8::Function>> poSetterFunc =
          std::make_shared<Persistent<v8::Function>>(isolate, setter.As<v8::Function>());
      PropertyCallbackContext* userData =
          new PropertyCallbackContext(isolate, poSetterFunc, propertyMeta);

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
          Context::Scope context_scope(v8Context);
          NativeCallbackSelf receiver(v8Context, *static_cast<const id*>(argValues[0]));

          uint8_t* argBuffer = (uint8_t*)argValues[2];
          const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
          BaseCall call(argBuffer);
          Local<Value> jsWrapper = Interop::GetResult(v8Context, typeEncoding, &call, true);
          Local<Value> params[1] = {jsWrapper};

          TryCatch tc(isolate);
          if (!setterFunc->Call(v8Context, receiver.Get(), 1, params).ToLocal(&res)) {
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
      std::string types = GetAccessorTypeEncoding(typeEncoding, 1, "v@:@");

      class_addMethod(extendedClass, propertyMeta->setter()->selector(), impSetter, types.c_str());
    }
  }
}

void ClassBuilder::SuperAccessorGetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  // Copying the implementation object or the class prototype (Object.assign,
  // spread) reads `super` with a receiver that is no native instance: like the
  // other native accessors, it reads undefined.
  Local<Value> target = tns::UnwrapProxy(info.This());
  if (target.IsEmpty() || !target->IsObject() || target.As<Object>()->InternalFieldCount() < 1) {
    return;
  }
  // Field 0 holds the object that carries the wrapper, never another alias,
  // so resolving an alias takes one step.
  Local<Object> receiver = tns::SuperAliasReceiver(target.As<Object>());
  if (receiver.IsEmpty()) {
    receiver = target.As<Object>();
  }

  // receiver -> extended class prototype -> implementation object -> base
  // class prototype.
  Local<Value> superPrototype = receiver;
  for (int i = 0; i < 3; i++) {
    if (!superPrototype->IsObject()) {
      return;
    }
    superPrototype = superPrototype.As<Object>()->GetPrototype();
  }

  // An alias owns no wrapper, so it is not registered with ObjectManager.
  Local<Object> superValue =
      ArgConverter::NewEmptyInstance(context, Caches::Get(isolate)->EmptyObjCtorFunc.get());
  superValue->SetPrototype(context, superPrototype).ToChecked();
  superValue->SetInternalField(0, receiver);
  superValue->SetInternalField(1, tns::ToV8String(isolate, "super"));

  info.GetReturnValue().Set(superValue);
}

Class ClassBuilder::FindNativeClass(Class klass) {
  // Walks the whole chain: key-value observing puts a subclass that does not
  // conform below the JS class, and class_conformsToProtocol does not look at
  // superclasses.
  Class native = klass;
  for (Class cls = klass; cls != nil; cls = class_getSuperclass(cls)) {
    if (class_conformsToProtocol(cls, @protocol(TNSDerivedClass))) {
      native = class_getSuperclass(cls);
    }
  }
  return native;
}

bool ClassBuilder::TracksNativeRetains(Isolate* isolate, Class klass) {
  RetainTrackedClasses* tracked = Caches::ExistingStateFor<RetainTrackedClasses>(isolate);
  if (tracked == nullptr || tracked->classes.empty()) {
    return false;
  }
  for (; klass != nil; klass = class_getSuperclass(klass)) {
    if (tracked->classes.count((__bridge void*)klass) != 0) {
      return true;
    }
  }
  return false;
}

IMP ClassBuilder::FindNotOverridenMethod(Class klass, SEL method) {
  return class_getMethodImplementation(FindNativeClass(klass), method);
}

std::atomic<unsigned long long> ClassBuilder::classNameCounter_{0};

}  // namespace tns
