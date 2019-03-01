#ifndef Console_h
#define Console_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

namespace tns {

class Console {
public:
    static void Init(v8::Isolate* isolate);
private:
    static void LogCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
};

}

#endif /* Console_h */
