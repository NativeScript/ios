#ifndef Console_h
#define Console_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

using namespace v8;

namespace tns {

class Console {
public:
    static void Init(Isolate* isolate);
private:
    static void LogCallback(const FunctionCallbackInfo<Value>& args);
};

}

#endif /* Console_h */
