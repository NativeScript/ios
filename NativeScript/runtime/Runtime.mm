#include "Runtime.h"
#include <chrono>
#include <string>
#include "ArgConverter.h"
#include "BuiltinLoader.h"
#include "Caches.h"
#include "Console.h"
#include "Constants.h"
#include "ErrorEvents.h"
#include "Events.h"
#include "Helpers.h"
#include "InlineFunctions.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "NativeScriptPlatform.h"
#include "ObjectManager.h"
#include "Performance.h"
#include "PromiseProxy.h"
#include "RuntimeConfig.h"
#include "SimpleAllocator.h"
#include "SpinLock.h"
#include "StructuredClone.h"
#include "TSHelpers.h"
#include "WeakRef.h"
#include "Worker.h"
// #include "SetTimeout.h"

#include "IsolateWrapper.h"

#include <mutex>
#include <unordered_map>
#include "DevFlags.h"
#include "HMRSupport.h"
#include "ModuleBinding.hpp"
#include "ModuleInternalCallbacks.h"
#include "URLImpl.h"
#include "URLPatternImpl.h"
#include "URLSearchParamsImpl.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

// Import meta callback to support import.meta.url
static void InitializeImportMetaObject(Local<Context> context, Local<Module> module,
                                       Local<Object> meta) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  // Look up the module path in the global module registry (with safety checks)
  std::string modulePath;

  try {
    for (auto& kv : tns::g_moduleRegistry) {
      // Check if Global handle is empty before accessing
      if (kv.second.IsEmpty()) {
        continue;
      }

      Local<Module> registered = kv.second.Get(isolate);
      if (!registered.IsEmpty() && registered == module) {
        modulePath = kv.first;
        break;
      }
    }
  } catch (...) {
    // NSLog(@"[import.meta] Exception during module registry lookup, using fallback");
    modulePath = "";  // Will use fallback path
  }

  // Debug logging
  // NSLog(@"[import.meta] Module lookup: found path = %s",
  //       modulePath.empty() ? "(empty)" : modulePath.c_str());
  // NSLog(@"[import.meta] Registry size: %zu", tns::g_moduleRegistry.size());

  // Convert file path to file:// URL
  std::string moduleUrl;
  if (!modulePath.empty()) {
    // Remove base directory and create file:// URL
    std::string base = tns::ReplaceAll(modulePath, RuntimeConfig.BaseDir, "");
    moduleUrl = "file://" + base;
  } else {
    // Fallback URL if module not found in registry
    moduleUrl = "file:///app/";
  }

  // NSLog(@"[import.meta] Final URL: %s", moduleUrl.c_str());

  Local<String> url =
      String::NewFromUtf8(isolate, moduleUrl.c_str(), NewStringType::kNormal).ToLocalChecked();

  // Set import.meta.url property
  meta->CreateDataProperty(
          context, String::NewFromUtf8(isolate, "url", NewStringType::kNormal).ToLocalChecked(),
          url)
      .Check();

  // Add import.meta.dirname support (extract directory from path)
  std::string dirname;
  if (!modulePath.empty()) {
    size_t lastSlash = modulePath.find_last_of("/\\");
    if (lastSlash != std::string::npos) {
      dirname = modulePath.substr(0, lastSlash);
    } else {
      dirname = "/app";  // fallback
    }
  } else {
    dirname = "/app";  // fallback
  }

  Local<String> dirnameStr =
      String::NewFromUtf8(isolate, dirname.c_str(), NewStringType::kNormal).ToLocalChecked();

  // Set import.meta.dirname property
  meta->CreateDataProperty(
          context, String::NewFromUtf8(isolate, "dirname", NewStringType::kNormal).ToLocalChecked(),
          dirnameStr)
      .Check();

  if (RuntimeConfig.IsDebug) {
    // Attach minimal import.meta.hot only in dev
    try {
      tns::InitializeImportMetaHot(isolate, context, meta, modulePath);
    } catch (...) {
      // If anything fails, keep meta without hot to avoid crashing
    }
  }
}

