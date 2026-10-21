#ifndef ClassBuilder_h
#define ClassBuilder_h

#include <string>
#include <vector>

#include "Common.h"
#include "Metadata.h"

namespace tns {

struct PropertyCallbackContext {
 public:
  PropertyCallbackContext(
      v8::Isolate* isolate,
      std::shared_ptr<v8::Persistent<v8::Function>> callback,
      std::shared_ptr<v8::Persistent<v8::Object>> implementationObject,
      const PropertyMeta* meta)
      : isolate_(isolate),
        callback_(callback),
        implementationObject_(implementationObject),
        meta_(meta) {}
  v8::Isolate* isolate_;
  std::shared_ptr<v8::Persistent<v8::Function>> callback_;
  std::shared_ptr<v8::Persistent<v8::Object>> implementationObject_;
  const PropertyMeta* meta_;
};

class ClassBuilder {
 public:
  static v8::Local<v8::FunctionTemplate> GetExtendFunction(
      v8::Isolate* isolate, const InterfaceMeta* interfaceMeta);
  static Class GetExtendedClass(const std::string& baseClassName,
                                const std::string& staticClassName,
                                int isolateId);

  static void RegisterBaseTypeScriptExtendsFunction(
      v8::Local<v8::Context> context);
  static void RegisterNativeTypeScriptExtendsFunction(
      v8::Local<v8::Context> context);
  static std::string GetTypeEncoding(const TypeEncoding* typeEncoding,
                                     int argsCount);

  // Defines the global `__registerNativeClass(ctor)` used by NativeClass to
  // register eagerly. No-ops on worker isolates, whose class names are
  // isolate-suffixed and so cannot answer name-based native lookups.
  static void RegisterNativeClassFunction(v8::Local<v8::Context> context);

  // Lazily registers an Objective-C subclass for a plain ES
  // `class X extends Base {}` constructor function, registering a JS-defined
  // Base first so the Objective-C hierarchy mirrors the JS one. Returns the
  // registered class, or nil when ctorFunc is not part of a native inheritance
  // chain. Idempotent: subsequent calls return the cached class from the ctor's
  // ObjCClassWrapper.
  static Class EnsureExtendedClass(v8::Local<v8::Context> context,
                                   v8::Local<v8::Function> ctorFunc);

  // Resolves the Objective-C class that should be instantiated for a construct
  // call, honoring `new.target` so that plain ES subclasses of native classes
  // get their own registered class. Sets *esDerived when that class is one, so
  // the construct path need not look new.target up again.
  static Class ResolveConstructedClass(v8::Local<v8::Context> context,
                                       v8::Local<v8::Value> newTarget,
                                       Class fallback,
                                       bool* esDerived = nullptr);

  // False for constructors the runtime builds from templates (native classes,
  // `.extend()`), which have no script and so can never be ES classes. Lets hot
  // paths skip the wrapper lookup on a function, which is a private-symbol
  // read.
  static bool MayBeESClass(v8::Local<v8::Value> function);

  // The native end of super(...) for an ES class. Binds info.This() to the
  // object being initialized before the initializer runs, so overrides the
  // initializer calls see the instance under construction:
  // - inside an initializer hook (Objective-C started the construction), the
  //   object already exists and the initializer the caller sent runs unless
  //   the constructor names another in [interop.initializer.args];
  // - when adopting an object first seen after an initializer that has no
  //   hook, the object is bound as is and no initializer runs;
  // - otherwise (`new X(...)`), klass is allocated and initialized with the
  //   initializer [interop.initializer.args] names, or `init`.
  static void ConstructESObject(v8::Local<v8::Context> context,
                                const v8::FunctionCallbackInfo<v8::Value>& info,
                                Class klass);

  // Runs the ES constructor for an instance of an ES class that reaches JS
  // without having been constructed, i.e. one initialized through an
  // initializer the metadata does not list and so has no hook. Returns false
  // when target is not such an instance.
  static bool TryAdoptNativeInstance(v8::Local<v8::Context> context, id target,
                                     v8::Local<v8::Value>& result);

  // Defines interop.initializer.{args,native}.
  static void RegisterInitializerSymbols(v8::Local<v8::Context> context,
                                         v8::Local<v8::Object> interop);

  // The class a JS `super.method()` reaching a native method must dispatch
  // to: the superclass of the rootmost JS-defined class in klass's chain. A JS
  // super lookup only lands on a native method when no JS level above the
  // caller defines it, so every JS-defined class in between must be skipped —
  // their implementations call back into JS and would recurse.
  static Class GetNativeSuperclass(Class klass);

 private:
  static std::atomic<unsigned long long> classNameCounter_;

  static void ExtendCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void SuperAccessorGetterCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void ExtendedClassConstructorCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);

  static void SwizzleRetainRelease(v8::Isolate* isolate, Class extendedClass);
  static void InstallInitializerHooks(v8::Isolate* isolate,
                                      Class extendedClass);
  static void ExposeDynamicMethods(v8::Local<v8::Context> context,
                                   Class extendedClass,
                                   v8::Local<v8::Value> exposedMethods,
                                   v8::Local<v8::Value> exposedProtocols,
                                   v8::Local<v8::Object> implementationObject);
  static void ExposeDynamicMembers(v8::Local<v8::Context> context,
                                   Class extendedClass,
                                   v8::Local<v8::Object> implementationObject,
                                   v8::Local<v8::Object> nativeSignature);
  static void VisitMethods(Class extendedClass, std::string methodName,
                           const BaseClassMeta* meta,
                           std::vector<const MethodMeta*>& methodMetas,
                           std::vector<const ProtocolMeta*> exposedProtocols);
  static void VisitProperties(
      std::string propertyName, const BaseClassMeta* meta,
      std::vector<const PropertyMeta*>& propertyMetas,
      std::vector<const ProtocolMeta*> exposedProtocols);
  static void ExposeProperties(v8::Isolate* isolate, Class extendedClass,
                               std::vector<const PropertyMeta*> propertyMetas,
                               v8::Local<v8::Object> implementationObject,
                               v8::Local<v8::Value> getter,
                               v8::Local<v8::Value> setter);
  static std::string GetTypeEncoding(const TypeEncoding* typeEncoding);
  static BinaryTypeEncodingType GetTypeEncodingType(v8::Isolate* isolate,
                                                    v8::Local<v8::Value> value);
  static IMP FindNotOverridenMethod(Class klass, SEL method);

  struct CacheItem {
   public:
    CacheItem(const InterfaceMeta* meta, id data) : meta_(meta), data_(data) {}
    const InterfaceMeta* meta_;
    id data_;
  };
};

}  // namespace tns

#endif /* ClassBuilder_h */
