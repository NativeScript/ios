#include "Runtime.h"
#include <chrono>
#include <string>
#include "ArgConverter.h"
#include "Caches.h"
#include "Console.h"
#include "Constants.h"
#include "Helpers.h"
#include "InlineFunctions.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "PromiseProxy.h"
#include "RuntimeConfig.h"
#include "SimpleAllocator.h"
#include "SpinLock.h"
#include "TSHelpers.h"
#include "WeakRef.h"
#include "Worker.h"
// #include "SetTimeout.h"

#include "DisposerPHV.h"
#include "IsolateWrapper.h"

#include <unordered_map>
#include "ModuleBinding.hpp"
#include "ModuleInternalCallbacks.h"
#include "URLImpl.h"
#include "URLPatternImpl.h"
#include "URLSearchParamsImpl.h"
#include <vector>
#include "HMRSupport.h"
#include "DevFlags.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

namespace {

bool GetOptionalStringProperty(v8::Isolate* isolate, v8::Local<v8::Context> context,
                               v8::Local<v8::Object> object, const char* key,
                               std::string* out) {
  if (out == nullptr) return false;

  v8::Local<v8::Value> value;
  if (!object->Get(context, tns::ToV8String(isolate, key)).ToLocal(&value) ||
      value->IsUndefined() || value->IsNull()) {
    return false;
  }

  v8::Local<v8::String> stringValue;
  if (!value->ToString(context).ToLocal(&stringValue)) {
    return false;
  }

  v8::String::Utf8Value utf8(isolate, stringValue);
  *out = *utf8 ? *utf8 : "";
  return true;
}

v8::Local<v8::Promise> CreateResolvedPromise(v8::Isolate* isolate,
                                             v8::Local<v8::Context> context) {
  v8::Local<v8::Promise::Resolver> resolver =
      v8::Promise::Resolver::New(context).ToLocalChecked();
  resolver->Resolve(context, v8::Undefined(isolate)).FromMaybe(false);
  return resolver->GetPromise();
}

v8::Local<v8::Promise> CreateRejectedPromise(v8::Local<v8::Context> context,
                                             v8::Local<v8::Value> reason) {
  v8::Local<v8::Promise::Resolver> resolver =
      v8::Promise::Resolver::New(context).ToLocalChecked();
  resolver->Reject(context, reason).FromMaybe(false);
  return resolver->GetPromise();
}

void MirrorFunctionOnGlobalThis(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                const char* name) {
  std::string src =
      "if (typeof globalThis !== 'undefined' && typeof globalThis." +
      std::string(name) +
      " !== 'function') {"
      "  Object.defineProperty(globalThis, '" + std::string(name) +
      "', { value: this." + std::string(name) +
      ", writable: true, configurable: true, enumerable: false });"
      "}";

  v8::Local<v8::Script> script;
  if (v8::Script::Compile(context, tns::ToV8String(isolate, src.c_str()))
          .ToLocal(&script)) {
    script->Run(context).FromMaybe(v8::Local<v8::Value>());
  }
}

}  // namespace

