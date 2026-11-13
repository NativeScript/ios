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
  if ([mode isKindOfClass:[NSString class]]) {
    if ([mode isEqualToString:@"rooted"]) {
      detail::wrapperLifetimeMode = WrapperLifetimeMode::kRooted;
    } else if (![mode isEqualToString:@"resurrecting"]) {
      Log("NativeScript: unknown wrapperLifetime mode \"%s\"; using \"resurrecting\".",
          [mode UTF8String]);
    }
  }
  id scope = ((NSDictionary*)config)[@"scope"];
  if ([scope isKindOfClass:[NSString class]]) {
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
  // The first -retainCount implementation that is not JS-implemented, per
  // class: the scan runs in a GC prologue, where JS may not run.
  std::unordered_map<Class, IMP> retainCountImps;
};

// Retains the runtime holds on an object across every isolate: one per
// Instances entry. A wrapper is natively owned when the object's retain count
// exceeds this. Readers in the GC prologue use the cached atomic without the
// lock; entries are only erased when their count reaches zero. Unadopted
// entries (skipGCRegistration) are not counted, so their retain reads as a
// native owner: such an object stays rooted in other isolates (a leak, never an
// early release).
std::mutex runtimeRetainsMutex_;
std::unordered_map<void*, std::unique_ptr<std::atomic<int>>> runtimeRetains_;

std::atomic<int>* AcquireRuntimeRetain(id obj) {
  std::lock_guard<std::mutex> lock(runtimeRetainsMutex_);
  std::unique_ptr<std::atomic<int>>& slot = runtimeRetains_[(__bridge void*)obj];
  if (slot == nullptr) {
    slot = std::make_unique<std::atomic<int>>(0);
  }
  slot->fetch_add(1, std::memory_order_relaxed);
  return slot.get();
}

void DropRuntimeRetain(id obj, std::atomic<int>* counter) {
  if (counter == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(runtimeRetainsMutex_);
  if (counter->fetch_sub(1, std::memory_order_relaxed) == 1) {
    auto it = runtimeRetains_.find((__bridge void*)obj);
    if (it != runtimeRetains_.end() && it->second.get() == counter) {
      runtimeRetains_.erase(it);
    }
  }
}

bool IsTaggedPointer(id obj) {
  // Through void*: clang rejects bit tests on ObjC object pointers.
  uintptr_t bits = reinterpret_cast<uintptr_t>(static_cast<const void*>(obj));
#if defined(__arm64__)
  return (bits >> 63) != 0;
#else
  return (bits & 1) != 0;
#endif
}

bool IsBlock(id obj) {
  static Class blockClass = objc_getClass("NSBlock");
  return blockClass != nil && [obj isKindOfClass:blockClass];
}

bool IsRootable(id obj) {
  if (IsTaggedPointer(obj) || IsBlock(obj)) {
    return false;
  }
  return GetWrapperLifetimeScope() == WrapperLifetimeScope::kAll ||
         class_conformsToProtocol(object_getClass(obj), @protocol(TNSDerivedClass));
}

NSUInteger NativeRetainCount(RootedState* state, id obj) {
  Class cls = object_getClass(obj);
  IMP& imp = state->retainCountImps[cls];
  if (imp == nullptr) {
    imp = ClassBuilder::FindNotOverridenMethod(cls, @selector(retainCount));
  }
  return reinterpret_cast<NSUInteger (*)(id, SEL)>(imp)(obj, @selector(retainCount));
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
  if (loop != nullptr &&
      loop->PostInternal([isolate]() { WrapperLifetime::DrainReleases(isolate); })) {
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
void PrologueCallback(Isolate* isolate, GCType, GCCallbackFlags) {
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
    NSUInteger count = NativeRetainCount(rooted, target);
    int runtimeRetains =
        state->runtimeRetains_ != nullptr ? state->runtimeRetains_->load(std::memory_order_relaxed)
                                          : 1;
    bool owned = count >= (NSUIntegerMax >> 1) || count > static_cast<NSUInteger>(runtimeRetains);
    if (owned && !state->lifetimeStrong_) {
      PromoteState(state);
      if (stats != nullptr) {
        stats->promotions++;
      }
    } else if (!owned && state->lifetimeStrong_) {
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
  std::atomic<int>* counter = state->runtimeRetains_;
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
  while (!rooted->releases.empty()) {
    std::vector<ObjectWeakCallbackState*> batch;
    batch.swap(rooted->releases);
    WrapperLifetime::pendingReleaseIsolates_.fetch_sub(1, std::memory_order_relaxed);
    for (ObjectWeakCallbackState* state : batch) {
      ReleaseQueued(cache, state);
    }
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
  isolate->AddGCPrologueCallback(
      PrologueCallback,
      static_cast<GCType>(kGCTypeMarkSweepCompact | kGCTypeIncrementalMarking));
}

void WrapperLifetime::Adopt(Isolate* isolate, ObjCDataWrapper* wrapper,
                            const std::shared_ptr<Persistent<Value>>& handle, id target) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kRooted || target == nil) {
    return;
  }
  RootedState* rooted = Caches::StateFor<RootedState>(isolate);
  if (rooted == nullptr || !handle->IsWeak()) {
    // Unregistered handles (skipGCRegistration) keep their own lifetime.
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
  if (runtime != nullptr && CFRunLoopGetCurrent() != runtime->RuntimeLoop()) {
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

void WrapperLifetime::Retire(Isolate* isolate, ObjectWeakCallbackState* state, bool released) {
  if (state->lifetimeTarget_ == nil) {
    return;
  }
  id target = state->lifetimeTarget_;
  std::atomic<int>* counter = state->runtimeRetains_;
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
