#ifndef Pointer_h
#define Pointer_h

#include "Common.h"
#include "DataWrapper.h"

namespace tns {

class Pointer {
public:
    static void Register(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static v8::Local<v8::Value> NewInstance(v8::Isolate* isolate, void* handle);
private:
    static v8::Local<v8::Function> GetPointerCtorFunc(v8::Isolate* isolate);
    static void PointerConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void RegisterAddMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
    static void RegisterSubtractMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
    static void RegisterToStringMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
    static void RegisterToHexStringMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
    static void RegisterToDecimalStringMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
    static void RegisterToNumberMethod(v8::Isolate* isolate, v8::Local<v8::Object> prototype);
};

}

#endif /* Pointer_h */
