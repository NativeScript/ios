#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "inspector/JsV8InspectorClient.h"
#include "runtime/RuntimeConfig.h"
#include "runtime/Helpers.h"
#include "runtime/Runtime.h"
#include "runtime/Tasks.h"

using namespace v8;
using namespace tns;

@implementation Config

@synthesize BaseDir;
@synthesize MetadataPtr;
@synthesize IsDebug;

@end

@implementation NativeScript

static std::shared_ptr<Runtime> runtime_;

+ (void)start:(Config*)config {
    RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
    RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
    RuntimeConfig.MetadataPtr = [config MetadataPtr];
    RuntimeConfig.IsDebug = [config IsDebug];
    RuntimeConfig.LogToSystemConsole = [config LogToSystemConsole];

    Runtime::Initialize();
    runtime_ = std::make_shared<Runtime>();

    std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
    Isolate* isolate = runtime_->CreateIsolate();
    runtime_->Init(isolate);
    std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
    printf("Runtime initialization took %llims\n", duration);

    if (config.IsDebug) {
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        v8_inspector::JsV8InspectorClient* inspectorClient = new v8_inspector::JsV8InspectorClient(runtime_.get());
        inspectorClient->init();
        inspectorClient->registerModules();
        inspectorClient->connect([config ArgumentsCount], [config Arguments]);
    }

    runtime_->RunMainScript();

    tns::Tasks::Drain();

    runtime_.reset();
}

+ (bool)liveSync {
    if (runtime_ == nullptr) {
        return false;
    }

    Isolate* isolate = runtime_->GetIsolate();
    return tns::LiveSync(isolate);
}

@end
