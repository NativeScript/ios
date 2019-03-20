#ifndef MetadataBuilder_h
#define MetadataBuilder_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <Foundation/NSInvocation.h>
#include <string>
#include <map>
#include "Metadata.h"
#include "ObjectManager.h"

namespace tns {

struct DataWrapper {
public:
    DataWrapper(id data): data_(data), meta_(nullptr) {}
    DataWrapper(id data, const Meta* meta): data_(data), meta_(meta) {}
    id data_;
    const Meta* meta_;
};

class MetadataBuilder {
public:
    MetadataBuilder();
    void Init(v8::Isolate* isolate);
    static MetadataBuilder* Load(const std::string& baseDir) {
        static MetadataBuilder *b = new MetadataBuilder(baseDir);
        return b;
    }

private:
    template<class T>
    struct CacheItem;

    v8::Isolate* isolate_;
    ObjectManager objectManager_;
    std::map<const InterfaceMeta*, v8::Persistent<v8::FunctionTemplate>*> ctorTemplatesCache_;
    std::map<const InterfaceMeta*, v8::Persistent<v8::Value>*> prototypesCache_;

    static void ClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void AllocCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void MethodCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PropertyGetterCallback(v8::Local<v8::String> name, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void PropertySetterCallback(v8::Local<v8::String> name, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<void>& info);
    static void PropertyNameGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value> &info);
    static void PropertyNameSetterCallback(v8::Local<v8::Name> name, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<void> &info);
    v8::Local<v8::Value> InvokeMethod(v8::Isolate* isolate, const MethodMeta* meta, v8::Local<v8::Object> receiver, const std::vector<v8::Local<v8::Value>> args, const char* containingClass);

    v8::Local<v8::FunctionTemplate> GetOrCreateConstructor(const InterfaceMeta* interfaceMeta);
    void RegisterAllocMethod(v8::Local<v8::Function> ctorFuncm, const InterfaceMeta* interfaceMeta);
    void RegisterStaticMethods(v8::Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta);
    void RegisterInstanceMethods(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta);
    void RegisterStaticProperties(v8::Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta);
    void RegisterInstanceProperties(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta);
    void SetArgument(NSInvocation* invocation, int index, v8::Isolate* isolate, v8::Local<v8::Value> arg, const TypeEncoding* typeEncoding);
    v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, id obj);
    v8::Local<v8::Object> CreateJsWrapper(v8::Isolate* isolate, id obj, v8::Local<v8::Object> receiver);
    const InterfaceMeta* GetInterfaceMeta(id obj);
    v8::Local<v8::Object> CreateEmptyObject(v8::Local<v8::Context> context);
    void SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding);

    MetadataBuilder(const std::string& baseDir) {
        std::string fileName = baseDir + "/metadata-x86_64.bin";
        std::string mode = "rb";
        auto file = fopen(fileName.c_str(), mode.c_str());
        if (!file) {
            assert(false);
        }

        fseek(file, 0, SEEK_END);
        long length = ftell(file);
        rewind(file);

        uint8_t* data = new uint8_t[length];
        fread(data, sizeof(uint8_t), length, file);
        fclose(file);

        MetaFile::setInstance(data);
    }

    template<class T>
    struct CacheItem {
        CacheItem(const T* meta, const InterfaceMeta* interfaceMeta, MetadataBuilder* builder)
        : meta_(meta), interfaceMeta_(interfaceMeta), builder_(builder) {
            static_assert(std::is_base_of<Meta, T>::value, "Derived not derived from Meta");
        }
        const T* meta_;
        const InterfaceMeta* interfaceMeta_;
        MetadataBuilder* builder_;
    };
};

}

#endif /* MetadataBuilder_h */
