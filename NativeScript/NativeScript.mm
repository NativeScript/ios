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
@synthesize SnapshotPtr;
@synthesize SnapshotSize;
@synthesize IsDebug;

@end

@implementation NativeScript

static Runtime* runtime_ = nullptr;

+ (void)start:(Config*)config {
    RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
    RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
    RuntimeConfig.MetadataPtr = [config MetadataPtr];
    RuntimeConfig.SnapshotPtr = [config SnapshotPtr];
    RuntimeConfig.SnapshotSize = [config SnapshotSize];
    RuntimeConfig.IsDebug = [config IsDebug];

    Runtime::Initialize();
    runtime_ = new Runtime();

    std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
    runtime_->Init();
    std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
    printf("Runtime initialization took %llims\n", duration);

    if (config.IsDebug) {
        v8_inspector::JsV8InspectorClient* inspectorClient = new v8_inspector::JsV8InspectorClient(runtime_);
        inspectorClient->init();
        inspectorClient->registerModules();
        inspectorClient->connect([config ArgumentsCount], [config Arguments]);
    }

    runtime_->RunMainScript();

    tns::Tasks::Drain();
}

+ (bool)liveSync {
    if (runtime_ == nullptr) {
        return false;
    }

    Isolate* isolate = runtime_->GetIsolate();
    return tns::LiveSync(isolate);
}

@end
