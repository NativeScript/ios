#ifndef Runtime_h
#define Runtime_h

#include "libplatform/libplatform.h"
#include "Common.h"
#include "ModuleInternal.h"
#include "MetadataBuilder.h"

namespace tns {

class Runtime {
public:
    Runtime();
    void Init(const std::string& baseDir);
    void InitAndRunMainScript(const std::string& baseDir);
    void RunScript(std::string file, v8::TryCatch& tc);
    v8::Isolate* GetIsolate();

    const int WorkerId();

    void SetWorkerId(int workerId);

    std::string BaseDir() {
        return this->baseDir_;
    }

    static void InitializeMetadata(void* metadataPtr);

    static Runtime* GetCurrentRuntime() {
        return currentRuntime_;
    }
private:
    static bool mainThreadInitialized_;
    static v8::Platform* platform_;
    static thread_local Runtime* currentRuntime_;

    void DefineGlobalObject(v8::Local<v8::Context> context);
    void DefineCollectFunction(v8::Local<v8::Context> context);
    void DefineNativeScriptVersion(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    void DefinePerformanceObject(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    void DefineTimeMethod(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    static void PerformanceNowCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    v8::Isolate* isolate_;
    ModuleInternal moduleInternal_;
    std::string baseDir_;
    int workerId_;
};

}

#endif /* Runtime_h */
