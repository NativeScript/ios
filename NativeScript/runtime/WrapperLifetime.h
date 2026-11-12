#ifndef WrapperLifetime_h
#define WrapperLifetime_h

#include <atomic>

#include "Common.h"
#include "DataWrapper.h"
#include "Helpers.h"
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
  // Phantom callbacks, no resurrection: the wrapper is a canary that dies with
  // its JS references. JS properties set on it live on a separate state object
  // that stays alive until the native object is deallocated, and a canary
  // built for the same object later shares it (WrapperLifetimeCanary).
  kCanary,
};

enum class WrapperLifetimeScope {
  // Only JS-extended instances (TNSDerivedClass) are rooted, or canaries;
  // other wrappers are weak and die with their JS references, except receivers
  // of JS methods native code calls, which keep the default mode's ownership
  // tracking (ArgConverter::WrapNativeCallbackSelf).
  kExtended,
  kAll,
};

namespace detail {
// Written once, by the first WrapperLifetime::Init, before any wrapper exists.
inline WrapperLifetimeMode wrapperLifetimeMode =
    WrapperLifetimeMode::kResurrecting;
inline WrapperLifetimeScope wrapperLifetimeScope =
    WrapperLifetimeScope::kExtended;
}  // namespace detail

inline WrapperLifetimeMode GetWrapperLifetimeMode() {
  return detail::wrapperLifetimeMode;
}
inline WrapperLifetimeScope GetWrapperLifetimeScope() {
  return detail::wrapperLifetimeScope;
}
const char* WrapperLifetimeModeName(WrapperLifetimeMode mode);
const char* WrapperLifetimeScopeName(WrapperLifetimeScope scope);

class WrapperLifetime {
 public:
  static void Init(v8::Isolate* isolate);

  // A newly wrapped ObjC object: `handle` is its Instances entry, registered by
  // ObjectManager::Register and holding the entry's +1 on `target`.
  static void Adopt(v8::Isolate* isolate, ObjCDataWrapper* wrapper,
                    const std::shared_ptr<v8::Persistent<v8::Value>>& handle,
                    id target);

  // The object crossed the JS/native boundary: native code returned it to JS,
  // or received it as a receiver, argument, return value of a JS-implemented
  // member, collection element or reference target. A weak, rootable wrapper
  // becomes strong until the next major collection re-evaluates it.
  static inline void Escape(BaseDataWrapper* wrapper) {
    if (GetWrapperLifetimeMode() == WrapperLifetimeMode::kRooted &&
        wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
      EscapeSlow(static_cast<ObjCDataWrapper*>(wrapper));
    }
  }

  // Escape for the wrapper `value` holds, looked up only in the rooted mode.
  static inline void EscapeValue(v8::Isolate* isolate,
                                 const v8::Local<v8::Value>& value) {
    if (GetWrapperLifetimeMode() == WrapperLifetimeMode::kRooted) {
      Escape(tns::GetValue(isolate, value));
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

  // Gives an adopted wrapper that is not rooted back to ObjectManager: returns
  // its registration with the handle strong, for
  // ObjectManager::ManageOwnership. Null when the mode keeps the wrapper.
  static ObjectWeakCallbackState* Relinquish(ObjCDataWrapper* wrapper);

  // __releaseNativeCounterpart retired this adopted wrapper's registration.
  static void Forget(v8::Isolate* isolate, ObjectWeakCallbackState* state);

  // Teardown, before the registration walk: releases what the queue still
  // holds. The isolate is already invalidated and its event loop stopped, so
  // this releases inline on the tearing-down thread.
  static void DrainForTeardown(v8::Isolate* isolate);

  // Teardown: called before DisposeValue releases an adopted wrapper's object,
  // since the runtime's retain must be dropped before the native one.
  static void DropRetainBeforeDisposal(ObjectWeakCallbackState* state);

  // Teardown (ObjectManager::DisposeAllRegistered) disposes an adopted wrapper;
  // `released` tells whether DisposeValue already released the object.
  static void Retire(v8::Isolate* isolate, ObjectWeakCallbackState* state,
                     bool released);

 private:
  static void EscapeSlow(ObjCDataWrapper* wrapper);

 public:
  // Isolates whose release queue is not empty.
  static std::atomic<int> pendingReleaseIsolates_;
};

}  // namespace tns

#endif /* WrapperLifetime_h */
