#ifndef ArgConverter_h
#define ArgConverter_h

#include <Foundation/NSInvocation.h>
#include "NativeScript.h"
#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Interop.h"

namespace tns {

class ArgConverter;

struct MethodCallbackWrapper {
public:
    MethodCallbackWrapper(v8::Isolate* isolate, const v8::Persistent<v8::Object>* callback, const uint8_t initialParamIndex, const uint8_t paramsCount, const TypeEncoding* typeEncoding, ArgConverter* argConverter)
        : isolate_(isolate), callback_(callback), initialParamIndex_(initialParamIndex), paramsCount_(paramsCount), typeEncoding_(typeEncoding), argConverter_(argConverter) {}
    v8::Isolate* isolate_;
    const v8::Persistent<v8::Object>* callback_;
    const uint8_t initialParamIndex_;
    const uint8_t paramsCount_;
    const TypeEncoding* typeEncoding_;
    ArgConverter* argConverter_;
};

class ArgConverter {
public:
    void Init(v8::Isolate* isolate, ObjectManager objectManager);
    v8::Local<v8::Value> Invoke(v8::Isolate* isolate, Class klass, v8::Local<v8::Object> receiver, const std::vector<v8::Local<v8::Value>> args, NSInvocation* invocation, const TypeEncoding* typeEncoding, const std::string returnType);
    v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, BaseDataWrapper* wrapper);
    v8::Local<v8::Value> CreateJsWrapper(v8::Isolate* isolate, BaseDataWrapper* wrapper, v8::Local<v8::Object> receiver);
    v8::Local<v8::Object> CreateEmptyObject(v8::Local<v8::Context> context);
    const BaseClassMeta* FindInterfaceMeta(Class klass);
    const BaseClassMeta* GetInterfaceMeta(std::string name);
    static void MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData);
private:
    v8::Isolate* isolate_;
    ObjectManager objectManager_;
    Interop interop_;
    v8::Persistent<v8::Function>* poEmptyObjCtorFunc_;

    v8::Local<v8::Function> CreateEmptyObjectFunction(v8::Isolate* isolate);
    void SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding);
};

}

#endif /* ArgConverter_h */