namespace tns {

std::atomic<int> Runtime::nextIsolateId{0};
SimpleAllocator allocator_;
NSDictionary* AppPackageJson = nil;
static std::unordered_map<std::string, id> AppConfigCache;  // generic cache for app config values
static std::mutex AppConfigCacheMutex;

// Global flag to track if error display is currently showing
bool isErrorDisplayShowing = false;

// TODO: consider listening to timezone changes and automatically reseting the DateTime. Probably
// makes more sense to move it to its own file
// void UpdateTimezoneNotificationCallback(CFNotificationCenterRef center,
//                void *observer,
//                CFStringRef name,
//                const void *object,
//                CFDictionaryRef userInfo) {
//    Runtime* r = (Runtime*)observer;
//    auto isolate = r->GetIsolate();
//
//    CFRunLoopPerformBlock(r->RuntimeLoop(), kCFRunLoopDefaultMode, ^() {
//        TODO: lock isolate here?
//        isolate->DateTimeConfigurationChangeNotification(Isolate::TimeZoneDetection::kRedetect);
//    });
//}
// add this to register (most likely on setting up isolate
// CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), this,
// &UpdateTimezoneNotificationCallback, kCFTimeZoneSystemTimeZoneDidChangeNotification, nullptr,
// CFNotificationSuspensionBehaviorDeliverImmediately);
// add this to remove the observer
// CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), this,
// kCFTimeZoneSystemTimeZoneDidChangeNotification, NULL);

void DisposeIsolateWhenPossible(Isolate* isolate) {
  // most of the time, this will never delay disposal
  // occasionally this can happen when the runtime is destroyed by actions of its own isolate
  // as an example: isolate calls exit(0), which in turn destroys the Runtime unique_ptr
  // another scenario is when embedding nativescript, if the embedder deletes the runtime as a
  // result of a callback from JS in the case of exit(0), the app will die before actually disposing
  // the isolate, which isn't a problem
  if (isolate->IsInUse()) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                     DisposeIsolateWhenPossible(isolate);
                   });
  } else {
    isolate->Dispose();
  }
}

void Runtime::Initialize() { MetaFile::setInstance(RuntimeConfig.MetadataPtr); }

Runtime::Runtime() {
  currentRuntime_ = this;
  workerId_ = -1;
  workerCache_ = Caches::Workers;
}

Runtime::~Runtime() {
  // Tear the rejection observer down before any isolate teardown: it references
  // the isolate and reads Caches, both of which are invalidated below.
  if (rejectionObserver_ != nullptr) {
    CFRunLoopObserverInvalidate(rejectionObserver_);
    CFRelease(rejectionObserver_);
    rejectionObserver_ = nullptr;
  }

  // Drop any pending uncaughtErrorPolicy "throw" deposit for this isolate so a
  // stale entry can't outlive the isolate it keys on.
  NativeScriptException::OnIsolateTeardown(isolate_);

  auto currentIsolate = this->isolate_;
  {
    // make sure we remove the isolate from the list of active isolates first
    // this will make sure isAlive(isolate) will return false and prevent locking of the v8 isolate
    // after it terminates execution
    SpinLock lock(isolatesMutex_);
    Runtime::isolates_.erase(
        std::remove(Runtime::isolates_.begin(), Runtime::isolates_.end(), this->isolate_),
        Runtime::isolates_.end());
    Caches::Get(isolate_)->InvalidateIsolate();
  }
  this->isolate_->TerminateExecution();

  Caches::Workers->ForEach([currentIsolate](int& key, std::shared_ptr<Caches::WorkerState>& value) {
    auto childWorkerWrapper = static_cast<WorkerWrapper*>(value->UserData());
    if (childWorkerWrapper->GetMainIsolate() == currentIsolate) {
      childWorkerWrapper->Terminate();
    }
    return false;
  });

  {
    v8::Locker lock(isolate_);

    // Stop the event loop before any handle disposal: queued entries touch
    // caches and persistents that go away below, and posts from other threads
    // must start dropping now.
    if (eventLoop_ != nullptr) {
      eventLoop_->Shutdown();
    }

    // Clear module registry before disposing other handles
    // This prevents crashes during g_moduleRegistry cleanup
    extern std::unordered_map<std::string, v8::Global<v8::Module>> g_moduleRegistry;
    for (auto& kv : g_moduleRegistry) {
      kv.second.Reset();
    }
    g_moduleRegistry.clear();

    ObjectManager::DisposeAllRegistered(isolate_);

    if (IsRuntimeWorker()) {
      auto currentWorker =
          static_cast<WorkerWrapper*>(Caches::Workers->Get(this->workerId_)->UserData());
      Caches::Workers->Remove(this->workerId_);
      // if the parent isolate is dead then deleting the wrapper is our responsibility
      if (currentWorker->IsWeak()) {
        delete currentWorker;
      }
    }
    Caches::Remove(this->isolate_);

    this->isolate_->SetData(Constants::RUNTIME_SLOT, nullptr);
  }

  DisposeIsolateWhenPossible(this->isolate_);

  // Matched erase: only removes the registry entry while it still maps to
  // this runtime's loop, so a worker isolate that reuses this pointer after
  // the (possibly deferred) Dispose can't be evicted by us.
  if (eventLoop_ != nullptr) {
    NativeScriptPlatform::Instance()->IsolateDisposed(currentIsolate, eventLoop_);
  }

  currentRuntime_ = nullptr;
}

