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

#include "ModuleBinding.hpp"
#include "ModuleInternalCallbacks.h"
#include "URLImpl.h"
#include "URLPatternImpl.h"
#include "URLSearchParamsImpl.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

namespace tns {

std::atomic<int> Runtime::nextIsolateId{0};
SimpleAllocator allocator_;
NSDictionary* AppPackageJson = nil;

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
  ObjectManager::Init(isolate, globalTemplate);
  //    SetTimeout::Init(isolate, globalTemplate);
  MetadataBuilder::RegisterConstantsOnGlobalObject(isolate, globalTemplate, isWorker);

  isolate->SetCaptureStackTraceForUncaughtExceptions(true, 100, StackTrace::kOverview);

  // Enable dynamic import() support (handle API rename across V8 versions)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  isolate->SetHostImportModuleDynamicallyCallback(tns::ImportModuleDynamicallyCallback);
#pragma clang diagnostic pop
  isolate->AddMessageListener(NativeScriptException::OnUncaughtError);

  Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
  context->Enter();

  DefineGlobalObject(context, isWorker);
  DefineCollectFunction(context);
  PromiseProxy::Init(context);
  Console::Init(context);
  WeakRef::Init(context);

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

  id result = AppPackageJson[[NSString stringWithUTF8String:key.c_str()]];
  return result;
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
