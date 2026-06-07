#include "NativeScript.h"
#include <Foundation/Foundation.h>
#include "inspector/JsV8InspectorClient.h"
#include "runtime/Console.h"
#include "runtime/Helpers.h"
#include "runtime/ModuleInternal.h"
#include "runtime/ModuleInternalCallbacks.h"
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

  // Async boot handoff. For UI apps Tasks::Drain() invokes UIApplicationMain
  // and never returns — the app's main runloop services whatever is still in
  // flight. When Drain returns, the entry has not reached UIApplicationMain,
  // so pump a manual runloop until boot actually finishes, Node-like. A
  // completion may itself register the UIApplicationMain task, so drain after
  // each slice; if that drain calls UIApplicationMain it takes over and never
  // returns.
  //
  // Two independent things can leave boot unfinished, and BOTH must hold the
  // pump: an in-flight module-graph load, and an entry whose own evaluation
  // promise is still pending — a top-level await parked on anything at all
  // (a nested import() that does its own async work, a native init that will
  // call UIApplicationMain later). Gating on graph work alone let the second
  // case reach counter == 0 and fall off the end of main().
  std::string entryRejectionReason;
  bool entryPending = runtime_->PollMainEntryEvaluation(&entryRejectionReason) ==
                      tns::EntryEvaluationState::kPending;
  bool entryRejected = false;

  if (entryPending || tns::HasPendingAsyncModuleGraphWork()) {
    const CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + 2 * tns::kModuleEvaluateDeadlineSeconds;
    while ((entryPending || tns::HasPendingAsyncModuleGraphWork()) &&
           CFAbsoluteTimeGetCurrent() < deadline) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
      tns::Tasks::Drain();

      if (entryPending) {
        tns::EntryEvaluationState state = runtime_->PollMainEntryEvaluation(&entryRejectionReason);
        // Once it settles, stop probing for good.
        entryPending = state == tns::EntryEvaluationState::kPending;
        if (state == tns::EntryEvaluationState::kRejected) {
          entryRejected = true;
          break;
        }
      }
    }
    tns::Tasks::Drain();

    // A settled entry that never called UIApplicationMain is a script-style
    // app finishing normally; only the two failures below are fatal, and both
    // are reported in every build.
    if (entryRejected) {
      Log(@"Fatal: the main entry module's evaluation rejected during boot: %s",
          entryRejectionReason.c_str());
    } else if (entryPending) {
      Log(@"Fatal: main entry never settled and UIApplicationMain was never reached within %.0fs",
          2 * tns::kModuleEvaluateDeadlineSeconds);
    }
  }
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