Runtime* Runtime::GetRuntime(v8::Isolate* isolate) {
  return static_cast<Runtime*>(isolate->GetData(Constants::RUNTIME_SLOT));
}

Isolate* Runtime::CreateIsolate() {
  if (!v8Initialized_) {
    // Runtime::platform_ = RuntimeConfig.IsDebug
    //     ? v8_inspector::V8InspectorPlatform::CreateDefaultPlatform()
    //     : platform::NewDefaultPlatform();

    // Flags must be set before V8::Initialize(), which freezes them; changing a
    // flag afterwards aborts the process. Don't pass --jitless either:
    // v8_enable_lite_mode already implies it and makes the flag read-only,
    // which is likewise fatal to set.
    std::string flags = RuntimeConfig.IsDebug ? "--expose_gc" : "--expose_gc --no-lazy";
    V8::SetFlagsFromString(flags.c_str(), flags.size());

    // wrap the default platform so foreground tasks ride each runtime
    // thread's CFRunLoop instead of sitting in never-pumped libplatform queues
    Runtime::platform_ = std::make_shared<NativeScriptPlatform>(platform::NewDefaultPlatform());

    V8::InitializePlatform(Runtime::platform_.get());
    V8::Initialize();
    v8Initialized_ = true;
  }

  timeOriginMonotonic_ = platform_->MonotonicallyIncreasingTime();
  timeOriginRealtimeMs_ = platform_->CurrentClockTimeMillis();

  // auto version = v8::V8::GetVersion();

  Isolate::CreateParams create_params;
  create_params.array_buffer_allocator = &allocator_;
  Isolate* isolate = Isolate::New(create_params);
  runtimeLoop_ = CFRunLoopGetCurrent();
  // v8 already asked for this isolate's task runner during Isolate::New, so
  // the registry may hold an unbound loop - or a stopped one, when a worker
  // isolate reuses a disposed isolate's address. Refresh, then attach to this
  // thread; foreground tasks buffered so far start flowing from here on.
  eventLoop_ = NativeScriptPlatform::Instance()->RefreshEventLoop(isolate);
  eventLoop_->BindToCurrentThread();
  isolate->SetData(Constants::RUNTIME_SLOT, this);

  {
    SpinLock lock(isolatesMutex_);
    Runtime::isolates_.emplace_back(isolate);
  }

  return isolate;
}

