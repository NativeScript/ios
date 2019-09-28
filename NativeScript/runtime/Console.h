#ifndef Console_h
#define Console_h

#include "Common.h"

namespace tns {

class Console {
public:
    static void Init(v8::Isolate* isolate);
private:
    static void AttachLogFunction(v8::Isolate* isolate, v8::Local<v8::Object> console, const std::string name);
    static void LogCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static std::string BuildStringFromArgs(v8::Isolate* isolate, const v8::FunctionCallbackInfo<v8::Value>& args);
    static const v8::Local<v8::String> BuildStringFromArg(v8::Isolate* isolate, const v8::Local<v8::Value>& val);
    static const v8::Local<v8::String> TransformJSObject(v8::Isolate* isolate, v8::Local<v8::Object> object);
};

}

#endif /* Console_h */
