#include "NativeScript.h"
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include "inspector/JsV8InspectorClient.h"
#include "runtime/Console.h"
#include "runtime/Helpers.h"
#include "runtime/ModuleInternal.h"
#include "runtime/ModuleInternalCallbacks.h"
#include "runtime/NativeScriptException.h"
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

@implementation NativeScript

static void* HostExecutableMetadata() {
  // Debug builds with ENABLE_DEBUG_DYLIB link the app's code and linker flags
  // into <executable>.debug.dylib and leave the executable a stub.
  NSString* debugDylibName = [[[[NSBundle mainBundle] executablePath] lastPathComponent]
      stringByAppendingString:@".debug.dylib"];
  for (uint32_t i = 0, count = _dyld_image_count(); i < count; i++) {
    const struct mach_header* header = _dyld_get_image_header(i);
    if (header == nullptr) {
      continue;
    }
    if (header->filetype != MH_EXECUTE) {
      const char* path = _dyld_get_image_name(i);
      const char* name = path != nullptr ? strrchr(path, '/') : nullptr;
      if (debugDylibName == nil || name == nullptr ||
          strcmp(name + 1, debugDylibName.UTF8String) != 0) {
        continue;
      }
    }
    unsigned long size = 0;
    uint8_t* data = getsectiondata(reinterpret_cast<const struct mach_header_64*>(header), "__DATA",
                                   "__TNSMetadata", &size);
    // The app template creates an empty metadata file before the generator
    // runs, so an empty section means the host carries no metadata.
    if (data != nullptr && size > 0) {
      return data;
    }
  }
  return nullptr;
}

// NativeScriptDefaultMetadata.framework ships only with the NativeScriptSDK
// package product, embedded next to NativeScript.framework.
static void* DefaultFrameworkMetadata() {
  const char* accessorName = "NativeScriptDefaultMetadata";
  void* accessor = dlsym(RTLD_DEFAULT, accessorName);
  if (accessor == nullptr) {
    NSString* frameworksDir = [[[NSBundle bundleForClass:[NativeScript class]] bundlePath]
        stringByDeletingLastPathComponent];
    NSBundle* bundle =
        [NSBundle bundleWithPath:[frameworksDir stringByAppendingPathComponent:
                                                    @"NativeScriptDefaultMetadata.framework"]];
    // executablePath, unlike a hand-built path, follows Mac Catalyst's versioned layout.
    NSString* executable = [bundle executablePath];
    void* handle =
        executable != nil ? dlopen(executable.fileSystemRepresentation, RTLD_NOW) : nullptr;
    accessor = handle != nullptr ? dlsym(handle, accessorName) : nullptr;
  }
  if (accessor == nullptr) {
    return nullptr;
  }
  return const_cast<void*>(reinterpret_cast<const void* (*)(void)>(accessor)());
}

static void* ResolveMetadataPtr(Config* config) {
  if (config.MetadataPtr != nil) {
    return config.MetadataPtr;
  }
  if (void* hostMetadata = HostExecutableMetadata()) {
    return hostMetadata;
  }
  if (void* defaultMetadata = DefaultFrameworkMetadata()) {
    return defaultMetadata;
  }
  std::string fatal =
      "no NativeScript metadata found. Pass Config.MetadataPtr, link a __DATA,__TNSMetadata "
      "section into the app executable (-sectcreate __DATA __TNSMetadata <metadata.bin>), or "
      "depend on the NativeScriptSDK package product, which bundles default metadata.";
  Log(@"Fatal: %s", fatal.c_str());
  throw tns::NativeScriptException("Fatal: " + fatal);
}

- (void)runScriptString:(NSString*)script runLoop:(BOOL)runLoop {
  std::string cppString = std::string([script UTF8String]);
  runtime_->RunScript(cppString);

  if (runLoop) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
  }

  tns::Tasks::Drain();
}

// A raw pointer so that exit() never runs ~Runtime from a static destructor:
// exit() can come from any thread while the main thread and every worker are
// still live, and a teardown then races them and the other static destructors.
// A dying process needs no teardown; shutdownRuntime is the deliberate path.
Runtime* runtime_ = nullptr;

// Cleared before ~Runtime runs so no caller sees a runtime mid-destruction.
static void DestroyMainRuntime() {
  Runtime* runtime = runtime_;
  runtime_ = nullptr;
  delete runtime;
}

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
    bool terminated = false;
    for (;;) {
      // Termination outranks everything, including an entry that settled in the
      // same slice: boot must report the terminating fatal rather than take the
      // normal exit and carry on into an app on a stopping isolate. Nothing
      // pending can complete after this point either. Both signals: V8 reports
      // only a materialized termination, which needs JS to run, and an entry
      // parked on a promise nothing settles never runs any.
      if (runtime_->IsExecutionTerminating() || runtime_->IsTerminationRequested()) {
        terminated = true;
        break;
      }
      if (!(entryPending || tns::HasPendingAsyncModuleGraphWork())) {
        break;
      }
      if (CFAbsoluteTimeGetCurrent() >= deadline) {
        break;
      }
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

    // A settled entry that never called UIApplicationMain is a script-style app
    // finishing normally. The failures below are fatal in every build: each one
    // evicts the entry first, so nothing can later import the half-evaluated
    // module the failure left behind, and then throws rather than logging and
    // returning into an app whose entry never ran.
    std::string fatal;
    if (terminated) {
      fatal = "boot ended with execution terminating before the main entry settled";
    } else if (entryRejected) {
      fatal = "the main entry module's evaluation rejected during boot: " + entryRejectionReason;
    } else if (entryPending) {
      char within[64];
      snprintf(within, sizeof(within), "%.0fs", 2 * tns::kModuleEvaluateDeadlineSeconds);
      fatal = std::string("main entry never settled and UIApplicationMain was never reached "
                          "within ") +
              within;
    }
    if (!fatal.empty()) {
      runtime_->EvictMainEntry();
      Log(@"Fatal: %s", fatal.c_str());
      throw tns::NativeScriptException("Fatal: " + fatal);
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
  DestroyMainRuntime();
}

- (instancetype)initializeWithConfig:(Config*)config {
  if (self = [super init]) {
    RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
    if (config.ApplicationPath != nil) {
      RuntimeConfig.ApplicationPath =
          [[config.BaseDir stringByAppendingPathComponent:config.ApplicationPath] UTF8String];
    } else {
      RuntimeConfig.ApplicationPath =
          [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
    }
    RuntimeConfig.MetadataPtr = ResolveMetadataPtr(config);
    RuntimeConfig.IsDebug = [config IsDebug];
    RuntimeConfig.LogToSystemConsole = [config LogToSystemConsole];

    Runtime::Initialize();
    DestroyMainRuntime();
    runtime_ = new Runtime();

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
          new v8_inspector::JsV8InspectorClient(runtime_);
      inspectorClient->init();
      inspectorClient->registerModules();
      // A nil Arguments array carries no inspector flags, whatever ArgumentsCount says.
      inspectorClient->connect(config.Arguments != nullptr ? config.ArgumentsCount : 0,
                               config.Arguments);
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
