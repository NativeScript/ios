#ifndef MethodCallProfiler_h
#define MethodCallProfiler_h

#include <atomic>
#include <string>

#include "Common.h"
#include "Metadata.h"

namespace tns {

// Counts native method and property-getter calls that take the generic
// (libffi) path. Exposed to JS as the lazy global `__native_call_profiler`:
//   start() / stop() / reset()
//   report(topN = 50)     human-readable top calls
//   aotConfig(topN = 50)  JSON candidates for AOT stubs
//   aotStats()            {served, declined} AOT stub calls, counted only
//                         between start() and stop()
class MethodCallProfiler {
 public:
  static inline bool IsEnabled() {
    return enabled_.load(std::memory_order_relaxed);
  }
  static void Enable();
  static void Disable();
  static void Reset();
  static void RecordCall(const std::string& className, const MethodMeta* meta,
                         bool isStatic = false);
  // LazyGlobals exports accessor: `{ profiler: <the JS API object> }`.
  static v8::MaybeLocal<v8::Object> GetExports(v8::Local<v8::Context> context);

 private:
  static std::atomic<bool> enabled_;

  static void JSStart(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSStop(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSReset(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSReport(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSAOTConfig(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSAOTStats(const v8::FunctionCallbackInfo<v8::Value>& info);
};

}  // namespace tns

#endif /* MethodCallProfiler_h */
