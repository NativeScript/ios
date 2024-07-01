#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "inspector/JsV8InspectorClient.h"
#include "runtime/Console.h"
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

extern char defaultStartOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

- (void)runScriptString: (NSString*) script runLoop: (BOOL) runLoop {

    std::string cppString = std::string([script UTF8String]);
    runtime_->RunScript(cppString);
    
    if (runLoop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    }


    tns::Tasks::Drain();

}

std::unique_ptr<Runtime> runtime_;

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

- (void)shutdownRuntime {
    if (RuntimeConfig.IsDebug) {
        Console::DetachInspectorClient();
    }
    tns::Tasks::ClearTasks();
    if (runtime_ != nullptr) {
        runtime_ = nullptr;
    }
}

- (instancetype)initializeWithConfig:(Config*)config {
    if (self = [super init]) {
        RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
        if (config.ApplicationPath != nil) {
            RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:config.ApplicationPath] UTF8String];
        } else {
            RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
        }
        if (config.MetadataPtr != nil) {
            RuntimeConfig.MetadataPtr = [config MetadataPtr];
        } else {
            RuntimeConfig.MetadataPtr = &defaultStartOfMetadataSection;
        }
        RuntimeConfig.IsDebug = [config IsDebug];
        RuntimeConfig.LogToSystemConsole = [config LogToSystemConsole];

        Runtime::Initialize();
        runtime_ = nullptr;
        runtime_ = std::make_unique<Runtime>();

        std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
        Isolate* isolate = runtime_->CreateIsolate();
        v8::Locker l(isolate);
        runtime_->Init(isolate);
        std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
        printf("Runtime initialization took %llims (version %s, V8 version %s)\n", duration,  NATIVESCRIPT_VERSION, V8::GetVersion());

        if (config.IsDebug) {
            Isolate::Scope isolate_scope(isolate);
            HandleScope handle_scope(isolate);
            v8_inspector::JsV8InspectorClient* inspectorClient = new v8_inspector::JsV8InspectorClient(runtime_.get());
            inspectorClient->init();
            inspectorClient->registerModules();
            inspectorClient->connect([config ArgumentsCount], [config Arguments]);
            Console::AttachInspectorClient(inspectorClient);
        }
    }
    return self;
    
}

- (instancetype)initWithConfig:(Config*)config {
    return [self initializeWithConfig:config];
}

- (void)restartWithConfig:(Config*)config {
    [self shutdownRuntime];
    [self initializeWithConfig:config];
}



@end
