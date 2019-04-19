#ifndef ArgConverter_h
#define ArgConverter_h

#include "ffi.h"
#include "NativeScript.h"
#include "DataWrapper.h"

namespace tns {

class ArgConverter;

struct MethodCallbackWrapper {
public:
    MethodCallbackWrapper(v8::Isolate* isolate, v8::Persistent<v8::Object>* callback, const uint8_t initialParamIndex, const uint8_t paramsCount, const TypeEncoding* typeEncoding)
        : isolate_(isolate), callback_(callback), initialParamIndex_(initialParamIndex), paramsCount_(paramsCount), typeEncoding_(typeEncoding) {}
    v8::Isolate* isolate_;
    v8::Persistent<v8::Object>* callback_;
    const uint8_t initialParamIndex_;
    const uint8_t paramsCount_;
    const TypeEncoding* typeEncoding_;
};

class ArgConverter {
public:
    static void Init(v8::Isolate* isolate, v8::GenericNamedPropertyGetterCallback structPropertyGetter, v8::GenericNamedPropertySetterCallback structPropertySetter);
    static v8::Local<v8::Value> Invoke(v8::Isolate* isolate, Class klass, v8::Local<v8::Object> receiver, const std::vector<v8::Local<v8::Value>> args, const MethodMeta* meta, bool isMethodCallback);
    static v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, BaseDataWrapper* wrapper);
    static v8::Local<v8::Value> CreateJsWrapper(v8::Isolate* isolate, BaseDataWrapper* wrapper, v8::Local<v8::Object> receiver);
    static v8::Local<v8::Object> CreateEmptyObject(v8::Local<v8::Context> context);
    static v8::Local<v8::Object> CreateEmptyStruct(v8::Local<v8::Context> context);
    static const BaseClassMeta* FindInterfaceMeta(Class klass);
    static const BaseClassMeta* GetInterfaceMeta(std::string name);
    static void MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData);
private:
    static v8::Persistent<v8::Function>* poEmptyObjCtorFunc_;
    static v8::Persistent<v8::Function>* poEmptyStructCtorFunc_;

    static v8::Local<v8::Function> CreateEmptyInstanceFunction(v8::Isolate* isolate, v8::GenericNamedPropertyGetterCallback propertyGetter = nullptr, v8::GenericNamedPropertySetterCallback propertySetter = nullptr);
    static v8::Local<v8::Object> CreateEmptyInstance(v8::Local<v8::Context> context, v8::Persistent<v8::Function>* ctorFunc);
};

}

#endif /* ArgConverter_h */
