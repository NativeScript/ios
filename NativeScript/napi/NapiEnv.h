#ifndef NapiEnv_h
#define NapiEnv_h

// Pins NAPI_VERSION for every consumer of this header, so napi_env__ is seen
// identically wherever it is compiled. Must precede the napi includes below.
#ifndef NAPI_EXPERIMENTAL
#define NAPI_EXPERIMENTAL
#endif
#ifndef NODE_API_EXPERIMENTAL_NO_WARNING
#define NODE_API_EXPERIMENTAL_NO_WARNING
#endif

#include <CoreFoundation/CoreFoundation.h>

#include <memory>
#include <string>
#include <unordered_map>

#include "js_native_api_v8.h"

namespace tns {

class EventLoop;

// The napi_env behind every Node-API call, one per runtime isolate/context.
// Node's equivalent (node_napi_env__) lives in node_api.cc, which is not
// vendored; this is its replacement.
class NapiEnv : public napi_env__ {
 public:
  // Creates the env for `context` and hands ownership to the caller, which
  // must eventually pass it to Destroy while the isolate is alive and locked.
  static NapiEnv* Create(v8::Local<v8::Context> context);
  static void Destroy(NapiEnv* env);

  // Null when the isolate has no runtime, or before Runtime::Init reaches the
  // env, or after teardown.
  static NapiEnv* ForIsolate(v8::Isolate* isolate);

  bool can_call_into_js() const override { return !tearingDown_; }
  void CallFinalizer(napi_finalize cb, void* data, void* hint) override;
  void EnqueueFinalizer(v8impl::RefTracker* finalizer) override;
  void DeleteMe() override;

  v8::Local<v8::Private> PrivateKey(NapiPrivateKeySlot slot);

  // The runloop of the thread that owns this env — identity checks only
  // (is-this-the-env's-thread); work is posted through GetEventLoop().
  CFRunLoopRef RuntimeLoop() const { return runtimeLoop_; }

  // The runtime's event loop, or null once the runtime shut it down. Posted
  // internal-lane entries run on the env's thread under the loop's
  // Locker/scopes and end with a microtask checkpoint.
  std::shared_ptr<EventLoop> GetEventLoop() const { return eventLoop_.lock(); }

  // Exports of an addon already initialized in this env, or an empty handle.
  v8::MaybeLocal<v8::Object> CachedModuleExports(const std::string& name);
  void CacheModuleExports(const std::string& name,
                          v8::Local<v8::Object> exports);

 private:
  explicit NapiEnv(v8::Local<v8::Context> context);
  ~NapiEnv() override;

  void DrainFinalizers();

  CFRunLoopRef runtimeLoop_ = nullptr;
  std::weak_ptr<EventLoop> eventLoop_;
  bool tearingDown_ = false;
  v8::Eternal<v8::Private> privateKeys_[2];
  std::unordered_map<std::string, v8::Global<v8::Object>> moduleExports_;
};

// Runs the env's cleanup hooks, most recently added first, at the head of
// teardown. Defined in NodeApiEmbed.mm, next to the hook registry.
void NapiRunEnvCleanupHooks(NapiEnv* env);

}  // namespace tns

#endif /* NapiEnv_h */