// Import meta callback to support import.meta.url
//
// `g_moduleRegistry` keys are normalized by `CanonicalizeRegistryKey`
// (in ModuleInternalCallbacks.mm) to one of:
//
//   1. HTTP / HTTPS URL — `http://host:port/path` or `https://...`.
//      The URL IS the module identity;
//      `import.meta.url` should be the URL verbatim.
//
//   2. Custom scheme — `ns-vendor://...`, `node:fs`, `blob:...`,
//      `optional:...`. Synthetic / built-in modules that aren't backed
//      by the local filesystem. Their identity is the scheme + body
//      itself; `import.meta.url` keeps that string unchanged.
//
//   3. Absolute filesystem path — `/Users/.../app/src/foo.js`. The
//      historical production / non-HMR dev shape. Strip the runtime
//      base dir to recover the legacy "/app/<rel>" shape JS consumers
//      have always seen, then prepend `file://` so the result is a
//      well-formed URL.
//
static void InitializeImportMetaObject(Local<Context> context, Local<Module> module,
                                       Local<Object> meta) {
  Isolate* isolate = context->GetIsolate();

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

  auto hasUrlScheme = [](const std::string& s) -> bool {
    if (s.empty()) return false;
    size_t colonPos = s.find(':');
    if (colonPos == 0 || colonPos == std::string::npos) return false;
    size_t slashPos = s.find('/');
    if (slashPos != std::string::npos && slashPos < colonPos) return false;
    for (size_t i = 0; i < colonPos; i++) {
      char c = s[i];
      const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                      (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
      if (!ok) return false;
    }
    return true;
  };

  // Compute import.meta.url.
  std::string moduleUrl;
  if (modulePath.empty()) {
    moduleUrl = "file:///app/";
  } else if (hasUrlScheme(modulePath)) {
    moduleUrl = modulePath;
  } else {
    std::string base = tns::ReplaceAll(modulePath, RuntimeConfig.BaseDir, "");
    moduleUrl = "file://" + base;
  }

  Local<String> url =
      String::NewFromUtf8(isolate, moduleUrl.c_str(), NewStringType::kNormal).ToLocalChecked();

  // Set import.meta.url property
  meta->CreateDataProperty(
          context, String::NewFromUtf8(isolate, "url", NewStringType::kNormal).ToLocalChecked(),
          url)
      .Check();

  // Compute import.meta.dirname.
  //
  // Spec (Node.js): `import.meta.dirname` is the OS-path of the
  // directory containing the module — equivalent to `path.dirname(
  // fileURLToPath(import.meta.url))`. It only makes sense for modules
  // backed by the local filesystem.
  //
  // For URL-backed modules (HTTP, ns-vendor, blob, etc.) there is no
  // filesystem directory. We return the URL with the final segment
  // stripped — a best-effort answer that's stable across cycles and
  // useful for log lines / source maps. Consumers that genuinely need
  // a filesystem path should already be guarding on `meta.url`'s
  // scheme before using `meta.dirname`.
  std::string dirname;
  if (modulePath.empty()) {
    dirname = "/app";
  } else if (hasUrlScheme(modulePath)) {
    size_t schemeEnd = modulePath.find("://");
    size_t pathStart = (schemeEnd == std::string::npos) ? std::string::npos
                                                        : modulePath.find('/', schemeEnd + 3);
    size_t lastSlash = modulePath.find_last_of('/');
    if (pathStart != std::string::npos && lastSlash != std::string::npos &&
        lastSlash > pathStart) {
      dirname = modulePath.substr(0, lastSlash);
    } else {
      // No path beyond the host (`http://host`) or scheme without `//`
      // (`node:fs`, `blob:abc`). Keep the identity intact.
      dirname = modulePath;
    }
  } else {
    size_t lastSlash = modulePath.find_last_of("/\\");
    if (lastSlash != std::string::npos) {
      dirname = modulePath.substr(0, lastSlash);
    } else {
      dirname = "/app";  // fallback
    }
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
static std::unordered_map<std::string, id> AppConfigCache; // generic cache for app config values
static std::mutex AppConfigCacheMutex;

// Global flag to track when JavaScript errors occur during execution
bool jsErrorOccurred = false;
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

  // TODO: fix race condition on workers where a queue can leak (maybe calling Terminate before
  // Initialize?)
  Caches::Workers->ForEach([currentIsolate](int& key, std::shared_ptr<Caches::WorkerState>& value) {
    auto childWorkerWrapper = static_cast<WorkerWrapper*>(value->UserData());
    if (childWorkerWrapper->GetMainIsolate() == currentIsolate) {
      childWorkerWrapper->Terminate();
    }
    return false;
  });

  {
    v8::Locker lock(isolate_);

    // Clear module registry before disposing other handles.
    // This prevents crashes during g_moduleRegistry cleanup. The registry is
    // `thread_local` (each NS isolate has its own per-thread map; see
    // ModuleInternalCallbacks.mm for rationale), so this loop walks ONLY the
    // entries that this destructor's thread/isolate created.
    extern thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_moduleRegistry;
    for (auto& kv : g_moduleRegistry) {
      kv.second.Reset();
    }
    g_moduleRegistry.clear();

    // Clear HMR + import-map globals (`g_importMap`, `g_hotData`,
    // `g_hotAccept`, `g_hotDispose`, `g_hotPrune`, `g_hotEventListeners`,
    // `g_hotDeclined`, `g_vendorModuleCache`, etc.) before isolate disposal.
    // These hold v8::Global handles that would crash during static destructor
    // cleanup if the isolate is already torn down.
    //
    // CRITICAL: these globals are PROCESS-WIDE, not per-isolate. They live
    // in the main isolate's address space but every Runtime destructor would
    // clear them. That's wrong for worker-isolate teardown: when a worker
    // dies (e.g. via `__nsTerminateAllWorkers` during an HMR cycle), its
    // Runtime destructor MUST NOT wipe the main isolate's import map and
    // hot-state — doing so silently breaks the next HMR cycle's bare-
    // specifier resolution (vendor packages fall back to filesystem and
    // fail with `Cannot find module @scope/pkg`).
    //
    // Worker isolates have their own `g_moduleRegistry` (thread_local,
    // cleared above), but they SHARE the static globals with the main
    // isolate. So we gate this cleanup on "this is the main isolate" —
    // worker teardown leaves the shared globals intact and the main
    // isolate continues serving HMR cycles uninterrupted. Real
    // process-teardown still routes through the main isolate's
    // destructor, so the cleanup eventually fires.
    if (!IsRuntimeWorker()) {
      tns::CleanupHMRGlobals();
      tns::CleanupImportMapGlobals();
      tns::ResetActiveDevSession();
    }

    DisposerPHV phv(isolate_);
    isolate_->VisitHandlesWithClassIds(&phv);

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

    Runtime::platform_ = platform::NewDefaultPlatform();

    V8::InitializePlatform(Runtime::platform_.get());
    V8::Initialize();
    std::string flags =
        RuntimeConfig.IsDebug ? "--expose_gc --jitless" : "--expose_gc --jitless --no-lazy";
    V8::SetFlagsFromString(flags.c_str(), flags.size());
    v8Initialized_ = true;
  }

  startTime = platform_->MonotonicallyIncreasingTime();
  realtimeOrigin = platform_->CurrentClockTimeMillis();

  // auto version = v8::V8::GetVersion();

  Isolate::CreateParams create_params;
  create_params.array_buffer_allocator = &allocator_;
  Isolate* isolate = Isolate::New(create_params);
  runtimeLoop_ = CFRunLoopGetCurrent();
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
  DefinePerformanceObject(isolate, globalTemplate);
  DefineTimeMethod(isolate, globalTemplate);
  DefineDrainMicrotaskMethod(isolate, globalTemplate);
  // queueMicrotask(callback) per spec
  {
    Local<FunctionTemplate> qmtTemplate = FunctionTemplate::New(
        isolate, [](const FunctionCallbackInfo<Value>& info) {
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

  Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
  context->Enter();

  DefineGlobalObject(context, isWorker);
  DefineCollectFunction(context);
  PromiseProxy::Init(context);
  Console::Init(context);
  WeakRef::Init(context);
  
  // Initialize HMR runtime helpers for dev mode. These collectively expose
  // the JS-callable globals the @nativescript/vite HMR client uses to drain
  // per-module callbacks and check declined-module state before each reboot:
  //   - __NS_DISPATCH_HOT_EVENT__   — fire registered import.meta.hot.on() listeners
  //   - __nsRunHmrDispose            — drain import.meta.hot.dispose() callbacks
  //   - __nsRunHmrPrune              — drain import.meta.hot.prune() callbacks
  //   - __nsHasDeclinedModule        — check g_hotDeclined for full-reload fallback
  // All four installations share one try/catch — they have identical risk
  // profiles (single V8 function registration each) and a failure in any
  // one of them shouldn't abort the rest of runtime init.
  if (RuntimeConfig.IsDebug) {
    try {
      tns::InitializeHotEventDispatcher(isolate, context);
      tns::InitializeHotDisposeRunner(isolate, context);
      tns::InitializeHotPruneRunner(isolate, context);
      tns::InitializeHotDeclinedHelper(isolate, context);
    } catch (...) {
      // Don't crash if HMR setup fails
    }
  }

  auto installGlobalFunction = [&](const char* name, v8::FunctionCallback callback) {
    v8::Local<v8::FunctionTemplate> fnTpl =
        v8::FunctionTemplate::New(isolate, callback);
    v8::Local<v8::Function> fn = fnTpl->GetFunction(context).ToLocalChecked();
    fn->SetName(tns::ToV8String(isolate, name));
    context->Global()
        ->Set(context, tns::ToV8String(isolate, name), fn)
        .FromMaybe(false);
    MirrorFunctionOnGlobalThis(isolate, context, name);
  };

  // Install the session bootstrap runtime configuration hook for import map support.
  // __nsConfigureDevRuntime is the explicit host-runtime surface used by the
  // deterministic session bootstrap. __nsConfigureRuntime remains as a
  // compatibility alias while older entry paths still exist.
  {
    auto configureRuntimeCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
      bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

      if (info.Length() < 1 || !info[0]->IsObject()) {
        if (logScriptLoading) {
          Log(@"[__nsConfigureRuntime] expected config object argument");
        }
        return;
      }

      v8::Local<v8::Object> config = info[0].As<v8::Object>();

      // Process importMap: can be a JSON string or an object with { imports: {...} }
      v8::Local<v8::String> importMapKey = tns::ToV8String(isolate, "importMap");
      v8::Local<v8::Value> importMapVal;
      if (config->Get(ctx, importMapKey).ToLocal(&importMapVal) && !importMapVal->IsUndefined()) {
        std::string jsonStr;
        if (importMapVal->IsString()) {
          v8::String::Utf8Value utf8(isolate, importMapVal);
          if (*utf8) jsonStr = *utf8;
        } else if (importMapVal->IsObject()) {
          // Serialize object to JSON string
          v8::Local<v8::Object> jsonObj = ctx->Global()->Get(ctx,
            tns::ToV8String(isolate, "JSON")).ToLocalChecked().As<v8::Object>();
          v8::Local<v8::Function> stringify = jsonObj->Get(ctx,
            tns::ToV8String(isolate, "stringify")).ToLocalChecked().As<v8::Function>();
          v8::Local<v8::Value> args[] = { importMapVal };
          v8::Local<v8::Value> result;
          if (stringify->Call(ctx, jsonObj, 1, args).ToLocal(&result) && result->IsString()) {
            v8::String::Utf8Value utf8(isolate, result);
            if (*utf8) jsonStr = *utf8;
          }
        }
        if (!jsonStr.empty()) {
          SetImportMap(jsonStr);
          if (logScriptLoading) {
            Log(@"[__nsConfigureRuntime] import map set (%zu bytes)", jsonStr.size());
          }
        }
      }

      // Process volatilePatterns: array of strings
      v8::Local<v8::String> vpKey = tns::ToV8String(isolate, "volatilePatterns");
      v8::Local<v8::Value> vpVal;
      if (config->Get(ctx, vpKey).ToLocal(&vpVal) && vpVal->IsArray()) {
        v8::Local<v8::Array> arr = vpVal.As<v8::Array>();
        std::vector<std::string> patterns;
        for (uint32_t i = 0; i < arr->Length(); i++) {
          v8::Local<v8::Value> elem;
          if (arr->Get(ctx, i).ToLocal(&elem) && elem->IsString()) {
            v8::String::Utf8Value utf8(isolate, elem);
            if (*utf8) patterns.push_back(*utf8);
          }
        }
        if (!patterns.empty()) {
          SetVolatilePatterns(patterns);
          if (logScriptLoading) {
            Log(@"[__nsConfigureRuntime] %zu volatile patterns set", patterns.size());
          }
        }
      }
    };

    installGlobalFunction("__nsConfigureDevRuntime", configureRuntimeCallback);
    installGlobalFunction("__nsConfigureRuntime", configureRuntimeCallback);
    context->Global()
      ->CreateDataProperty(context,
                 tns::ToV8String(isolate, "__nsSupportsRuntimeConfigUrl"),
                 v8::Boolean::New(isolate, true))
      .Check();
  }

  {
    auto startDevSessionCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

      if (info.Length() < 1 || !info[0]->IsObject()) {
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::TypeError(
                     tns::ToV8String(isolate,
                                     "[__nsStartDevSession] expected config object"))));
        return;
      }

      v8::Local<v8::Object> config = info[0].As<v8::Object>();
      tns::DevSessionState next;
      std::string sessionError;
      if (!tns::ReadDevSessionConfig(isolate, ctx, config, &next, &sessionError)) {
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::TypeError(
                     tns::ToV8String(isolate, sessionError.c_str()))));
        return;
      }

      tns::DevSessionState previous = tns::GetActiveDevSessionSnapshot();
      bool sessionChanged = tns::HasDevSessionChanged(previous, next);
      bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

      if (sessionChanged && previous.active) {
        std::vector<std::string> staleUrls = tns::CollectSessionModuleUrls(previous);
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] session changed old=%s new=%s invalidating=%lu",
              previous.sessionId.c_str(), next.sessionId.c_str(),
              (unsigned long)staleUrls.size());
        }
        if (!staleUrls.empty()) {
          tns::InvalidateModules(isolate, ctx, staleUrls);
        }
      }

      if (!sessionChanged && previous.active && previous.started) {
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] session already active: %s",
              next.sessionId.c_str());
        }
        info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
        return;
      }

      bool nativeRuntimeConfigDelegationEnabled = false;
      {
        v8::Local<v8::Value> delegationFlag;
        if (ctx->Global()
                ->Get(ctx, tns::ToV8String(isolate, "__NS_EXPERIMENTAL_NATIVE_RUNTIME_CONFIG_URL__"))
                .ToLocal(&delegationFlag) &&
            !delegationFlag.IsEmpty() && !delegationFlag->IsUndefined() &&
            !delegationFlag->IsNull()) {
          nativeRuntimeConfigDelegationEnabled = delegationFlag->BooleanValue(isolate);
        }
      }

      if (!next.runtimeConfigUrl.empty() && nativeRuntimeConfigDelegationEnabled) {
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] runtimeConfigUrl fetch start session=%s url=%s",
              next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
        }
        std::string runtimeConfigError;
        if (!tns::ApplyDevRuntimeConfigFromUrl(next.runtimeConfigUrl,
                                               &runtimeConfigError)) {
          if (logScriptLoading) {
            Log(@"[__nsStartDevSession] runtimeConfigUrl fetch failed session=%s url=%s",
                next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
          }
          info.GetReturnValue().Set(CreateRejectedPromise(
              ctx, v8::Exception::Error(
                       tns::ToV8String(isolate, runtimeConfigError.c_str()))));
          return;
        }
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] runtimeConfigUrl fetch complete session=%s url=%s",
              next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
        }
      } else if (!next.runtimeConfigUrl.empty() && logScriptLoading) {
        Log(@"[__nsStartDevSession] runtimeConfigUrl native delegation disabled; using JS-configured runtime session=%s url=%s",
            next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
      }

      tns::ApplyDevSessionGlobals(isolate, ctx, next);

      tns::StoreActiveDevSession(next);

      Runtime* runtime = Runtime::GetRuntime(isolate);
      if (runtime == nullptr) {
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] runtime unavailable for session=%s",
              next.sessionId.c_str());
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsStartDevSession] runtime unavailable"))));
        return;
      }

      if (logScriptLoading) {
        Log(@"[__nsStartDevSession] clientUrl import start session=%s url=%s",
            next.sessionId.c_str(), next.clientUrl.c_str());
      }

      if (!runtime->RunModule(next.clientUrl)) {
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] clientUrl import failed session=%s url=%s",
              next.sessionId.c_str(), next.clientUrl.c_str());
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsStartDevSession] failed to import clientUrl"))));
        return;
      }

      if (logScriptLoading) {
        Log(@"[__nsStartDevSession] clientUrl import complete session=%s url=%s",
            next.sessionId.c_str(), next.clientUrl.c_str());
        Log(@"[__nsStartDevSession] entryUrl import start session=%s url=%s",
            next.sessionId.c_str(), next.entryUrl.c_str());
      }

      if (!runtime->RunModule(next.entryUrl)) {
        if (logScriptLoading) {
          Log(@"[__nsStartDevSession] entryUrl import failed session=%s url=%s",
              next.sessionId.c_str(), next.entryUrl.c_str());
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsStartDevSession] failed to import entryUrl"))));
        return;
      }

      next.started = true;
      tns::StoreActiveDevSession(next);

      if (logScriptLoading) {
        Log(@"[__nsStartDevSession] entryUrl import complete session=%s url=%s",
            next.sessionId.c_str(), next.entryUrl.c_str());
        Log(@"[__nsStartDevSession] session=%s imports complete; waiting for real app root commit",
            next.sessionId.c_str());
      }

      if (logScriptLoading) {
        Log(@"[__nsStartDevSession] session=%s platform=%s origin=%s client=%s entry=%s changed=%s",
            next.sessionId.c_str(), next.platform.c_str(), next.origin.c_str(),
            next.clientUrl.c_str(), next.entryUrl.c_str(),
            sessionChanged ? "true" : "false");
      }

      info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
    };

    installGlobalFunction("__nsStartDevSession", startDevSessionCallback);
  }

  {
    auto invalidateModulesCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

      if (info.Length() < 1 || !info[0]->IsArray()) {
        Log(@"[__nsInvalidateModules] expected array of URL strings");
        return;
      }

      v8::Local<v8::Array> urlsArray = info[0].As<v8::Array>();
      std::vector<std::string> urls;
      urls.reserve(urlsArray->Length());
      for (uint32_t index = 0; index < urlsArray->Length(); index++) {
        v8::Local<v8::Value> value;
        if (!urlsArray->Get(ctx, index).ToLocal(&value) || !value->IsString()) {
          continue;
        }

        v8::String::Utf8Value utf8(isolate, value);
        if (*utf8) {
          urls.emplace_back(*utf8);
        }
      }

      // Diagnostic: surface every URL the runtime is asked to drop, plus
      // a sample of currently-loaded module registry keys so we can
      // correlate "asked to evict X" against "actually had X loaded as
      // Y" when canonicalization differs (e.g. http://localhost vs
      // file:// or http:// with port).
      if (tns::IsScriptLoadingLogEnabled()) {
        Log(@"[ns-hmr-diag][ios-invalidate] called urls.count=%zu", urls.size());
        size_t shown = 0;
        for (const auto& u : urls) {
          if (shown >= 32) break;
          Log(@"[ns-hmr-diag][ios-invalidate] url[%zu]=%s", shown, u.c_str());
          shown++;
        }
        if (urls.size() > shown) {
          Log(@"[ns-hmr-diag][ios-invalidate] (hidden %zu more URL(s))", urls.size() - shown);
        }
      }

      tns::InvalidateModules(isolate, ctx, urls);
    };

    installGlobalFunction("__nsInvalidateModules", invalidateModulesCallback);
  }

  {
    //
    // `__nsKickstartHmrPrefetch(seedUrlOrUrls, options?)` lets HMR client
    // tell the runtime "the next re-import will walk this dep tree — please
    // pre-fill the loader cache with every reachable module body before V8
    // starts walking".
    //
    // Two argument shapes are accepted:
    //
    //   1. `seedUrl: string` — Legacy / cold-boot. The native side runs a
    //      16-way parallel BFS over the static imports of `seedUrl`,
    //      blocks the calling JS thread until the walk drains (or
    //      `timeoutMs` elapses), and stores every body in the
    //      speculative-prefetch cache. By the time the JS thread
    //      unblocks and triggers `import(seedUrl)`, V8's synchronous
    //      dep-tree walk hits memory instead of the network on every
    //      module — turning a ~3s 200-fetch refresh into ~150–250ms.
    //
    //   2. `urls: string[]` — HMR shape. The dev server already
    //      computed the inverse-dep closure of the changed file
    //      (`evictPaths` in the `ns:angular-update` payload). This form
    //      fetches *only* that exact set in parallel — no body scanning,
    //      no recursion. Skipping the BFS saves one round trip per graph
    //      level and avoids re-fetching modules V8 still has compiled.
    //      This is the shape the Angular HMR client uses on every save.
    //
    // Returns an object `{ ok, fetched, ms }` so JS can log the
    // result alongside the existing `[ns-hmr][angular] ok ...` line.
    // On failure (empty seed, URL blocked by remote-loading
    // security gate, or BFS timeout) `ok` is false; callers should
    // treat that as "no kickstart speedup this round" and fall
    // back to V8's normal synchronous walk, which always succeeds
    // independently.
    auto kickstartHmrPrefetchCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

      auto buildResult = [&](bool ok, size_t fetched, uint64_t elapsedMs) {
        v8::Local<v8::Object> result = v8::Object::New(isolate);
        result->Set(ctx, tns::ToV8String(isolate, "ok"), v8::Boolean::New(isolate, ok)).Check();
        result->Set(ctx, tns::ToV8String(isolate, "fetched"), v8::Integer::NewFromUnsigned(isolate, (uint32_t)fetched)).Check();
        result->Set(ctx, tns::ToV8String(isolate, "ms"), v8::Number::New(isolate, (double)elapsedMs)).Check();
        info.GetReturnValue().Set(result);
      };

      // Accept either a string seed (BFS-from-seed shape, kept for
      // cold-boot / legacy callers) or a string[] of URLs (HMR
      // cycle: dev server precomputed the inverse-dep closure; we
      // just need to fetch that exact set in parallel). Anything
      // else is a contract violation by the caller; log and return
      // early.
      if (info.Length() < 1 || (!info[0]->IsString() && !info[0]->IsArray())) {
        Log(@"[__nsKickstartHmrPrefetch] expected (seedUrl: string, options?) or (urls: string[], options?)");
        buildResult(false, 0, 0);
        return;
      }

      int maxConcurrent = 16;
      double timeoutSeconds = 10.0;
      if (info.Length() >= 2 && info[1]->IsObject()) {
        v8::Local<v8::Object> options = info[1].As<v8::Object>();

        v8::Local<v8::Value> mcVal;
        if (options->Get(ctx, tns::ToV8String(isolate, "maxConcurrent")).ToLocal(&mcVal) &&
            !mcVal.IsEmpty() && mcVal->IsNumber()) {
          double mc = mcVal->NumberValue(ctx).FromMaybe(16.0);
          if (mc >= 1.0 && mc <= 64.0) maxConcurrent = (int)mc;
        }

        v8::Local<v8::Value> toVal;
        if (options->Get(ctx, tns::ToV8String(isolate, "timeoutMs")).ToLocal(&toVal) &&
            !toVal.IsEmpty() && toVal->IsNumber()) {
          double ms = toVal->NumberValue(ctx).FromMaybe(10000.0);
          if (ms >= 100.0 && ms <= 60000.0) timeoutSeconds = ms / 1000.0;
        }
      }

      size_t fetched = 0;
      uint64_t elapsedMs = 0;

      if (info[0]->IsArray()) {
        // Multi-URL form — non-recursive parallel fetch of the
        // server-provided eviction closure.
        v8::Local<v8::Array> arr = info[0].As<v8::Array>();
        const uint32_t len = arr->Length();
        std::vector<std::string> urls;
        urls.reserve(len);
        for (uint32_t i = 0; i < len; i++) {
          v8::Local<v8::Value> elem;
          if (!arr->Get(ctx, i).ToLocal(&elem)) continue;
          if (!elem->IsString()) continue;
          v8::String::Utf8Value u8(isolate, elem);
          if (!*u8) continue;
          std::string s(*u8);
          if (s.empty()) continue;
          urls.push_back(std::move(s));
        }
        if (urls.empty()) {
          buildResult(false, 0, 0);
          return;
        }
        bool ok = tns::KickstartHmrPrefetchUrlsSync(urls, maxConcurrent, timeoutSeconds, &fetched, &elapsedMs);
        buildResult(ok, fetched, elapsedMs);
        return;
      }

      // Single-string form — legacy BFS-from-seed.
      v8::String::Utf8Value seedUtf8(isolate, info[0]);
      if (!*seedUtf8) {
        buildResult(false, 0, 0);
        return;
      }
      std::string seedUrl(*seedUtf8);

      bool ok = tns::KickstartHmrPrefetchSync(seedUrl, maxConcurrent, timeoutSeconds, &fetched, &elapsedMs);
      buildResult(ok, fetched, elapsedMs);
    };

    installGlobalFunction("__nsKickstartHmrPrefetch", kickstartHmrPrefetchCallback);
  }

  {
    auto reloadDevAppCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
      bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

      tns::DevSessionState session = tns::GetActiveDevSessionSnapshot();
      if (!session.active || session.entryUrl.empty()) {
        if (logScriptLoading) {
          Log(@"[__nsReloadDevApp] no active dev session");
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsReloadDevApp] no active dev session"))));
        return;
      }

      std::vector<std::string> sessionUrls = tns::CollectSessionModuleUrls(session);
      if (logScriptLoading) {
        Log(@"[__nsReloadDevApp] invalidating session=%s urls=%lu",
            session.sessionId.c_str(), (unsigned long)sessionUrls.size());
      }
      if (!sessionUrls.empty()) {
        tns::InvalidateModules(isolate, ctx, sessionUrls);
      }

      tns::SetDevSessionBootComplete(isolate, ctx, false);

      Runtime* runtime = Runtime::GetRuntime(isolate);
      if (runtime == nullptr) {
        if (logScriptLoading) {
          Log(@"[__nsReloadDevApp] runtime unavailable for session=%s",
              session.sessionId.c_str());
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsReloadDevApp] runtime unavailable"))));
        return;
      }

      if (logScriptLoading) {
        Log(@"[__nsReloadDevApp] entryUrl import start session=%s url=%s",
            session.sessionId.c_str(), session.entryUrl.c_str());
      }

      if (!runtime->RunModule(session.entryUrl)) {
        if (logScriptLoading) {
          Log(@"[__nsReloadDevApp] entryUrl import failed session=%s url=%s",
              session.sessionId.c_str(), session.entryUrl.c_str());
        }
        info.GetReturnValue().Set(CreateRejectedPromise(
            ctx, v8::Exception::Error(
                     tns::ToV8String(isolate,
                                     "[__nsReloadDevApp] failed to import entryUrl"))));
        return;
      }

      if (logScriptLoading) {
        Log(@"[__nsReloadDevApp] entryUrl import complete session=%s url=%s",
            session.sessionId.c_str(), session.entryUrl.c_str());
        Log(@"[__nsReloadDevApp] session=%s reload imports complete; waiting for real app root commit (invalidated=%lu)",
            session.sessionId.c_str(), (unsigned long)sessionUrls.size());
      }

      info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
    };

    installGlobalFunction("__nsReloadDevApp", reloadDevAppCallback);
  }

  {
    auto applyStyleUpdateCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

      // All [__nsApplyStyleUpdate] log surfaces below are gated on the
      // logScriptLoading flag (DevFlags::IsScriptLoadingLogEnabled). This
      // path runs on every CSS HMR apply, so we keep it silent unless the
      // developer opts in via nativescript.config.ts. Real V8 exceptions
      // are still surfaced via tns::LogError unconditionally so HMR
      // failures are never swallowed.
      const bool logEnabled = tns::IsScriptLoadingLogEnabled();

      if (info.Length() < 1 || !info[0]->IsObject()) {
        if (logEnabled) {
          Log(@"[__nsApplyStyleUpdate] expected payload object");
        }
        return;
      }

      v8::Local<v8::Object> payload = info[0].As<v8::Object>();
      std::string cssText;
      std::string url;
      GetOptionalStringProperty(isolate, ctx, payload, "cssText", &cssText);
      GetOptionalStringProperty(isolate, ctx, payload, "url", &url);

      if (cssText.empty()) {
        if (logEnabled) {
          Log(@"[__nsApplyStyleUpdate] missing cssText payload");
        }
        return;
      }

      v8::Local<v8::Value> applicationValue;
      if (!ctx->Global()
               ->Get(ctx, tns::ToV8String(isolate, "Application"))
               .ToLocal(&applicationValue) ||
          !applicationValue->IsObject()) {
        if (logEnabled) {
          Log(@"[__nsApplyStyleUpdate] Application is unavailable for %s",
              url.c_str());
        }
        return;
      }

      v8::Local<v8::Object> applicationObject = applicationValue.As<v8::Object>();

      v8::Local<v8::Value> addCssValue;
      if (!applicationObject
               ->Get(ctx, tns::ToV8String(isolate, "addCss"))
               .ToLocal(&addCssValue) ||
          !addCssValue->IsFunction()) {
        if (logEnabled) {
          Log(@"[__nsApplyStyleUpdate] Application.addCss is unavailable for %s",
              url.c_str());
        }
        return;
      }

      v8::TryCatch tc(isolate);
      v8::Local<v8::Value> args[] = {
          tns::ToV8String(isolate, cssText.c_str()),
      };
      v8::Local<v8::Value> ignored;
        bool addCssCalled = addCssValue.As<v8::Function>()
                    ->Call(ctx, applicationObject, 1, args)
                    .ToLocal(&ignored);

        if (addCssCalled && !tc.HasCaught()) {
        v8::Local<v8::Value> getRootViewValue;
        if (applicationObject
                ->Get(ctx, tns::ToV8String(isolate, "getRootView"))
                .ToLocal(&getRootViewValue) &&
            getRootViewValue->IsFunction()) {
          v8::Local<v8::Value> rootViewValue;
          if (getRootViewValue.As<v8::Function>()
                  ->Call(ctx, applicationObject, 0, nullptr)
                  .ToLocal(&rootViewValue) &&
              rootViewValue->IsObject()) {
            v8::Local<v8::Object> rootViewObject = rootViewValue.As<v8::Object>();
            v8::Local<v8::Value> cssStateChangeValue;
            if (rootViewObject
                    ->Get(ctx, tns::ToV8String(isolate, "_onCssStateChange"))
                    .ToLocal(&cssStateChangeValue) &&
                cssStateChangeValue->IsFunction()) {
              bool cssStateChanged = cssStateChangeValue.As<v8::Function>()
                                         ->Call(ctx, rootViewObject, 0, nullptr)
                                         .ToLocal(&ignored);
              (void)cssStateChanged;
            }
          }
        }
      }

      if (tc.HasCaught()) {
        if (logEnabled) {
          Log(@"[__nsApplyStyleUpdate] failed for %s", url.c_str());
        }
        tns::LogError(isolate, tc);
        return;
      }

      if (logEnabled) {
        Log(@"[__nsApplyStyleUpdate] applied %s", url.c_str());
      }
    };

    installGlobalFunction("__nsApplyStyleUpdate", applyStyleUpdateCallback);
  }

  {
    auto getLoadedModuleUrlsCallback = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* isolate = info.GetIsolate();
      v8::HandleScope scope(isolate);
      v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

      std::vector<std::string> urls = tns::GetLoadedModuleUrls();
      v8::Local<v8::Array> result =
          v8::Array::New(isolate, static_cast<int>(urls.size()));

      for (uint32_t index = 0; index < urls.size(); index++) {
        result
            ->Set(ctx, index, tns::ToV8String(isolate, urls[index].c_str()))
            .FromMaybe(false);
      }

      info.GetReturnValue().Set(result);
    };

    installGlobalFunction("__nsGetLoadedModuleUrls", getLoadedModuleUrlsCallback);
  }

  // URL.createObjectURL/revokeObjectURL and blob URL registry
  // Blob URLs have the format: blob:<origin>/<uuid>
  // We use blob:nativescript/<uuid> as NativeScript's origin identifier
  auto blob_methods = R"js(
    const BLOB_STORE = new Map();
    URL.createObjectURL = function (object, options = null) {
        try {
            if (object instanceof Blob || object instanceof File) {
                const id = NSUUID.UUID().UUIDString.toLowerCase();
                const ret = `blob:nativescript/${id}`;
                BLOB_STORE.set(ret, {
                    blob: object,
                    type: object?.type,
                    ext: options?.ext,
                });
                return ret;
            }
        } catch (error) {
            return null;
        }
        return null;
    };
    URL.revokeObjectURL = function (url) {
        BLOB_STORE.delete(url);
    };
    const InternalAccessor = class {};
    InternalAccessor.getData = function (url) {
        return BLOB_STORE.get(url);
    };
    // Get the text content directly from a blob URL (for HMR)
    InternalAccessor.getText = async function (url) {
        const data = BLOB_STORE.get(url);
        if (!data || !data.blob) return null;
        return await data.blob.text();
    };
    URL.InternalAccessor = InternalAccessor;
    Object.defineProperty(URL.prototype, 'searchParams', {
        get() {
            if (this._searchParams == null) {
                this._searchParams = new URLSearchParams(this.search);
                Object.defineProperty(this._searchParams, '_url', {
                    enumerable: false,
                    writable: false,
                    value: this,
                });
                this._searchParams._append = this._searchParams.append;
                this._searchParams.append = function (name, value) {
                    this._append(name, value);
                    this._url.search = this.toString();
                };
                this._searchParams._delete = this._searchParams.delete;
                this._searchParams.delete = function (name) {
                    this._delete(name);
                    this._url.search = this.toString();
                };
                this._searchParams._set = this._searchParams.set;
                this._searchParams.set = function (name, value) {
                    this._set(name, value);
                    this._url.search = this.toString();
                };
                this._searchParams._sort = this._searchParams.sort;
                this._searchParams.sort = function () {
                    this._sort();
                    this._url.search = this.toString();
                };
            }
            return this._searchParams;
        },
    });
    )js";

  v8::Local<v8::Script> script;
  auto done = v8::Script::Compile(context, ToV8String(isolate, blob_methods)).ToLocal(&script);

  v8::Local<v8::Value> outVal;
  if (done) {
    done = script->Run(context).ToLocal(&outVal);
  }

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

