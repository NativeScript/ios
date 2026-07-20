#ifndef Runtime_h
#define Runtime_h

#include "Caches.h"
#include "Common.h"
#include "MetadataBuilder.h"
#include "ModuleInternal.h"
#include "SpinLock.h"
#include "libplatform/libplatform.h"

#include <functional>
#include <string>

namespace tns {

using ReloadApplicationHook = std::function<bool(const std::string& baseDir)>;
void SetReloadApplicationHook(ReloadApplicationHook hook);
bool InvokeReloadApplicationHook(const std::string& baseDir);

// Number of times the runtime has been soft-rebooted in this process
// (restartWithConfig / reloadApplication). 0 for the first boot. Exposed to JS
// as `NativeScriptRuntime.reloadCount` so application code (e.g.
// @nativescript/core) can detect a reloaded instance and reattach native
// delegates (UIApplication delegate, UIScene delegates) that are still pinned
// to classes created by the previous isolate.
void IncrementRuntimeReloadCount();
int GetRuntimeReloadCount();

class Runtime {
 public:
  Runtime();
  ~Runtime();
  v8::Isolate* CreateIsolate();
  void Init(v8::Isolate* isolate, bool isWorker = false);
  void RunMainScript();
  v8::Isolate* GetIsolate();

  const int WorkerId();

  void SetWorkerId(int workerId);
  inline bool IsRuntimeWorker() { return workerId_ > 0; }

  inline CFRunLoopRef RuntimeLoop() { return runtimeLoop_; }

  // Forwards `outErrorMessage` to `ModuleInternal::RunModule(...)` so
  // callers can capture the failure cause on a false return.
  bool RunModule(const std::string moduleName,
                 std::string* outErrorMessage = nullptr);

  void RunScript(const std::string script);

  static void Initialize();

  static Runtime* GetCurrentRuntime() { return currentRuntime_; }

  static Runtime* GetRuntime(v8::Isolate* isolate);

  static bool IsWorker() {
    if (currentRuntime_ == nullptr) {
      return false;
    }

    return currentRuntime_->IsRuntimeWorker();
  }

  static std::shared_ptr<v8::Platform> GetPlatform() { return platform_; }

  static id GetAppConfigValue(std::string key);

  // Convenience accessor for whether to show the JS error display UI.
  // Reads the boolean `showErrorDisplay` from the nativescript.config (aka,
  // bundled package.json). Defaults to false when not present.
  static bool showErrorDisplay();

  static bool IsAlive(const v8::Isolate* isolate);

  // Milliseconds since this runtime's time origin, on the monotonic clock.
  // Not inline on purpose: an inline definition would have to reach the
  // platform through GetPlatform(), which copies a shared_ptr on every call,
  // while the out-of-line definition reads platform_ directly.
  double PerformanceNowMillis();

  // Wall-clock milliseconds since the Unix epoch at the moment the time origin
  // was captured, on the same base as Date.now(); this is
  // performance.timeOrigin.
  inline double TimeOriginMillis() const { return timeOriginRealtimeMs_; }

  // The monotonic clock reading (seconds, V8 platform units) of the time
  // origin, for mapping platform-supplied timestamps onto the performance
  // timeline.
  inline double TimeOriginMonotonicSeconds() const {
    return timeOriginMonotonic_;
  }

 private:
  static thread_local Runtime* currentRuntime_;
  static std::shared_ptr<v8::Platform> platform_;
  static std::vector<v8::Isolate*> isolates_;
  static SpinMutex isolatesMutex_;
  static bool v8Initialized_;
  static std::atomic<int> nextIsolateId;

  void DefineGlobalObject(v8::Local<v8::Context> context, bool isWorker);
  void DefineCollectFunction(v8::Local<v8::Context> context);
  void DefineNativeScriptVersion(v8::Isolate* isolate,
                                 v8::Local<v8::ObjectTemplate> globalTemplate);
  void DefineNativeScriptRuntime(v8::Isolate* isolate,
                                 v8::Local<v8::ObjectTemplate> globalTemplate);
  void DefineTimeMethod(v8::Isolate* isolate,
                        v8::Local<v8::ObjectTemplate> globalTemplate);
  void DefineDrainMicrotaskMethod(v8::Isolate* isolate,
                                  v8::Local<v8::ObjectTemplate> globalTemplate);
  void DefineDateTimeConfigurationChangeNotificationMethod(
      v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);

  static void DrainRejectionsObserver(CFRunLoopObserverRef observer,
                                      CFRunLoopActivity activity, void* info);
  v8::Isolate* isolate_;
  std::unique_ptr<ModuleInternal> moduleInternal_;
  int workerId_;
  CFRunLoopRef runtimeLoop_;
  // Drains unhandled promise rejections once per runloop turn
  // (kCFRunLoopBeforeWaiting). Torn down before isolate disposal in ~Runtime.
  CFRunLoopObserverRef rejectionObserver_ = nullptr;
  double timeOriginMonotonic_;
  double timeOriginRealtimeMs_;
  // TODO: refactor this. This is only needed because, during program
  // termination (UIApplicationMain not called) the Cache::Workers is released
  // (static initialization order fiasco
  // https://en.cppreference.com/w/cpp/language/siof) so it released the
  // Cache::Workers shared_ptr and then releases the Runtime unique_ptr
  // eventually we just need to refactor so that Runtime::Initialize is
  // responsible for its initalization and lifecycle
  std::shared_ptr<ConcurrentMap<int, std::shared_ptr<Caches::WorkerState>>>
      workerCache_;
};

}  // namespace tns

#endif /* Runtime_h */
