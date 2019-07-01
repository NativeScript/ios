#ifndef MetadataBuilder_h
#define MetadataBuilder_h

#include "libffi.h"
#include "Common.h"
#include "Metadata.h"
#include "ClassBuilder.h"

namespace tns {

class MetadataBuilder {
public:
    MetadataBuilder();
    void Init(v8::Isolate* isolate);
    void RegisterConstantsOnGlobalObject(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> global);

private:
    v8::Isolate* isolate_;
    ClassBuilder classBuilder_;
    v8::Persistent<v8::Function>* poToStringFunction_;
    v8::Persistent<v8::Function>* poOriginalExtendsFunc_;

    static void ClassConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void AllocCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void MethodCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void CFunctionCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PropertyGetterCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PropertySetterCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PropertyNameGetterCallback(v8::Local<v8::Name> name, const v8::PropertyCallbackInfo<v8::Value> &info);
    static void PropertyNameSetterCallback(v8::Local<v8::Name> name, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<void> &info);
    static void StructConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void StructPropertyGetterCallback(v8::Local<v8::Name> property, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void StructPropertySetterCallback(v8::Local<v8::Name> property, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<v8::Value>& info);
    static void StructEqualsCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void ToStringFunctionCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static std::pair<ffi_type*, void*> GetStructData(v8::Isolate* isolate, v8::Local<v8::Object> initializer, const StructMeta* structMeta);

    v8::Local<v8::Value> InvokeMethod(v8::Isolate* isolate, const MethodMeta* meta, v8::Local<v8::Object> receiver, const std::vector<v8::Local<v8::Value>> args, std::string containingClass, bool isMethodCallback);
    v8::Persistent<v8::Function>* CreateToStringFunction(v8::Isolate* isolate);
    v8::Local<v8::FunctionTemplate> GetOrCreateConstructorFunctionTemplate(const BaseClassMeta* meta);
    v8::Local<v8::Function> CreateEmptyObjectFunction(v8::Isolate* isolate);
    v8::Local<v8::Function> GetOrCreateStructCtorFunction(v8::Isolate* isolate, const StructMeta* structMeta);
    void RegisterCFunction(const FunctionMeta* funcMeta);
    void RegisterAllocMethod(v8::Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta);
    void RegisterInstanceMethods(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, std::vector<std::string>& names);
    void RegisterInstanceProperties(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, std::string className, std::vector<std::string>& names);
    void RegisterInstanceProtocols(v8::Local<v8::FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, std::string className, std::vector<std::string>& names);
    void RegisterStaticMethods(v8::Local<v8::Function> ctorFunc, const BaseClassMeta* meta, std::vector<std::string>& names);
    void RegisterStaticProperties(v8::Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names);
    void RegisterStaticProtocols(v8::Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names);
    void DefineFunctionLengthProperty(v8::Local<v8::Context> context, const TypeEncodingsList<ArrayCount>* encodings, v8::Local<v8::Function> func);

    template<class T>
    struct CacheItem {
        CacheItem(const T* meta, const std::string className, MetadataBuilder* builder)
        : meta_(meta), className_(className), builder_(builder) {
            static_assert(std::is_base_of<Meta, T>::value, "Derived not derived from Meta");
        }
        const T* meta_;
        const std::string className_;
        MetadataBuilder* builder_;
    };

    struct TaskContext {
    public:
        TaskContext(v8::Isolate* isolate, const FunctionMeta* meta, std::vector<v8::Persistent<v8::Value>*> args): isolate_(isolate), meta_(meta), args_(args) {}
        v8::Isolate* isolate_;
        const FunctionMeta* meta_;
        std::vector<v8::Persistent<v8::Value>*> args_;
    };
};

}

#endif /* MetadataBuilder_h */
