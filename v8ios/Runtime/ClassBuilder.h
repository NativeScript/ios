#ifndef ClassBuilder_h
#define ClassBuilder_h

#include "NativeScript.h"
#include "Metadata.h"

namespace tns {

class ClassBuilder {
public:
    v8::Local<v8::Function> GetExtendFunction(v8::Local<v8::Context> context, const InterfaceMeta* interfaceMeta);
private:
    static unsigned long long classNameCounter_;

    static void ExtendCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SuperAccessorGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void ExtendedClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);

    Class GetExtendedClass(std::string baseClassName, std::string staticClassName);
    void ExposeDynamicMembers(v8::Isolate* isolate, Class extendedClass, v8::Local<v8::Object> implementationObject, v8::Local<v8::Object> nativeSignature);
    void ExposeDynamicProtocols(v8::Isolate* isolate, Class extendedClass, v8::Local<v8::Object> implementationObject, v8::Local<v8::Object> nativeSignature);

    struct CacheItem {
    public:
        CacheItem(const InterfaceMeta* meta, id data, ClassBuilder* classBuilder): meta_(meta), data_(data), self_(classBuilder) {}
        const InterfaceMeta* meta_;
        id data_;
        ClassBuilder* self_;
    };

    struct PropertyCallbackContext {
    public:
        PropertyCallbackContext(ClassBuilder* classBuilder, v8::Isolate* isolate, v8::Persistent<v8::Function>* callback, v8::Persistent<v8::Object>* implementationObject)
            : classBuilder_(classBuilder), isolate_(isolate), callback_(callback), implementationObject_(implementationObject) {}
        ClassBuilder* classBuilder_;
        v8::Isolate* isolate_;
        v8::Persistent<v8::Function>* callback_;
        v8::Persistent<v8::Object>* implementationObject_;
    };
};

}

#endif /* ClassBuilder_h */
