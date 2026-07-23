#include "NativeScript.h"
#include <Foundation/Foundation.h>
#include "inspector/JsV8InspectorClient.h"
#include "runtime/Console.h"
#include "runtime/Helpers.h"
#include "runtime/Runtime.h"
#include "runtime/RuntimeConfig.h"
#include "runtime/Tasks.h"

using namespace v8;
using namespace tns;

namespace tns {}

@implementation Config

@synthesize BaseDir;
@synthesize ApplicationPath;
@synthesize MetadataPtr;
@synthesize IsDebug;

@end

static Config* CopyConfig(Config* config) {
  Config* copy = [[Config alloc] init];
  copy.BaseDir = config.BaseDir;
  copy.ApplicationPath = config.ApplicationPath;
  copy.MetadataPtr = config.MetadataPtr;
  copy.IsDebug = config.IsDebug;
  copy.LogToSystemConsole = config.LogToSystemConsole;
  copy.ArgumentsCount = config.ArgumentsCount;
  copy.Arguments = config.Arguments;
  return copy;
}

static NativeScript* currentNativeScript;
static Config* currentConfig;

@implementation NativeScript

extern char defaultStartOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

- (void)runScriptString:(NSString*)script runLoop:(BOOL)runLoop {
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
    currentNativeScript = self;
    currentConfig = CopyConfig(config);

    RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
    if (config.ApplicationPath != nil) {
      RuntimeConfig.ApplicationPath =
          [[config.BaseDir stringByAppendingPathComponent:config.ApplicationPath] UTF8String];
    } else {
      RuntimeConfig.ApplicationPath =
          [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
    }
    if (config.MetadataPtr != nil) {
      RuntimeConfig.MetadataPtr = [config MetadataPtr];
    } else {
      RuntimeConfig.MetadataPtr = &defaultStartOfMetadataSection;
    }
    RuntimeConfig.IsDebug = [config IsDebug];
    RuntimeConfig.LogToSystemConsole = [config LogToSystemConsole];

    // Connect the JS-exposed `NativeScriptRuntime.reloadApplication(baseDir?)`
    // global (registered by the runtime) to the Objective-C implementation below.
    tns::SetReloadApplicationHook([](const std::string& baseDir) -> bool {
      NSString* dir = baseDir.empty()
                          ? nil
                          : [NSString stringWithUTF8String:baseDir.c_str()];
      return [NativeScriptRuntime reloadApplication:dir] == YES;
    });

    Runtime::Initialize();
    runtime_ = nullptr;
    runtime_ = std::make_unique<Runtime>();

    std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
    Isolate* isolate = runtime_->CreateIsolate();
    v8::Locker l(isolate);
    runtime_->Init(isolate);
    std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1).count();
    printf("Runtime initialization took %llims (version %s, V8 version %s)\n", duration,
           NATIVESCRIPT_VERSION, V8::GetVersion());

    if (config.IsDebug) {
      Isolate::Scope isolate_scope(isolate);
      HandleScope handle_scope(isolate);
      v8_inspector::JsV8InspectorClient* inspectorClient =
          new v8_inspector::JsV8InspectorClient(runtime_.get());
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
  // Incremented before the new isolate boots so its global template bakes in
  // the correct `NativeScriptRuntime.reloadCount` value.
  tns::IncrementRuntimeReloadCount();
  [self shutdownRuntime];
  [self initializeWithConfig:config];
}

@end

@implementation NativeScriptRuntime

+ (BOOL)reloadApplication {
  return [self reloadApplication:nil];
}

+ (BOOL)reloadApplication:(NSString*)baseDir {
  if (currentNativeScript == nil || currentConfig == nil) {
    return NO;
  }

  Config* config = CopyConfig(currentConfig);
  if (baseDir != nil && [baseDir length] > 0) {
    config.BaseDir = baseDir;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [currentNativeScript restartWithConfig:config];
    [currentNativeScript runMainApplication];
  });

  return YES;
}

@end
