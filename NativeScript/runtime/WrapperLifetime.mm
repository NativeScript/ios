#include "WrapperLifetime.h"
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "Caches.h"
#include "ClassBuilder.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Runtime.h"
#import "TNSDerivedClass.h"

using namespace v8;

namespace tns {

std::atomic<int> WrapperLifetime::pendingReleaseIsolates_{0};

namespace {

std::once_flag configOnce_;

void ReadConfig() {
  id config = Runtime::GetAppConfigValue("wrapperLifetime");
  if (![config isKindOfClass:[NSDictionary class]]) {
    return;
  }
  id mode = ((NSDictionary*)config)[@"mode"];
  if (mode != nil && ![mode isKindOfClass:[NSString class]]) {
    Log("NativeScript: wrapperLifetime mode must be a string; using \"resurrecting\".");
  } else if (mode != nil) {
    if ([mode isEqualToString:@"rooted"]) {
      detail::wrapperLifetimeMode = WrapperLifetimeMode::kRooted;
    } else if (![mode isEqualToString:@"resurrecting"]) {
      Log("NativeScript: unknown wrapperLifetime mode \"%s\"; using \"resurrecting\".",
          [mode UTF8String]);
    }
  }
  id scope = ((NSDictionary*)config)[@"scope"];
  if (scope != nil && ![scope isKindOfClass:[NSString class]]) {
    Log("NativeScript: wrapperLifetime scope must be a string; using \"extended\".");
  } else if (scope != nil) {
    if ([scope isEqualToString:@"all"]) {
      detail::wrapperLifetimeScope = WrapperLifetimeScope::kAll;
    } else if (![scope isEqualToString:@"extended"]) {
      Log("NativeScript: unknown wrapperLifetime scope \"%s\"; using \"extended\".",
          [scope UTF8String]);
    }
  }
}

// Per-isolate state of the rooted mode.
struct RootedState {
  ~RootedState() {
    if (!releases.empty()) {
      WrapperLifetime::pendingReleaseIsolates_.fetch_sub(1, std::memory_order_relaxed);
    }
  }