bool Runtime::RunModule(const std::string moduleName) {
  Isolate* isolate = this->GetIsolate();
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  return this->moduleInternal_->RunModule(isolate, moduleName);
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

  // Store in cache (can cache nil as NSNull to differentiate presence if desired; for now, cache as-is)
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
  Isolate* isolate = context->GetIsolate();
  Local<Object> global = context->Global();
  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  if (!global
           ->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "global"), global,
                               readOnlyFlags)
           .FromMaybe(false)) {
    tns::Assert(false, isolate);
  }

  if (isWorker && !global
                       ->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "self"),
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
  Isolate* isolate = context->GetIsolate();
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

void Runtime::DefinePerformanceObject(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  Local<ObjectTemplate> performanceTemplate = ObjectTemplate::New(isolate);

  Local<FunctionTemplate> nowFuncTemplate = FunctionTemplate::New(isolate, PerformanceNowCallback);
  performanceTemplate->Set(tns::ToV8String(isolate, "now"), nowFuncTemplate);

  performanceTemplate->Set(tns::ToV8String(isolate, "timeOrigin"),
                           v8::Number::New(isolate, realtimeOrigin));

  Local<v8::String> performancePropertyName = ToV8String(isolate, "performance");
  globalTemplate->Set(performancePropertyName, performanceTemplate);
}

void Runtime::PerformanceNowCallback(const FunctionCallbackInfo<Value>& args) {
  auto runtime = Runtime::GetRuntime(args.GetIsolate());
  args.GetReturnValue().Set(
      (runtime->platform_->MonotonicallyIncreasingTime() - runtime->startTime) * 1000.0);
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
