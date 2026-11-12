#ifndef ObjectManager_h
#define ObjectManager_h

#include "Common.h"

namespace tns {

class ObjectManager;

// Parameter of the kFinalizer weak callback armed on target_.
//
// Ownership: created by ObjectManager::Register and deleted by exactly two
// sites -- ObjectManager::FinalizerCallback's disposed branch and
// DisposeAllRegistered. Retiring a registration from anywhere else (the
// __releaseNativeCounterpart builtin is the only one) must Reset target_
// first: resetting frees the V8 node, which clears its pending-finalizer bit
// and guarantees no further callback, so the state is unreachable afterwards
// and safe to unlink and delete. Dropping the weakness without resetting
// leaves the node rooted forever with parameter() pointing at the freed state.
struct ObjectWeakCallbackState {
  ObjectWeakCallbackState(std::shared_ptr<v8::Persistent<v8::Value>> target)
      : target_(target) {}

  std::shared_ptr<v8::Persistent<v8::Value>> target_;

  // Links in the per-isolate registry (Caches::ObjectManagedValues) that
  // teardown walks. Intrusive so that a wrapper unlinks itself in O(1) when it
  // is disposed, rather than leaving an entry for a later sweep to find.
  // head_ points at the owning cache's head slot so unlinking -- which happens
  // in a GC finalizer -- needs no cache lookup.
  ObjectWeakCallbackState** head_ = nullptr;
  ObjectWeakCallbackState* prev_ = nullptr;
  ObjectWeakCallbackState* next_ = nullptr;

  // Set while one of the two owning sites is disposing this handle's value.
  // Disposal releases the native counterpart, whose -dealloc can re-enter JS
  // and reach __releaseNativeCounterpart for this very handle; retiring it
  // there would free the state under the frame that owns it. Retirement
  // observes the flag and leaves the handle to that frame.
  bool disposing_ = false;
};

class ObjectManager {
 public:
  // Per-isolate wrapper lifetime counters. Kept in every build: plain integers
  // bumped only on cold paths (finalizers, released-object reports), exposed
  // through ns:runtime's getWrapperLifetimeStats().
  struct LifetimeStats {
    // An ObjC wrapper's finalizer refused disposal because native code still
    // retains its object (IsGcProtected), keeping the wrapper alive.
    uint64_t resurrections = 0;
    // An ObjC wrapper's finalizer released its native object.
    uint64_t collected = 0;
    // __releaseNativeCounterpart released a native object.
    uint64_t releasedExplicitly = 0;
    // JS handed a released wrapper to native code or used it as a receiver.
    uint64_t releasedAccesses = 0;
    // A finalized ObjC wrapper carried JS properties while something other
    // than the wrapper still retained its object, and whether that object was
    // still alive a runloop turn later (see WrapperLifetimeWarningsEnabled).
    uint64_t stateLostCandidates = 0;
    uint64_t stateLostConfirmed = 0;
  };
  static LifetimeStats* GetLifetimeStats(v8::Isolate* isolate);

  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate);
  static std::shared_ptr<v8::Persistent<v8::Value>> Register(
      v8::Local<v8::Context> context, const v8::Local<v8::Value> obj);
  static void FinalizerCallback(
      const v8::WeakCallbackInfo<ObjectWeakCallbackState>& data);
  static bool DisposeValue(v8::Isolate* isolate, v8::Local<v8::Value> value,
                           bool isFinalDisposal = false);
  // Disposes every handle from Register() that is still alive. Replaces the
  // old Isolate::VisitHandlesWithClassIds walk, which V8 removed.
  static void DisposeAllRegistered(v8::Isolate* isolate);

 private:
  static void ReleaseNativeCounterpartCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static long GetRetainCount(id obj);
  static bool IsInstanceOf(id obj, Class clazz);
};

}  // namespace tns

#endif /* ObjectManager_h */
