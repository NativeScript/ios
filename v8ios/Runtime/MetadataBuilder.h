#ifndef MetadataBuilder_h
#define MetadataBuilder_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <CoreFoundation/CFBase.h>
#include <string>
#include "Metadata.h"
#include "ObjectManager.h"

namespace tns {

struct MethodCallbackData {
    MethodCallbackData(id data): data_(data) {}
    id data_;
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
    static void ClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void MethodCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    template<class T, class Args>
    void MethodCallbackInternal(CacheItem<T>* item, const Args& args);
    static void PropertyGetterCallback(v8::Local<v8::String> name, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void PropertySetterCallback(v8::Local<v8::String> name, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<void>& info);
    static void PropertyNameGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value> &info);
    static void PropertyNameSetterCallback(v8::Local<v8::Name> name, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<void> &info);

    v8::Local<v8::FunctionTemplate> RegisterConstructor(const InterfaceMeta* interfaceMeta);
    void RegisterStaticMethods(v8::Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta);
    void RegisterInstanceMethods(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta);
    void RegisterStaticProperties(v8::Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta);
    void RegisterInstanceProperties(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta);
    id ConvertArgument(v8::Isolate* isolate, v8::Local<v8::Value> arg);
    template<class Args>
    void SetReturnValue(id obj, const Args& args);

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
