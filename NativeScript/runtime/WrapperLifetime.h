#ifndef WrapperLifetime_h
#define WrapperLifetime_h

#include <atomic>
#include "Common.h"
#include "DataWrapper.h"
#include "ObjectManager.h"

namespace tns {

class ObjCDataWrapper;

// How ObjC object wrappers live. Process-wide, read once from the app config
// "wrapperLifetime": { "mode": ..., "scope": ... } and fixed for the process.
enum class WrapperLifetimeMode {
  // kFinalizer callbacks; a natively retained JS-extended instance refuses
  // disposal and is resurrected (ObjectManager::DisposeValue).
  kResurrecting,
  // Phantom callbacks, no resurrection: a wrapper is a strong root while
  // something other than the runtime retains its object, weak otherwise.
  kRooted,
};

enum class WrapperLifetimeScope {
  // Only JS-extended instances (TNSDerivedClass) are rooted; other wrappers are
  // weak and die with their JS references.
  kExtended,
  kAll,
};

namespace detail {
// Written once, by the first WrapperLifetime::Init, before any wrapper exists.
inline WrapperLifetimeMode wrapperLifetimeMode = WrapperLifetimeMode::kResurrecting;
inline WrapperLifetimeScope wrapperLifetimeScope = WrapperLifetimeScope::kExtended;
}  // namespace detail

inline WrapperLifetimeMode GetWrapperLifetimeMode() { return detail::wrapperLifetimeMode; }
inline WrapperLifetimeScope GetWrapperLifetimeScope() { return detail::wrapperLifetimeScope; }
const char* WrapperLifetimeModeName(WrapperLifetimeMode mode);
const char* WrapperLifetimeScopeName(WrapperLifetimeScope scope);

class WrapperLifetime {
 public:
  static void Init(v8::Isolate* isolate);

  // A newly wrapped ObjC object: `handle` is its Instances entry, registered by
  // ObjectManager::Register and holding the entry's +1 on `target`.
  static void Adopt(v8::Isolate* isolate, ObjCDataWrapper* wrapper,
                    const std::shared_ptr<v8::Persistent<v8::Value>>& handle, id target);

  // The object crossed the JS/native boundary: native code returned it to JS,
  // or received it as a receiver or argument. A weak, rootable wrapper becomes
  // strong until the next major collection re-evaluates it.
  static inline void Escape(BaseDataWrapper* wrapper) {
    if (GetWrapperLifetimeMode() == WrapperLifetimeMode::kRooted && wrapper != nullptr &&
        wrapper->Type() == WrapperType::ObjCObject) {
      EscapeSlow(static_cast<ObjCDataWrapper*>(wrapper));
    }
  }

  // Releases the native objects of wrappers that died. Runs only where JS may
  // run: release can reach a JS-implemented -dealloc.
  static void DrainReleases(v8::Isolate* isolate);

  // JS->native call entry: a long synchronous stretch of JS must not hold dead
  // objects until it yields. The gate is process-wide; while another isolate
  // has queued releases this costs one state lookup per call.
  static inline void DrainAtCallEntry(v8::Isolate* isolate) {
    if (pendingReleaseIsolates_.load(std::memory_order_relaxed) > 0) {
      DrainReleases(isolate);
    }
  }

  // __releaseNativeCounterpart retired this adopted wrapper's registration.
  static void Forget(v8::Isolate* isolate, ObjectWeakCallbackState* state);

  // Teardown, before the registration walk: releases what the queue still holds.
  // The isolate is already invalidated and its event loop stopped, so this
  // releases inline on the tearing-down thread.
  static void DrainForTeardown(v8::Isolate* isolate);

  // Teardown (ObjectManager::DisposeAllRegistered) disposes an adopted wrapper;
  // `released` tells whether DisposeValue already released the object.
  static void Retire(v8::Isolate* isolate, ObjectWeakCallbackState* state, bool released);

 private:
  static void EscapeSlow(ObjCDataWrapper* wrapper);

 public:
  // Isolates whose release queue is not empty.
  static std::atomic<int> pendingReleaseIsolates_;
};

}  // namespace tns

#endif /* WrapperLifetime_h */
