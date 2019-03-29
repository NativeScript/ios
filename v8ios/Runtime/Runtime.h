#ifndef Runtime_h
#define Runtime_h

#include "libplatform/libplatform.h"
#include "NativeScript.h"
#include "ModuleInternal.h"
#include "MetadataBuilder.h"

namespace tns {

class Runtime {
public:
    Runtime();
    void Init(const std::string& baseDir);
    void RunScript(std::string file);
    static std::string ReadText(const std::string& file);
private:
    v8::Isolate* InitInternal(const std::string& baseDir);
    void DefineGlobalObject(v8::Local<v8::Context> context);
    void DefinePerformanceObject(v8::Local<v8::Context> context);
    static void PerformanceNowCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    v8::Platform* platform_;
    v8::Isolate* isolate_;
    MetadataBuilder metadataBuilder_;
    ModuleInternal moduleInternal_;
    std::string baseDir_;
};

}

#endif /* Runtime_h */
