#ifndef ObjectManager_h
#define ObjectManager_h

#include <atomic>
#include <cstdint>
#include "Common.h"

namespace tns {

struct CanaryRecord;

class ObjectManager;
class ObjCDataWrapper;

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

  // Set when WrapperLifetime adopted this registration (an ObjC object wrapper
  // under a phantom-callback mode). The JS object is unreadable after its
  // phantom callback, so the wrapper and object are cached here.
  ObjCDataWrapper* lifetimeWrapper_ = nullptr;
  id lifetimeTarget_ = nullptr;
  // WrapperLifetime's cross-isolate retain counter for lifetimeTarget_.
  std::atomic<uint64_t>* runtimeRetains_ = nullptr;
  // May be rooted; scanned when a major collection starts.
  bool lifetimeTracked_ = false;
  // The handle is currently strong.
  bool lifetimeStrong_ = false;
  // Canary mode: the wrapper forwards JS properties to a state object that
  // outlives it (WrapperLifetimeCanary), found through this record once the
  // object has state.
  bool lifetimeCanary_ = false;
  std::shared_ptr<CanaryRecord> canaryRecord_;
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
    // Rooted mode (WrapperLifetime): wrappers made strong because native code
    // owns their object, made weak because it no longer does, and dead
    // wrappers whose object was queued for release.
    uint64_t promotions = 0;
    uint64_t demotions = 0;
    uint64_t queuedReleases = 0;
    // Canary mode: state objects created for native objects, and state
    // objects let go of because their native object was deallocated.
    uint64_t canaryStates = 0;
    uint64_t canaryNativeDeaths = 0;
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
  // Takes over the handle `state` belongs to (the wrapper's Instances entry):
  // from now on it is strong while something besides that entry retains the
  // object and weak otherwise, re-checked whenever ReconcileOwnership runs and
  // when a major collection starts.
  static void ManageOwnership(v8::Isolate* isolate, ObjCDataWrapper* wrapper,
                              ObjectWeakCallbackState* state);
  // Requires the isolate locked and entered, on any thread.
  static void ReconcileOwnership(v8::Isolate* isolate,
                                 ObjCDataWrapper* wrapper);
  // Removes a registration from the teardown list.
  static void Unlink(ObjectWeakCallbackState* state);

  // A collection can run on any thread that holds the isolate's Locker, but
  // the native releases it causes are handed to the runtime's thread. A new
  // Instances entry for an object whose release is still waiting takes that
  // release over as its own retain instead of retaining again; returns whether
  // it did. Once the entry holds its reference, call ProtectIfNativelyRetained.
  static bool TakeDeferredRelease(v8::Isolate* isolate, id obj);
  // A class that tracks native retains (ClassBuilder::TracksNativeRetains)
  // protects its wrapper when native code first retains the object past the
  // runtime's own retain. A native retain made while a release waited found no
  // wrapper to protect; this catches up. A surplus reference the caller drops
  // afterwards goes through -release, which unprotects again.
  static void ProtectIfNativelyRetained(v8::Isolate* isolate, id obj, ObjCDataWrapper* wrapper);

 private:
  static void ReleaseNativeCounterpartCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static long GetRetainCount(id obj);
  static bool IsInstanceOf(id obj, Class clazz);
};

}  // namespace tns

#endif /* ObjectManager_h */
