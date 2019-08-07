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
};

}

#endif /* Console_h */