void Runtime::Init(Isolate* isolate, bool isWorker) {
  std::shared_ptr<Caches> cache =
      Caches::Init(isolate, nextIsolateId.fetch_add(1, std::memory_order_relaxed));
  cache->isWorker = isWorker;
  cache->ObjectCtorInitializer = MetadataBuilder::GetOrCreateConstructorFunctionTemplate;
  cache->StructCtorInitializer = MetadataBuilder::GetOrCreateStructCtorFunction;

  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  Local<FunctionTemplate> globalTemplateFunction = FunctionTemplate::New(isolate);
  globalTemplateFunction->SetClassName(tns::ToV8String(isolate, "NativeScriptGlobalObject"));
  tns::binding::CreateInternalBindingTemplates(isolate, globalTemplateFunction);
  Local<ObjectTemplate> globalTemplate = ObjectTemplate::New(isolate, globalTemplateFunction);
  DefineNativeScriptVersion(isolate, globalTemplate);

  // Worker::Init(isolate, globalTemplate, isWorker);
  DefineTimeMethod(isolate, globalTemplate);
  DefineDrainMicrotaskMethod(isolate, globalTemplate);
  DefineQueueMacrotaskMethod(isolate, globalTemplate);
  // queueMicrotask(callback) per spec
  {
    Local<FunctionTemplate> qmtTemplate =
        FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
          auto* isolate = info.GetIsolate();
          if (info.Length() < 1 || !info[0]->IsFunction()) {
            isolate->ThrowException(Exception::TypeError(
                tns::ToV8String(isolate, "queueMicrotask: callback must be a function")));
            return;
          }
          v8::Local<v8::Function> cb = info[0].As<v8::Function>();
          isolate->EnqueueMicrotask(cb);
        });
    globalTemplate->Set(tns::ToV8String(isolate, "queueMicrotask"), qmtTemplate);
  }
  ObjectManager::Init(isolate, globalTemplate);
  //    SetTimeout::Init(isolate, globalTemplate);
  MetadataBuilder::RegisterConstantsOnGlobalObject(isolate, globalTemplate, isWorker);

  isolate->SetCaptureStackTraceForUncaughtExceptions(true, 100, StackTrace::kOverview);

  // Enable dynamic import() support (handle API rename across V8 versions)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  isolate->SetHostImportModuleDynamicallyCallback(tns::ImportModuleDynamicallyCallback);
#pragma clang diagnostic pop

  // Set up import.meta callback
  isolate->SetHostInitializeImportMetaObjectCallback(InitializeImportMetaObject);

  isolate->AddMessageListener(NativeScriptException::OnUncaughtError);
  isolate->SetPromiseRejectCallback(NativeScriptException::OnPromiseRejected);

  Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
  context->Enter();

  // Drain tracked unhandled promise rejections once per runloop turn, just
  // before the loop sleeps. The info pointer is the isolate; the callback
  // re-validates liveness because the isolate may be torn down between turns.
  CFRunLoopObserverContext observerContext = {0, isolate, nullptr, nullptr, nullptr};
  rejectionObserver_ =
      CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, /*repeats*/ true,
                              /*order*/ 0, Runtime::DrainRejectionsObserver, &observerContext);
  CFRunLoopAddObserver(runtimeLoop_, rejectionObserver_, kCFRunLoopCommonModes);

  DefineGlobalObject(context, isWorker);
  DefineCollectFunction(context);
  PromiseProxy::Init(context);
  Events::Init(context);
  ErrorEvents::Init(context);
  StructuredClone::Init(context);
  Performance::Init(context);
  Console::Init(context);
  WeakRef::Init(context);

  // URL blob support (internal/blob-url.js); failures are tolerated, matching
  // the previous compile-and-run-if-possible behavior.
  v8::Local<v8::Value> blobMethodsResult;
  bool blobMethodsOk =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kBlobUrl).ToLocal(&blobMethodsResult);
  (void)blobMethodsOk;

  this->moduleInternal_ = std::make_unique<ModuleInternal>(context);

  ArgConverter::Init(context, MetadataBuilder::StructPropertyGetterCallback,
                     MetadataBuilder::StructPropertySetterCallback);
  Interop::RegisterInteropTypes(context);

  ClassBuilder::RegisterBaseTypeScriptExtendsFunction(
      context);  // Register the __extends function to the global object
  ClassBuilder::RegisterNativeTypeScriptExtendsFunction(
      context);  // Override the __extends function for native objects
  TSHelpers::Init(context);

  InlineFunctions::Init(context);

  cache->SetContext(context);

  this->isolate_ = isolate;
}

void Runtime::RunMainScript() {
  Isolate* isolate = this->GetIsolate();
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  this->moduleInternal_->RunModule(isolate, "./");
}

