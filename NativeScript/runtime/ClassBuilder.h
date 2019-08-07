#ifndef ClassBuilder_h
#define ClassBuilder_h

#include "Common.h"
#include "Metadata.h"

namespace tns {

class ClassBuilder {
public:
    v8::Local<v8::Function> GetExtendFunction(v8::Local<v8::Context> context, const InterfaceMeta* interfaceMeta);
    Class GetExtendedClass(std::string baseClassName, std::string staticClassName);

    void RegisterBaseTypeScriptExtendsFunction(v8::Isolate* isolate);
    void RegisterNativeTypeScriptExtendsFunction(v8::Isolate* isolate);
private:
    static unsigned long long classNameCounter_;

    static void ExtendCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SuperAccessorGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void ExtendedClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);

    void ExposeDynamicMethods(v8::Isolate* isolate, Class extendedClass, v8::Local<v8::Value> exposedMethods, v8::Local<v8::Value> exposedProtocols, v8::Local<v8::Object> implementationObject);
    void ExposeDynamicMembers(v8::Isolate* isolate, Class extendedClass, v8::Local<v8::Object> implementationObject, v8::Local<v8::Object> nativeSignature);
    void VisitMethods(v8::Isolate* isolate, Class extendedClass, std::string methodName, const BaseClassMeta* meta, std::vector<const MethodMeta*>& methodMetas, std::vector<const ProtocolMeta*> exposedProtocols);
    void VisitProperties(std::string propertyName, const BaseClassMeta* meta, std::vector<const PropertyMeta*>& propertyMetas, std::vector<const ProtocolMeta*> exposedProtocols);
    void ExposeProperties(v8::Isolate* isolate, Class extendedClass, std::vector<const PropertyMeta*> propertyMetas, v8::Local<v8::Object> implementationObject, v8::Local<v8::Value> getter, v8::Local<v8::Value> setter);
    std::string GetTypeEncoding(const TypeEncoding* typeEncoding, int argsCount);
    std::string GetTypeEncoding(const TypeEncoding* typeEncoding);
    BinaryTypeEncodingType GetTypeEncodingType(v8::Isolate* isolate, v8::Local<v8::Value> value);

    struct CacheItem {
    public:
        CacheItem(const InterfaceMeta* meta, id data, ClassBuilder* classBuilder): meta_(meta), data_(data), self_(classBuilder) {}
        const InterfaceMeta* meta_;
        id data_;
        ClassBuilder* self_;
    };

    struct PropertyCallbackContext {
    public:
        PropertyCallbackContext(ClassBuilder* classBuilder, v8::Isolate* isolate, v8::Persistent<v8::Function>* callback, v8::Persistent<v8::Object>* implementationObject, const PropertyMeta* meta)
            : classBuilder_(classBuilder), isolate_(isolate), callback_(callback), implementationObject_(implementationObject), meta_(meta) {
            }
        ClassBuilder* classBuilder_;
        v8::Isolate* isolate_;
        v8::Persistent<v8::Function>* callback_;
        v8::Persistent<v8::Object>* implementationObject_;
        const PropertyMeta* meta_;
    };
};

}

#endif /* ClassBuilder_h */
