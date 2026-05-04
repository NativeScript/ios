#ifndef MethodCallProfiler_h
#define MethodCallProfiler_h

#include <atomic>

#include "Common.h"
#include "Metadata.h"

namespace tns {

class MethodCallProfiler {
 public:
  static inline bool IsEnabled() {
    return enabled_.load(std::memory_order_relaxed);
  }
  static void Enable();
  static void Disable();
  static void Reset();
  static void RecordCall(const std::string& className, const MethodMeta* meta);
  static void RegisterJSAPI(v8::Isolate* isolate,
                            v8::Local<v8::ObjectTemplate> globalTemplate);

 private:
  static std::atomic<bool> enabled_;

  static void JSStart(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSStop(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSReset(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSReport(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void JSAOTConfig(const v8::FunctionCallbackInfo<v8::Value>& info);
};

}  // namespace tns

#endif /* MethodCallProfiler_h */
