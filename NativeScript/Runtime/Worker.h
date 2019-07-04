#ifndef Worker_h
#define Worker_h

#include "Common.h"

namespace tns {

class Worker {
public:
    static void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    static void RegisterGlobals(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
private:
    static void ConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PostMessageCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void TerminateCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void OnMessageCallback(v8::Isolate* isolate, v8::Local<v8::Value> receiver, std::string message);
    static v8::Local<v8::String> Serialize(v8::Isolate* isolate, v8::Local<v8::Value> value, v8::Local<v8::Value>& error);
};

}

#endif /* Worker_h */
