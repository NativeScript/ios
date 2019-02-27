#ifndef Runtime_h
#define Runtime_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop
#include "libplatform/libplatform.h"
#include "ModuleInternal.h"

using namespace v8;

namespace tns {

class Runtime {
public:
    Runtime();
    void Init(const std::string& baseDir);
    void RunScript(std::string file);
    static std::string ReadText(const std::string& file);
private:
    Isolate* InitInternal(const std::string& baseDir);
    void DefineGlobalObject(Local<Context> context);
    void DefinePerformanceObject(Local<Context> context);
    static void PerformanceNowCallback(const FunctionCallbackInfo<Value>& args);
    Platform* platform_;
    Isolate* isolate_;
    ModuleInternal moduleInternal_;
    std::string baseDir_;
};

}

#endif /* Runtime_h */