  // Adopted wrappers that may be rooted; scanned when a major collection starts.
  std::unordered_set<ObjectWeakCallbackState*> tracked;
  // Wrappers whose JS object died; their objects are released by DrainReleases.
  std::vector<ObjectWeakCallbackState*> releases;
  bool draining = false;
  bool drainPosted = false;
  // ObjectManager::NativeRetainCountImp per class:
  // the scan runs in a GC prologue, where JS may not run.
  std::unordered_map<Class, IMP> retainCountImps;
};

// Retains the runtime holds on an object across every isolate: one per
// Instances entry. A wrapper is natively owned when the object's retain count
// exceeds this. Readers in the GC prologue use the cached atomic without the
// lock; entries are only erased when their count reaches zero. Entries Adopt
// skipped (handles ObjectManager did not register) are not counted, so their
// retain reads as a native owner: such an object stays rooted in other
// isolates (a leak, never an early release).
//
// The low 32 bits count retains, the high 32 bits count changes. Every caller
// takes its native retain before acquiring and drops before releasing, and the
// scan reads the counter on both sides of -retainCount: a change in between
// keeps the wrapper strong, so no adopt or release on another thread can make
// a natively owned object read as unowned.
constexpr uint64_t kRetainAcquired = (uint64_t{1} << 32) + 1;
constexpr uint64_t kRetainDropped = (uint64_t{1} << 32) - 1;

uint32_t RetainsIn(uint64_t value) { return static_cast<uint32_t>(value); }

std::mutex runtimeRetainsMutex_;
std::unordered_map<void*, std::unique_ptr<std::atomic<uint64_t>>> runtimeRetains_;

std::atomic<uint64_t>* AcquireRuntimeRetain(id obj) {
  std::lock_guard<std::mutex> lock(runtimeRetainsMutex_);
  std::unique_ptr<std::atomic<uint64_t>>& slot = runtimeRetains_[(__bridge void*)obj];
  if (slot == nullptr) {
    slot = std::make_unique<std::atomic<uint64_t>>(0);
  }
  slot->fetch_add(kRetainAcquired);
  return slot.get();
}

void DropRuntimeRetain(id obj, std::atomic<uint64_t>* counter) {
  if (counter == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(runtimeRetainsMutex_);
  if (RetainsIn(counter->fetch_add(kRetainDropped)) == 1) {
    auto it = runtimeRetains_.find((__bridge void*)obj);
    if (it != runtimeRetains_.end() && it->second.get() == counter) {
      runtimeRetains_.erase(it);
    }
  }
}

bool IsBlock(id obj) {
  static Class blockClass = objc_getClass("NSBlock");
  return blockClass != nil && [obj isKindOfClass:blockClass];
}

bool IsRootable(id obj) {
  if (IsTaggedPointer(obj) || IsBlock(obj)) {
    return false;
  }
  if (GetWrapperLifetimeScope() == WrapperLifetimeScope::kAll) {
    return true;
  }
  // Key-value observing swaps in an NSKVONotifying_ subclass that does not
  // itself conform, so the protocol is looked up through the superclasses.
  for (Class cls = object_getClass(obj); cls != nil; cls = class_getSuperclass(cls)) {
    if (class_conformsToProtocol(cls, @protocol(TNSDerivedClass))) {
      return true;
    }
  }
  return false;
}

// Classes without a native -retainCount read as 0.
NSUInteger NativeRetainCount(RootedState* state, id obj) {
  Class cls = object_getClass(obj);
  auto found = state->retainCountImps.find(cls);
  if (found == state->retainCountImps.end()) {
    found = state->retainCountImps.emplace(cls, ObjectManager::NativeRetainCountImp(cls)).first;
  }
  if (found->second == nullptr) {
    return 0;
  }
  return reinterpret_cast<NSUInteger (*)(id, SEL)>(found->second)(obj, @selector(retainCount));
}

ObjectManager::LifetimeStats* Stats(Isolate* isolate) {
  return ObjectManager::GetLifetimeStats(isolate);
}

void MakeWeak(ObjectWeakCallbackState* state);

void PromoteState(ObjectWeakCallbackState* state) {
  if (state->lifetimeStrong_ || state->target_->IsEmpty()) {
    return;
  }
  state->target_->ClearWeak<ObjectWeakCallbackState>();
  state->lifetimeStrong_ = true;
}

void ScheduleDrain(Isolate* isolate, RootedState* state) {
  if (state->drainPosted) {
    return;
  }
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  if (loop != nullptr && loop->PostInternal([isolate]() {
        // Cleared before anything can return early, or no drain is posted again.
        if (RootedState* posted = Caches::ExistingStateFor<RootedState>(isolate)) {
          posted->drainPosted = false;
        }
        WrapperLifetime::DrainReleases(isolate);
      })) {
    state->drainPosted = true;
  }
}

// The wrapper's JS object died. Plain C++ only: the native object is released
// later, from DrainReleases.
void PhantomCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& info) {
  ObjectWeakCallbackState* state = info.GetParameter();
  state->target_->Reset();
  state->lifetimeStrong_ = false;
  if (state->disposing_) {
    // The teardown walk owns this state and finishes it (WrapperLifetime::Retire).
    return;
  }
  Isolate* isolate = info.GetIsolate();
  RootedState* rooted = Caches::StateFor<RootedState>(isolate);
  if (rooted == nullptr) {
    // Teardown has begun; the registration stays linked for its walk.
    return;
  }
  ObjectManager::Unlink(state);
  rooted->tracked.erase(state);
  if (rooted->releases.empty()) {
    WrapperLifetime::pendingReleaseIsolates_.fetch_add(1, std::memory_order_relaxed);
  }
  rooted->releases.push_back(state);
  if (ObjectManager::LifetimeStats* stats = Stats(isolate)) {
    stats->queuedReleases++;
  }
  ScheduleDrain(isolate, rooted);
}

void MakeWeak(ObjectWeakCallbackState* state) {
  state->target_->SetWeak(state, PhantomCallback, WeakCallbackType::kParameter);
  state->lifetimeStrong_ = false;
}

// Major-collection scan: root what native code owns, let go of the rest.
// Demotes only at the atomic pause, where the main thread stops until weak
// processing and young survivors are tenured. At incremental-marking start a
// demoted wrapper could still be young, and a scavenge before the pause would
// collect it without another scan, even after native code retained its object
// without crossing into JS (say by loading a __weak reference). A wrapper
// native code let go of thus survives one more incremental cycle.
void PrologueCallback(Isolate* isolate, GCType type, GCCallbackFlags) {
  const bool demote = type == kGCTypeMarkSweepCompact;
  RootedState* rooted = Caches::StateFor<RootedState>(isolate);
  if (rooted == nullptr) {
    return;
  }
  ObjectManager::LifetimeStats* stats = Stats(isolate);
  for (ObjectWeakCallbackState* state : rooted->tracked) {
    if (state->target_->IsEmpty()) {
      continue;
    }
    id target = state->lifetimeTarget_;
    uint64_t before = state->runtimeRetains_ != nullptr ? state->runtimeRetains_->load() : 0;
    NSUInteger count = NativeRetainCount(rooted, target);
    uint64_t after = state->runtimeRetains_ != nullptr ? state->runtimeRetains_->load() : 0;
    NSUInteger runtimeRetains = state->runtimeRetains_ != nullptr ? RetainsIn(before) : 1;
    bool owned = before != after || count >= (NSUIntegerMax >> 1) || count > runtimeRetains;
    if (owned && !state->lifetimeStrong_) {
      PromoteState(state);
      if (stats != nullptr) {
        stats->promotions++;
      }
    } else if (demote && !owned && state->lifetimeStrong_) {
      MakeWeak(state);
      if (stats != nullptr) {
        stats->demotions++;
      }
    }
  }
}

void ReleaseQueued(const std::shared_ptr<Caches>& cache, ObjectWeakCallbackState* state) {
  id target = state->lifetimeTarget_;
  // A wrapper built for the object after this one died owns the entry now.
  auto it = cache->Instances.find(target);
  if (it != cache->Instances.end() && it->second == state->target_) {
    cache->Instances.erase(it);
  }
  delete state->lifetimeWrapper_;
  std::atomic<uint64_t>* counter = state->runtimeRetains_;
  delete state;
  DropRuntimeRetain(target, counter);
  [target release];
}

void ReleaseAll(Isolate* isolate, RootedState* rooted) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  rooted->draining = true;
  // A -dealloc can throw an NSException through here.
  struct Reset {
    RootedState* rooted;
    ~Reset() { rooted->draining = false; }
  } reset{rooted};
  // One state leaves the queue at a time, so a release that throws leaves the
  // rest queued for the next drain or teardown.
  while (!rooted->releases.empty()) {
    ObjectWeakCallbackState* state = rooted->releases.back();
    rooted->releases.pop_back();
    if (rooted->releases.empty()) {
      WrapperLifetime::pendingReleaseIsolates_.fetch_sub(1, std::memory_order_relaxed);
    }
    ReleaseQueued(cache, state);
  }
}

}  // namespace

