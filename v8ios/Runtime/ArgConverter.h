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
#include "Caches.h"

namespace tns {

struct DataWrapper {
public:
    DataWrapper(id data): data_(data), meta_(nullptr) {}
    DataWrapper(id data, const Meta* meta): data_(data), meta_(meta) {}
    id data_;
    const Meta* meta_;
};

class ArgConverter {
public:
    void Init(v8::Isolate* isolate, ObjectManager objectManager);
    void SetArgument(NSInvocation* invocation, int index, v8::Isolate* isolate, v8::Local<v8::Value> arg, const TypeEncoding* typeEncoding);
    v8::Local<v8::Value> ConvertArgument(v8::Isolate* isolate, id obj);
    v8::Local<v8::Object> CreateJsWrapper(v8::Isolate* isolate, id obj, v8::Local<v8::Object> receiver);
    v8::Local<v8::Object> CreateEmptyObject(v8::Local<v8::Context> context);
private:
    v8::Isolate* isolate_;
    ObjectManager objectManager_;
    v8::Persistent<v8::Function>* poEmptyObjCtorFunc_;

    const InterfaceMeta* FindInterfaceMeta(id obj);
    const InterfaceMeta* GetInterfaceMeta(std::string className);
    v8::Local<v8::Function> CreateEmptyObjectFunction(v8::Isolate* isolate);
    void SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding);
};

}

#endif /* ArgConverter_h */
