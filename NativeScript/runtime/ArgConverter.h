#ifndef ArgConverter_h
#define ArgConverter_h

#include "libffi.h"
#include "Common.h"
#include "DataWrapper.h"

namespace tns {

class ArgConverter;

struct MethodCallbackWrapper {
public:
    MethodCallbackWrapper(v8::Isolate* isolate, v8::Persistent<v8::Value>* callback, const uint8_t initialParamIndex, const uint8_t paramsCount, const TypeEncoding* typeEncoding)
        : isolate_(isolate),
          callback_(callback),
          initialParamIndex_(initialParamIndex),
          paramsCount_(paramsCount),
          typeEncoding_(typeEncoding) {
    }
    v8::Isolate* isolate_;
    v8::Persistent<v8::Value>* callback_;
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
    static const Meta* FindMeta(Class klass);
    static const Meta* GetMeta(std::string name);
    static const ProtocolMeta* FindProtocolMeta(Protocol* protocol);
    static void MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData);
    static void SetValue(v8::Isolate* isolate, void* retValue, v8::Local<v8::Value> value, const TypeEncoding* typeEncoding);
    static void ConstructObject(v8::Isolate* isolate, const v8::FunctionCallbackInfo<v8::Value>& info, Class klass, const InterfaceMeta* interfaceMeta = nullptr);
private:
    static v8::Local<v8::Function> CreateEmptyInstanceFunction(v8::Isolate* isolate, v8::GenericNamedPropertyGetterCallback propertyGetter = nullptr, v8::GenericNamedPropertySetterCallback propertySetter = nullptr);
    static v8::Local<v8::Object> CreateEmptyInstance(v8::Local<v8::Context> context, v8::Persistent<v8::Function>* ctorFunc);
    static void FindMethodOverloads(Class klass, std::string methodName, MemberType type, std::vector<const MethodMeta*>& overloads);
    static const MethodMeta* FindInitializer(v8::Isolate* isolate, Class klass, const InterfaceMeta* interfaceMeta, const v8::FunctionCallbackInfo<v8::Value>& info);
    static bool CanInvoke(v8::Isolate* isolate, const TypeEncoding* typeEncoding, v8::Local<v8::Value> arg);
    static bool CanInvoke(v8::Isolate* isolate, const MethodMeta* candidate, const v8::FunctionCallbackInfo<v8::Value>& info);
    static void IndexedPropertyGetterCallback(uint32_t index, const v8::PropertyCallbackInfo<v8::Value>& args);
    static void IndexedPropertySetterCallback(uint32_t index, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<v8::Value>& args);
    static bool IsErrorOutParameter(const TypeEncoding* typeEncoding);
};

}

#endif /* ArgConverter_h */