const char* WrapperLifetimeModeName(WrapperLifetimeMode mode) {
  return mode == WrapperLifetimeMode::kRooted ? "rooted" : "resurrecting";
}

const char* WrapperLifetimeScopeName(WrapperLifetimeScope scope) {
  return scope == WrapperLifetimeScope::kAll ? "all" : "extended";
}

void WrapperLifetime::Init(Isolate* isolate) {
  std::call_once(configOnce_, ReadConfig);
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kRooted) {
    return;
  }
  Caches::StateFor<RootedState>(isolate);
  isolate->AddGCPrologueCallback(
      PrologueCallback, static_cast<GCType>(kGCTypeMarkSweepCompact | kGCTypeIncrementalMarking));
}

void WrapperLifetime::Adopt(Isolate* isolate, ObjCDataWrapper* wrapper,
                            const std::shared_ptr<Persistent<Value>>& handle, id target) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kRooted || target == nil) {
    return;
  }
  RootedState* rooted = Caches::StateFor<RootedState>(isolate);
  if (rooted == nullptr || !handle->IsWeak()) {
    // Handles ObjectManager did not register keep their own lifetime.
    return;
  }
  ObjectWeakCallbackState* state = handle->ClearWeak<ObjectWeakCallbackState>();
  if (state == nullptr) {
    return;
  }
  state->lifetimeWrapper_ = wrapper;
  state->lifetimeTarget_ = target;
  state->runtimeRetains_ = AcquireRuntimeRetain(target);
  wrapper->SetLifetimeState(state);
  if (IsRootable(target)) {
    // Born strong: a wrapper just handed to JS or native is in use; the next
    // major collection decides whether native code keeps it.
    state->lifetimeTracked_ = true;
    state->lifetimeStrong_ = true;
    rooted->tracked.insert(state);
  } else {
    MakeWeak(state);
  }
}