void Runtime::RunModule(const std::string moduleName) {
  Isolate* isolate = this->GetIsolate();
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  this->moduleInternal_->RunModule(isolate, moduleName);
}

void Runtime::RunScript(const std::string script) {
  Isolate* isolate = this->GetIsolate();
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  this->moduleInternal_->RunScript(isolate, script);
}

Isolate* Runtime::GetIsolate() { return this->isolate_; }

const int Runtime::WorkerId() { return this->workerId_; }

void Runtime::SetWorkerId(int workerId) { this->workerId_ = workerId; }

id Runtime::GetAppConfigValue(std::string key) {
  if (AppPackageJson == nil) {
    NSString* packageJsonPath =
        [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:@"package.json"];
    NSData* data = [NSData dataWithContentsOfFile:packageJsonPath];
    if (data) {
      NSError* error = nil;
      NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data
                                                           options:kNilOptions
                                                             error:&error];
      AppPackageJson = [[NSDictionary alloc] initWithDictionary:dict];
    }
  }

  // Generic cache for all keys to avoid repeated NSString conversion and NSDictionary hashing
  {
    std::lock_guard<std::mutex> lock(AppConfigCacheMutex);
    auto it = AppConfigCache.find(key);
    if (it != AppConfigCache.end()) {
      return it->second;
    }
  }

  id result = nil;
  if (AppPackageJson != nil) {
    NSString* nsKey = [NSString stringWithUTF8String:key.c_str()];
    result = AppPackageJson[nsKey];
  }

  // Store in cache (can cache nil as NSNull to differentiate presence if desired; for now, cache
  // as-is)
  {
    std::lock_guard<std::mutex> lock(AppConfigCacheMutex);
    AppConfigCache[key] = result;
  }

  return result;
}

bool Runtime::showErrorDisplay() {
  id value = GetAppConfigValue("showErrorDisplay");
  return value ? [value boolValue] : false;
}

void Runtime::DefineGlobalObject(Local<Context> context, bool isWorker) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();
  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  if (!global
           ->DefineOwnProperty(context, ToV8String(v8::Isolate::GetCurrent(), "global"), global,
                               readOnlyFlags)
           .FromMaybe(false)) {
    tns::Assert(false, isolate);
  }

  if (isWorker && !global
                       ->DefineOwnProperty(context, ToV8String(v8::Isolate::GetCurrent(), "self"),
                                           global, readOnlyFlags)
                       .FromMaybe(false)) {
    tns::Assert(false, isolate);
  }

  if (isWorker) {
    // Register proper interop types for worker context
    // Worker bundles need full interop functionality, not just simple stubs
    tns::Interop::RegisterInteropTypes(context);
  }
}

void Runtime::DefineCollectFunction(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();
  Local<Value> value;
  bool success = global->Get(context, tns::ToV8String(isolate, "gc")).ToLocal(&value);
  tns::Assert(success, isolate);

  if (value.IsEmpty() || !value->IsFunction()) {
    return;
  }

  Local<v8::Function> gcFunc = value.As<v8::Function>();
  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  success =
      global
          ->DefineOwnProperty(context, tns::ToV8String(isolate, "__collect"), gcFunc, readOnlyFlags)
          .FromMaybe(false);
  tns::Assert(success, isolate);
}

double Runtime::PerformanceNowMillis() {
  return (platform_->MonotonicallyIncreasingTime() - timeOriginMonotonic_) * 1000.0;
}

void Runtime::DefineNativeScriptVersion(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  globalTemplate->Set(ToV8String(isolate, "__runtimeVersion"),
                      ToV8String(isolate, STRINGIZE_VALUE_OF(NATIVESCRIPT_VERSION)), readOnlyFlags);
}

void Runtime::DefineTimeMethod(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
  Local<FunctionTemplate> timeFunctionTemplate =
      FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        auto nano = std::chrono::time_point_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now());
        double duration = nano.time_since_epoch().count() / 1000000.0;
        info.GetReturnValue().Set(duration);
      });
  globalTemplate->Set(ToV8String(isolate, "__time"), timeFunctionTemplate);
}

