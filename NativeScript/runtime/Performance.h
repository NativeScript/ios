#ifndef Performance_h
#define Performance_h

#include "Common.h"

namespace tns {

class Performance {
 public:
  // Installs the WHATWG Performance API by evaluating internal/performance.js
  // with a bag of natives {now, timeOrigin}. Must run after Events::Init
  // (Performance extends EventTarget) and after ErrorEvents::Init (observer
  // failures are reported through it). Evaluated once per isolate during
  // Runtime::Init, for main and worker isolates alike; each isolate carries its
  // own time origin.
  static void Init(v8::Local<v8::Context> context);

  // Milliseconds elapsed on this isolate's performance timeline: monotonic and
  // zero at the time origin. Native producers of JS-visible timestamps (a
  // future requestAnimationFrame) must read the clock through here instead of
  // sampling one of their own, so every such timestamp shares
  // performance.timeOrigin as its base. Returns 0.0 for an isolate with no
  // runtime.
  static double NowMillis(v8::Isolate* isolate);

  // Wall-clock milliseconds since the Unix epoch at the isolate's time origin,
  // on the same base as Date.now(); this is performance.timeOrigin. Returns
  // 0.0 for an isolate with no runtime.
  static double TimeOriginMillis(v8::Isolate* isolate);

 private:
  static void NowCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
};

}  // namespace tns

#endif /* Performance_h */