void WrapperLifetime::EscapeSlow(ObjCDataWrapper* wrapper) {
  ObjectWeakCallbackState* state = wrapper->LifetimeState();
  if (state == nullptr || !state->lifetimeTracked_ || state->lifetimeStrong_) {
    return;
  }
  PromoteState(state);
}

void WrapperLifetime::DrainReleases(Isolate* isolate) {
  RootedState* rooted = Caches::StateFor<RootedState>(isolate);
  if (rooted == nullptr || rooted->releases.empty()) {
    return;
  }
  // JS can run on another thread under the isolate's Locker; objects such as
  // views and CA transactions must be released on the runtime's own thread.
  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime != nullptr && !runtime->IsOnRuntimeThread()) {
    ScheduleDrain(isolate, rooted);
    return;
  }
  rooted->drainPosted = false;
  if (rooted->draining) {
    // A release ran JS that reached a drain point; the outer loop continues.
    return;
  }
  ReleaseAll(isolate, rooted);
}

void WrapperLifetime::DrainForTeardown(Isolate* isolate) {
  RootedState* rooted = Caches::ExistingStateFor<RootedState>(isolate);
  if (rooted == nullptr) {
    return;
  }
  rooted->tracked.clear();
  if (!rooted->draining) {
    ReleaseAll(isolate, rooted);
  }
}

void WrapperLifetime::Forget(Isolate* isolate, ObjectWeakCallbackState* state) {
  if (state == nullptr || state->lifetimeTarget_ == nil) {
    return;
  }
  if (RootedState* rooted = Caches::StateFor<RootedState>(isolate)) {
    rooted->tracked.erase(state);
  }
  DropRuntimeRetain(state->lifetimeTarget_, state->runtimeRetains_);
  state->runtimeRetains_ = nullptr;
  if (state->lifetimeWrapper_ != nullptr) {
    state->lifetimeWrapper_->SetLifetimeState(nullptr);
  }
}

void WrapperLifetime::DropRetainBeforeDisposal(ObjectWeakCallbackState* state) {
  DropRuntimeRetain(state->lifetimeTarget_, state->runtimeRetains_);
  state->runtimeRetains_ = nullptr;
}

void WrapperLifetime::Retire(Isolate* isolate, ObjectWeakCallbackState* state, bool released) {
  if (state->lifetimeTarget_ == nil) {
    return;
  }
  id target = state->lifetimeTarget_;
  std::atomic<uint64_t>* counter = state->runtimeRetains_;
  state->runtimeRetains_ = nullptr;
  if (!released) {
    // The JS object died during the teardown walk, before DisposeValue could
    // release it.
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache != nullptr) {
      auto it = cache->Instances.find(target);
      if (it != cache->Instances.end() && it->second == state->target_) {
        cache->Instances.erase(it);
      }
    }
    delete state->lifetimeWrapper_;
    DropRuntimeRetain(target, counter);
    [target release];
    return;
  }
  DropRuntimeRetain(target, counter);
}

ObjCDataWrapper::~ObjCDataWrapper() {
  if (this->lifetimeState_ != nullptr) {
    this->lifetimeState_->lifetimeWrapper_ = nullptr;
  }
}

}  // namespace tns
