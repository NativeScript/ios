#include <Foundation/Foundation.h>
#include "NativeScript.h"
// #include "inspector/JsV8InspectorClient.h"
#include "runtime/RuntimeConfig.h"
#include "runtime/Helpers.h"
#include "runtime/Runtime.h"
#include "runtime/Tasks.h"

using namespace v8;
using namespace tns;

@implementation Config

@synthesize BaseDir;
@synthesize ApplicationPath;
@synthesize MetadataPtr;
@synthesize IsDebug;

@end

@implementation NativeScript

std::unique_ptr<Runtime> runtime_;

- (instancetype)initWithConfig:(Config*)config {
    
    if (self = [super init]) {
        RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
        if (config.ApplicationPath != nil) {
            RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:config.ApplicationPath] UTF8String];
        } else {
            RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
        }
        RuntimeConfig.MetadataPtr = [config MetadataPtr];
        RuntimeConfig.IsDebug = [config IsDebug];
        RuntimeConfig.LogToSystemConsole = [config LogToSystemConsole];

        Runtime::Initialize();
        runtime_ = std::make_unique<Runtime>();

        std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
        Isolate* isolate = runtime_->CreateIsolate();
        runtime_->Init(isolate);
        std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
        printf("Runtime initialization took %llims\n", duration);

        // if (config.IsDebug) {
        //     Isolate::Scope isolate_scope(isolate);
        //     HandleScope handle_scope(isolate);
        //     v8_inspector::JsV8InspectorClient* inspectorClient = new v8_inspector::JsV8InspectorClient(runtime_.get());
        //     inspectorClient->init();
        //     inspectorClient->registerModules();
        //     inspectorClient->connect([config ArgumentsCount], [config Arguments]);
        // }
    }
    
    return self;
    
}

- (void)runMainApplication {
    runtime_->RunMainScript();

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);

    tns::Tasks::Drain();
}

- (bool)liveSync {
    if (runtime_ == nullptr) {
        return false;
    }

    Isolate* isolate = runtime_->GetIsolate();
    return tns::LiveSync(isolate);
}

@end
