#ifndef ClassBuilder_h
#define ClassBuilder_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include "Metadata.h"
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Interop.h"

namespace tns {

class ClassBuilder {
public:
    void Init(ArgConverter argConverter, ObjectManager objectManager);
    v8::Local<v8::Function> GetExtendFunction(v8::Local<v8::Context> context, const InterfaceMeta* interfaceMeta);
private:
    ObjectManager objectManager_;
    ArgConverter argConverter_;
    Interop interop_;
    static unsigned long long classNameCounter_;

    static void ExtendCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SuperAccessorGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void ExtendedClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);

    Class GetExtendedClass(std::string baseClassName);
    void ExposeDynamicMembers(v8::Isolate* isolate, Class extendedClass, v8::Local<v8::Object> implementationObject, v8::Local<v8::Object> nativeSignature);

    struct CacheItem {
    public:
        CacheItem(const InterfaceMeta* meta, id data, ClassBuilder* classBuilder): meta_(meta), data_(data), self_(classBuilder) {}
        const InterfaceMeta* meta_;
        id data_;
        ClassBuilder* self_;
    };
};

}

#endif /* ClassBuilder_h */