void Runtime::DefineDrainMicrotaskMethod(v8::Isolate* isolate,
                                         v8::Local<v8::ObjectTemplate> globalTemplate) {
  Local<FunctionTemplate> drainMicrotaskTemplate =
      FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        info.GetIsolate()->PerformMicrotaskCheckpoint();
      });
  globalTemplate->Set(ToV8String(isolate, "__drainMicrotaskQueue"), drainMicrotaskTemplate);
}

// TODO: remove the __ns__ prefix once the event loop's ordered lane backs
// public macrotask APIs (performance observers etc.)
void Runtime::DefineQueueMacrotaskMethod(v8::Isolate* isolate,
                                         v8::Local<v8::ObjectTemplate> globalTemplate) {
  Local<FunctionTemplate> queueMacrotaskTemplate =
      FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        auto* isolate = info.GetIsolate();
        if (info.Length() < 1 || !info[0]->IsFunction()) {
          isolate->ThrowException(Exception::TypeError(
              tns::ToV8String(isolate, "__ns__queueMacrotask: callback must be a function")));
          return;
        }
        Runtime* runtime = Runtime::GetRuntime(isolate);
        if (runtime == nullptr || runtime->GetEventLoop() == nullptr) {
          return;
        }
        auto callback =
            std::make_shared<Persistent<v8::Function>>(isolate, info[0].As<v8::Function>());
        // the ordered lane rides the home runloop's performed-block order, so
        // the callback runs as a macrotask in strict FIFO order with JS timers
        runtime->GetEventLoop()->PostOrdered([isolate, callback]() {
          auto cache = Caches::Get(isolate);
          Local<Context> context = cache->GetContext();
          Context::Scope context_scope(context);
          Local<v8::Function> cb = callback->Get(isolate);
          callback->Reset();
          // no TryCatch: like timer callbacks, uncaught errors surface
          // through the isolate's message listener
          (void)cb->Call(context, context->Global(), 0, nullptr);
        });
      });
  globalTemplate->Set(ToV8String(isolate, "__ns__queueMacrotask"), queueMacrotaskTemplate);
}

void Runtime::DefineDateTimeConfigurationChangeNotificationMethod(
    v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
  Local<FunctionTemplate> drainMicrotaskTemplate =
      FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        info.GetIsolate()->DateTimeConfigurationChangeNotification(
            Isolate::TimeZoneDetection::kRedetect);
      });
  globalTemplate->Set(ToV8String(isolate, "__dateTimeConfigurationChangeNotification"),
                      drainMicrotaskTemplate);
}

void Runtime::DrainRejectionsObserver(CFRunLoopObserverRef observer, CFRunLoopActivity activity,
                                      void* info) {
  Isolate* isolate = static_cast<Isolate*>(info);
  if (!Runtime::IsAlive(isolate)) {
    return;
  }
  auto cache = Caches::Get(isolate);
  // HasPending is an atomic read: OnReject can run on any thread holding the
  // v8::Locker, so pending_ itself must only be touched under the lock below.
  if (!cache->IsValid() || cache->PromiseRejections == nullptr ||
      !cache->PromiseRejections->HasPending()) {
    return;
  }

  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  Local<Context> context = cache->GetContext();
  Context::Scope context_scope(context);
  cache->PromiseRejections->Drain(context);
}

bool Runtime::IsAlive(const Isolate* isolate) {
  // speedup lookup by avoiding locking if thread locals match
  // note: this can be a problem when the Runtime is deleted in a different thread that it was
  // created which could happen under some specific embedding scenarios
  if ((Isolate::TryGetCurrent() == isolate ||
       (currentRuntime_ != nullptr && currentRuntime_->GetIsolate() == isolate)) &&
      Caches::Get((Isolate*)isolate)->IsValid()) {
    return true;
  }
  SpinLock lock(isolatesMutex_);
  return std::find(Runtime::isolates_.begin(), Runtime::isolates_.end(), isolate) !=
         Runtime::isolates_.end();
}

std::shared_ptr<Platform> Runtime::platform_;
std::vector<Isolate*> Runtime::isolates_;
bool Runtime::v8Initialized_ = false;
thread_local Runtime* Runtime::currentRuntime_ = nullptr;
SpinMutex Runtime::isolatesMutex_;

}  // namespace tns
