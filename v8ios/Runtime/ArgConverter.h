#ifndef ArgConverter_h
#define ArgConverter_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <Foundation/NSInvocation.h>
#include <string>
#include <map>
#include "Metadata.h"
#include "ObjectManager.h"
#include "Interop.h"
#include "Caches.h"

namespace tns {

class ArgConverter;

struct DataWrapper {
public:
    DataWrapper(id data): data_(data), meta_(nullptr) {}
    DataWrapper(id data, const Meta* meta): data_(data), meta_(meta) {}
    id data_;
    const Meta* meta_;
};

struct MethodCallbackWrapper {
public:
    MethodCallbackWrapper(v8::Isolate* isolate, const v8::Persistent<v8::Object>* callback, const uint8_t initialParamIndex, const uint8_t paramsCount, ArgConverter* argConverter)
        : isolate_(isolate), callback_(callback), initialParamIndex_(initialParamIndex), paramsCount_(paramsCount), argConverter_(argConverter) {}
    v8::Isolate* isolate_;
    const v8::Persistent<v8::Object>* callback_;
    const uint8_t initialParamIndex_;
    const uint8_t paramsCount_;
    ArgConverter* argConverter_;
};

class ArgConverter {
public:
    void Init(v8::Isolate* isolate, ObjectManager objectManager);
    void SetArgument(NSInvocation* invocation, int index, v8::Isolate* isolate, v8::Local<v8::Value> arg, const TypeEncoding* typeEncoding);
    v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, NSInvocation* invocation, std::string returnType);
    v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, id obj);
    v8::Local<v8::Object> CreateJsWrapper(v8::Isolate* isolate, id obj, v8::Local<v8::Object> receiver);
    v8::Local<v8::Object> CreateEmptyObject(v8::Local<v8::Context> context);
    static void MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData);
private:
    v8::Isolate* isolate_;
    ObjectManager objectManager_;
    Interop interop_;
    v8::Persistent<v8::Function>* poEmptyObjCtorFunc_;

    const InterfaceMeta* FindInterfaceMeta(id obj);
    const InterfaceMeta* GetInterfaceMeta(std::string className);
    v8::Local<v8::Function> CreateEmptyObjectFunction(v8::Isolate* isolate);
    void SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding);
};

}

#endif /* ArgConverter_h */
