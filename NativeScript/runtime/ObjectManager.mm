#include "ObjectManager.h"
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sstream>
#include <unordered_map>
#include <vector>
#include "Caches.h"
#include "ClassBuilder.h"
#include "Constants.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "FFICall.h"
#include "Helpers.h"
#include "Runtime.h"
#include "WrapperLifetime.h"
#include <objc/message.h>
#include <objc/runtime.h>
#include <string>
#include <unordered_set>
#include <vector>

// Exported by libobjc; not declared in a public header for MRC code.
extern "C" id objc_initWeak(id* location, id value);
extern "C" id objc_loadWeakRetained(id* location);
extern "C" void objc_destroyWeak(id* location);

using namespace v8;
using namespace std;

namespace tns {

static Class NSTimerClass = objc_getClass("NSTimer");

namespace {

// Wrappers whose handle ObjectManager::ManageOwnership took over, keyed by the
// finalizer state their handle carries.
struct OwnershipTracking {
  std::unordered_map<ObjectWeakCallbackState*, ObjCDataWrapper*> managed;
};

void ForgetOwnership(Isolate* isolate, ObjectWeakCallbackState* state) {
  if (OwnershipTracking* tracking = Caches::StateFor<OwnershipTracking>(isolate)) {
    tracking->managed.erase(state);
  }
}

void ApplyOwnership(ObjectWeakCallbackState* state, bool nativelyOwned) {
  bool weak = state->target_->IsWeak();
  if (nativelyOwned && weak) {
    state->target_->ClearWeak<ObjectWeakCallbackState>();
  } else if (!nativelyOwned && !weak) {
    state->target_->SetWeak(state, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);
  }
}

// For callers that may not enter JS (the GC prologue, the finalizer drain), so
// a JS-implemented -retainCount is skipped. Timers read as 0: the retain count
// of an uninitialized NSTimer (NSTimer.alloc()) can hang.
NSUInteger RetainCountWithoutJS(id obj) {
  for (Class c = object_getClass(obj); c != nil; c = class_getSuperclass(c)) {
    if (c == NSTimerClass) {
      return 0;
    }
  }
  IMP imp = ClassBuilder::FindNotOverridenMethod(object_getClass(obj), @selector(retainCount));
  return ((NSUInteger (*)(id, SEL))imp)(obj, @selector(retainCount));
}

bool NativelyOwnedWithoutJS(id obj) { return RetainCountWithoutJS(obj) > 1; }

void ReconcileOwnershipBeforeGC(Isolate* isolate, GCType, GCCallbackFlags) {
  OwnershipTracking* tracking = Caches::StateFor<OwnershipTracking>(isolate);
  if (tracking == nullptr) {
    return;
  }
  for (auto& [state, wrapper] : tracking->managed) {
    if (state->disposing_ || state->target_ == nullptr || state->target_->IsEmpty()) {
      continue;
    }
    ApplyOwnership(state, NativelyOwnedWithoutJS(wrapper->Data()));
  }
}

// A finalized wrapper that carried JS properties while something other than
// the wrapper still retained its object. Confirmed on a later internal task,
// once the releases a collection on another thread queued for the runtime
// thread have run, so a co-collected owner does not produce a warning.

struct StateLostCandidate {
  id* weakSlot;
  std::string description;
  std::string className;
  std::string properties;
};

struct WrapperLifetimeState {
  ObjectManager::LifetimeStats stats;
  std::vector<StateLostCandidate> candidates;
  bool confirmPosted = false;
  // Times the pending confirmation stepped behind queued releases.
  int confirmDeferrals = 0;
  std::unordered_set<std::string> warnedClasses;

  ~WrapperLifetimeState() {
    for (StateLostCandidate& candidate : candidates) {
      objc_destroyWeak(candidate.weakSlot);
      delete candidate.weakSlot;
    }
  }
};


bool ReleasesPendingOnRuntimeThread(Isolate* isolate);
bool PostStateLostConfirmation(Isolate* isolate);

void ConfirmStateLost(Isolate* isolate) {
  auto* state = Caches::StateFor<WrapperLifetimeState>(isolate);
  if (state == nullptr) {
    return;
  }
  // The internal lane is FIFO, so posting again runs after the queued drain.
  // Bounded, in case collections elsewhere keep queueing releases.
  if (ReleasesPendingOnRuntimeThread(isolate) && state->confirmDeferrals < 4 &&
      PostStateLostConfirmation(isolate)) {
    state->confirmDeferrals++;
    return;
  }
  state->confirmPosted = false;
  state->confirmDeferrals = 0;
  std::vector<StateLostCandidate> candidates;
  candidates.swap(state->candidates);
  for (StateLostCandidate& candidate : candidates) {
    id obj = objc_loadWeakRetained(candidate.weakSlot);
    if (obj != nil) {
      [obj release];
      state->stats.stateLostConfirmed++;
      if (state->warnedClasses.insert(candidate.className).second) {
        Log("NativeScript: JS properties (%s) set on %s were lost when its JavaScript wrapper was "
            "garbage collected, but the native object is still alive. If native code hands it "
            "back, it gets a new wrapper without them. Keep a JS reference to the object while "
            "its JS state is needed. Reported once per class; disable with \"wrapperLifetime\": "
            "{ \"warnings\": false }.",
            candidate.properties.c_str(), candidate.description.c_str());
      }
    }
    objc_destroyWeak(candidate.weakSlot);
    delete candidate.weakSlot;
  }
}

// Called from the finalizer drain just before the wrapper releases `target`.
void NoteStateLostCandidate(Isolate* isolate, Local<Object> obj, id target) {
  if (IsTaggedPointer(target)) {
    return;
  }
  NSUInteger count = RetainCountWithoutJS(target);
  if (count <= 1 || count >= (NSUIntegerMax >> 1)) {
    return;
  }
  SEL allowsWeak = sel_registerName("allowsWeakReference");
  if ([target respondsToSelector:allowsWeak] &&
      !reinterpret_cast<BOOL (*)(id, SEL)>(objc_msgSend)(target, allowsWeak)) {
    return;
  }
  // The V8 calls below can run a nested collection whose JS releases target,
  // so it is not touched after them.
  const char* className = object_getClassName(target);
  char description[256];
  snprintf(description, sizeof(description), "<%s: %p>", className, (void*)target);
  id* slot = new id(nil);
  objc_initWeak(slot, target);
  auto discardSlot = [slot]() {
    objc_destroyWeak(slot);
    delete slot;
  };

  HandleScope handleScope(isolate);
  TryCatch tryCatch(isolate);
  Local<Context> context = tns::GetCreationContextOrCurrent(isolate, obj);
  Local<v8::Array> names;
  if (context.IsEmpty() ||
      !obj->GetOwnPropertyNames(context, PropertyFilter::SKIP_SYMBOLS).ToLocal(&names) ||
      names->Length() == 0) {
    discardSlot();
    return;
  }

  auto* state = Caches::StateFor<WrapperLifetimeState>(isolate);
  if (state == nullptr) {
    discardSlot();
    return;
  }
  state->stats.stateLostCandidates++;

  std::string properties;
  uint32_t shown = std::min<uint32_t>(names->Length(), 5);
  for (uint32_t i = 0; i < shown; i++) {
    Local<Value> name;
    if (!names->Get(context, i).ToLocal(&name)) {
      continue;
    }
    if (!properties.empty()) {
      properties += ", ";
    }
    properties += tns::ToString(isolate, name);
  }
  if (names->Length() > shown) {
    properties += ", ...";
  }

  state->candidates.push_back({slot, description, className, properties});

  if (!state->confirmPosted) {
    state->confirmPosted = PostStateLostConfirmation(isolate);
  }
}

}  // namespace

namespace {

void LinkRegistered(v8::Isolate* isolate, ObjectWeakCallbackState* state) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr) {
    return;
  }
  state->head_ = &cache->ObjectManagedValues;
  state->next_ = *state->head_;
  if (state->next_ != nullptr) {
    state->next_->prev_ = state;
  }
  *state->head_ = state;
}

void UnlinkRegistered(ObjectWeakCallbackState* state);

}  // namespace

void ObjectManager::Unlink(ObjectWeakCallbackState* state) { UnlinkRegistered(state); }

namespace {

void UnlinkRegistered(ObjectWeakCallbackState* state) {
  if (state->head_ == nullptr) {
    return;
  }
  if (state->prev_ != nullptr) {
    state->prev_->next_ = state->next_;
  } else if (*state->head_ == state) {
    *state->head_ = state->next_;
  }
  if (state->next_ != nullptr) {
    state->next_->prev_ = state->prev_;
  }
  state->head_ = nullptr;
  state->prev_ = nullptr;
  state->next_ = nullptr;
}

// The native release of an object that first reached JS on its runtime's
// thread belongs on that thread. JS, and with it a collection and its
// finalizers, can run on any thread that holds the isolate's Locker (a JS
// callback dispatched to a background queue), and a -dealloc that tears down a
// view, a CA transaction or a block capturing one crashes off the main thread.
// Objects first wrapped on another thread are still released where the
// collection runs.
//
// Every access holds the isolate's Locker: finalizers,
// __releaseNativeCounterpart and wrapper creation on any thread, and on the
// runtime's thread the drain task and teardown. So no other synchronization.
struct DeferredReleases {
  // Object -> releases it is owed. An object stays alive while it is owed one,
  // so its address cannot be reused by another object meanwhile.
  std::unordered_map<void*, unsigned> objects;
  std::vector<const void*> blocks;
  bool drainPosted = false;
};

// A release can run JS (a -dealloc implemented in JS) that wraps an object
// whose own release still waits, or that reaches this drain again. So one
// release leaves the queue at a time, the rest stay there for
// TakeDeferredRelease, and nothing is held across a release.
void DrainDeferredReleases(DeferredReleases* pending) {
  pending->drainPosted = false;
  while (!pending->objects.empty()) {
    auto it = pending->objects.begin();
    id obj = (__bridge id)it->first;
    if (--it->second == 0) {
      pending->objects.erase(it);
    }
    [obj release];
  }
  while (!pending->blocks.empty()) {
    const void* block = pending->blocks.back();
    pending->blocks.pop_back();
    Block_release(block);
  }
}

// The queue to hand a release to, or null when the caller releases inline.
// Created by Init, so a collection on another thread never creates it; read
// without the validity check because a collection can still run on another
// thread between InvalidateIsolate and teardown, which drains it.
DeferredReleases* DeferralQueue(Isolate* isolate, bool bornOnRuntimeThread) {
  if (!bornOnRuntimeThread || OnRuntimeThreadOf(isolate)) {
    return nullptr;
  }
  return Caches::ExistingStateFor<DeferredReleases>(isolate);
}

// One event loop task per batch. If the loop no longer takes work, teardown is
// under way and drains the queue itself.
void PostDrain(Isolate* isolate, DeferredReleases* pending) {
  if (pending->drainPosted) {
    return;
  }
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  pending->drainPosted = loop != nullptr && loop->PostInternal([isolate]() {
    if (DeferredReleases* queued = Caches::ExistingStateFor<DeferredReleases>(isolate)) {
      DrainDeferredReleases(queued);
    }
  });
}

bool ReleasesPendingOnRuntimeThread(Isolate* isolate) {
  DeferredReleases* pending = Caches::ExistingStateFor<DeferredReleases>(isolate);
  return pending != nullptr && pending->drainPosted;
}

bool PostStateLostConfirmation(Isolate* isolate) {
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  return loop != nullptr && loop->PostInternal([isolate]() { ConfirmStateLost(isolate); });
}

void ReleaseOnRuntimeThread(Isolate* isolate, id obj, bool bornOnRuntimeThread) {
  DeferredReleases* pending = DeferralQueue(isolate, bornOnRuntimeThread);
  if (pending == nullptr) {
    [obj release];
    return;
  }
  pending->objects[(__bridge void*)obj]++;
  PostDrain(isolate, pending);
}

void BlockReleaseOnRuntimeThread(Isolate* isolate, const void* block, bool bornOnRuntimeThread) {
  DeferredReleases* pending = DeferralQueue(isolate, bornOnRuntimeThread);
  if (pending == nullptr) {
    Block_release(block);
    return;
  }
  pending->blocks.push_back(block);
  PostDrain(isolate, pending);
}

}  // namespace

void ObjectManager::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  globalTemplate->Set(tns::ToV8String(isolate, "__releaseNativeCounterpart"),
                      FunctionTemplate::New(isolate, ReleaseNativeCounterpartCallback));
  isolate->AddGCPrologueCallback(
      ReconcileOwnershipBeforeGC,
      static_cast<GCType>(kGCTypeMarkSweepCompact | kGCTypeIncrementalMarking));
  Caches::StateFor<DeferredReleases>(isolate);
  // Created here so a collection on another thread never allocates them, and
  // the warnings flag is read from the app config before any finalizer asks.
  tns::InitReleasedMarkers(isolate);
  Caches::StateFor<WrapperLifetimeState>(isolate);
  tns::WrapperLifetimeWarningsEnabled();
  WrapperLifetime::Init(isolate);
}

std::shared_ptr<Persistent<Value>> ObjectManager::Register(Local<Context> context,
                                                           const Local<Value> obj) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Persistent<Value>> objectHandle =
      std::make_shared<Persistent<Value>>(isolate, obj);
  objectHandle->SetWrapperClassId(Constants::ClassTypes::ObjectManagedValue);
  ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
  objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);

  LinkRegistered(isolate, state);

  return objectHandle;
}

namespace {

// The DataWrapper-tagged handles used to be reached through
// Isolate::VisitHandlesWithClassIds; they all live in Caches, so walk those
// directly instead.
template <typename Map>
void DisposeHandleMap(v8::Isolate* isolate, Map& map) {
  for (auto& entry : map) {
    if (entry.second == nullptr || entry.second->IsEmpty()) {
      continue;
    }
    ObjectManager::DisposeValue(isolate, entry.second->Get(isolate), true);
  }
}

void DisposeHandle(v8::Isolate* isolate,
                   const std::unique_ptr<v8::Persistent<v8::Function>>& handle) {
  if (handle == nullptr || handle->IsEmpty()) {
    return;
  }
  ObjectManager::DisposeValue(isolate, handle->Get(isolate), true);
}

}  // namespace

void ObjectManager::DisposeAllRegistered(Isolate* isolate) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr) {
    return;
  }

  // Runs from ~Runtime, which holds a Locker but has not entered the isolate;
  // creating handles below requires it to be entered.
  Isolate::Scope isolateScope(isolate);
  HandleScope scope(isolate);

  // The event loop has stopped taking work, so nothing else would drain.
  DeferredReleases* deferred = Caches::ExistingStateFor<DeferredReleases>(isolate);
  if (deferred != nullptr) {
    DrainDeferredReleases(deferred);
  }

  // Detach the whole list first so disposal can't walk into freed entries, and
  // claim every state up front: disposing one entry can re-enter JS from
  // -dealloc and reach __releaseNativeCounterpart for any other entry this
  // walk still owns.
  // Wrappers that died before teardown are already off the list, waiting in
  // the release queue.
  WrapperLifetime::DrainForTeardown(isolate);

  ObjectWeakCallbackState* state = cache->ObjectManagedValues;
  cache->ObjectManagedValues = nullptr;
  for (ObjectWeakCallbackState* claimed = state; claimed != nullptr; claimed = claimed->next_) {
    claimed->disposing_ = true;
  }

  while (state != nullptr) {
    ObjectWeakCallbackState* next = state->next_;

    std::shared_ptr<Persistent<Value>> handle = state->target_;
    bool released = false;
    WrapperLifetime::DropRetainBeforeDisposal(state);
    if (handle != nullptr && !handle->IsEmpty()) {
      ObjectManager::DisposeValue(isolate, handle->Get(isolate), true);
      released = true;
      if (handle->IsWeak()) {
        handle->ClearWeak<ObjectWeakCallbackState>();
      }
      handle->Reset();
    }
    WrapperLifetime::Retire(isolate, state, released);
    delete state;

    state = next;
  }

  // A walk that runs off the runtime's thread queues its own releases.
  if (deferred != nullptr) {
    DrainDeferredReleases(deferred);
  }

  DisposeHandleMap(isolate, cache->CtorFuncs);
  DisposeHandleMap(isolate, cache->ProtocolCtorFuncs);
  DisposeHandleMap(isolate, cache->CFunctions);
  DisposeHandleMap(isolate, cache->PrimitiveInteropTypes);
  DisposeHandle(isolate, cache->InteropReferenceCtorFunc);
  DisposeHandle(isolate, cache->PointerCtorFunc);
  DisposeHandle(isolate, cache->FunctionReferenceCtorFunc);
}

void ObjectManager::ManageOwnership(Isolate* isolate, ObjCDataWrapper* wrapper,
                                    ObjectWeakCallbackState* state) {
  OwnershipTracking* tracking = Caches::StateFor<OwnershipTracking>(isolate);
  if (tracking == nullptr || state == nullptr) {
    return;
  }
  wrapper->SetOwnershipState(state);
  tracking->managed[state] = wrapper;
  ObjectManager::ReconcileOwnership(isolate, wrapper);
}

void ObjectManager::ReconcileOwnership(Isolate* isolate, ObjCDataWrapper* wrapper) {
  ObjectWeakCallbackState* state = wrapper->OwnershipState();
  if (state == nullptr || state->disposing_ || state->target_ == nullptr ||
      state->target_->IsEmpty()) {
    return;
  }
  // The handle's strength carries the ownership; a GcProtect from the retain
  // swizzle would keep a weak handle from ever being disposed.
  wrapper->GcUnprotect();
  ApplyOwnership(state, NativelyOwnedWithoutJS(wrapper->Data()));
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
  ObjectWeakCallbackState* state = data.GetParameter();
  Isolate* isolate = data.GetIsolate();

  if (state->disposing_) {
    // Another frame owns this state's teardown — the DisposeAllRegistered
    // walk, whose pre-claimed entries a nested collection can still condemn.
    // Re-arm to satisfy the finalizer contract on this node and leave the
    // clear/reset/delete to the owner.
    state->target_->ClearWeak<void>();
    state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    return;
  }

  state->disposing_ = true;
  Local<Value> value = state->target_->Get(isolate);
  bool disposed = ObjectManager::DisposeValue(isolate, value);
  state->disposing_ = false;

  // Disposal releases the native counterpart, and a -dealloc reached that way
  // can reset this very handle (the collection adapters reset the persistent
  // they were built from). An empty handle means the node is already freed, so
  // there is nothing left to reset or re-arm -- ClearWeak/SetWeak would write
  // through a dead slot -- and the registration must be retired even when
  // disposal was refused.
  if (disposed || state->target_->IsEmpty()) {
    state->target_->Reset();
    UnlinkRegistered(state);
    ForgetOwnership(isolate, state);
    delete state;
    return;
  }

  state->target_->ClearWeak<void>();
  state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);

  // Refused because native code took the object back: keep the handle strong
  // rather than resurrecting it at every collection.
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    if (objcWrapper->OwnershipState() == state) {
      ApplyOwnership(state, NativelyOwnedWithoutJS(objcWrapper->Data()));
    }
  }
}

bool ObjectManager::TakeDeferredRelease(Isolate* isolate, id obj) {
  DeferredReleases* pending = Caches::ExistingStateFor<DeferredReleases>(isolate);
  if (pending == nullptr || pending->objects.empty()) {
    return false;
  }
  auto it = pending->objects.find((__bridge void*)obj);
  if (it == pending->objects.end()) {
    return false;
  }
  if (--it->second == 0) {
    pending->objects.erase(it);
  }
  return true;
}

void ObjectManager::ProtectIfNativelyRetained(Isolate* isolate, id obj, ObjCDataWrapper* wrapper) {
  // Only a wrapper the class's -release unprotects again may be protected.
  if (ClassBuilder::TracksNativeRetains(isolate, object_getClass(obj)) && [obj retainCount] > 1) {
    wrapper->GcProtect();
  }
}

bool ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value, bool isFinalDisposal) {
  if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
    return true;
  }

  Local<Object> obj = value.As<Object>();
  if (obj->InternalFieldCount() > 1) {
    Local<Value> superValue = obj->GetInternalField(1).As<v8::Value>();
    if (!superValue.IsEmpty() && superValue->IsString()) {
      // A "super" alias owns no wrapper; the one GetValue finds through it is
      // its receiver's.
      return true;
    }
  }

  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  // NSLog(@"dispose %p", wrapper);
  if (wrapper == nullptr) {
    if (tns::GetReleasedReason(obj) == tns::ReleasedReason::kNone) {
      tns::SetValue(isolate, obj, nullptr);
    }
    return true;
  }

  const WrapperType type = wrapper->Type();
  if (wrapper->IsGcProtected() && !isFinalDisposal) {
    if (type == WrapperType::ObjCObject) {
      if (LifetimeStats* stats = GetLifetimeStats(isolate)) {
        stats->resurrections++;
      }
    }
    return false;
  }

  // A handle ReconcileOwnership keeps is weak while the Instances entry looked
  // like the only owner; a retain from another thread can still be on its way
  // to making it strong again.
  if (!isFinalDisposal && wrapper->Type() == WrapperType::ObjCObject) {
    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    if (objcWrapper->OwnershipState() != nullptr && NativelyOwnedWithoutJS(objcWrapper->Data())) {
      if (LifetimeStats* stats = GetLifetimeStats(isolate)) {
        stats->resurrections++;
      }
      return false;
    }
  }

  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  switch (type) {
    case WrapperType::Struct:
      // Lives in the struct object's ArrayBuffer storage, which the GC frees.
      return true;
    case WrapperType::ObjCObject: {
      ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(wrapper);
      id target = objCObjectWrapper->Data();
      if (target != nil) {
        // Instances is keyed on the raw address, so an entry rebuilt for a
        // later object living there must survive this wrapper going away —
        // only the entry that still points back at this object is ours.
        auto it = cache->Instances.find(target);
        if (it != cache->Instances.end()) {
          Local<Value> cached = it->second->Get(isolate);
          if (cached.IsEmpty() || cached == value) {
            cache->Instances.erase(it);
          }
        }
        if (!isFinalDisposal) {
          if (LifetimeStats* stats = GetLifetimeStats(isolate)) {
            stats->collected++;
          }
          if (tns::WrapperLifetimeWarningsEnabled()) {
            NoteStateLostCandidate(isolate, obj, target);
            // It allocates, so a nested collection may have run finalizers
            // whose JS released this object explicitly.
            if (tns::GetValue(isolate, obj) != wrapper) {
              return true;
            }
          }
        }
        if (objCObjectWrapper->IsAdapterClaim()) {
          // The adapter's -dealloc retires this wrapper; it must run first.
          [target release];
        } else {
          ReleaseOnRuntimeThread(isolate, target, objCObjectWrapper->BornOnRuntimeThread());
        }
      }
      break;
    }
    case WrapperType::Block: {
      BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
      if (!blockWrapper->OwnsBlock()) {
        // A block created from a JS callback is owned by the native code it
        // was handed to (e.g. NSNotificationCenter), and it owns this wrapper
        // (see Interop::JSBlock): its dispose helper frees both once the last
        // native reference goes, possibly after this isolate is gone.
        return true;
      }
      // Balance the Block_copy taken when a native block was wrapped for JS
      // (see Interop::GetResult). Block_release is the correct counterpart to
      // Block_copy and runs the block's dispose helper once we drop the last
      // reference. (Using CFRelease here over-released stack blocks that were
      // never promoted to the heap, crashing in objc_release during GC.)
      BlockReleaseOnRuntimeThread(isolate, blockWrapper->Block(),
                                  blockWrapper->BornOnRuntimeThread());
      break;
    }
    case WrapperType::Reference: {
      ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
      if (referenceWrapper->Data() != nullptr) {
        referenceWrapper->SetData(nullptr);
        referenceWrapper->SetEncoding(nullptr);
      }

      break;
    }
    case WrapperType::Pointer: {
      PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
      if (pointerWrapper->Data() != nullptr) {
        cache->PointerInstances.erase(pointerWrapper->Data());

        if (pointerWrapper->IsAdopted()) {
          std::free(pointerWrapper->Data());
          pointerWrapper->SetData(nullptr);
        }
      }
      break;
    }
    case WrapperType::FunctionReference: {
      FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
      std::shared_ptr<Persistent<Value>> func = funcWrapper->Function();
      if (func != nullptr) {
        func->Reset();
      }
      break;
    }
    case WrapperType::AnonymousFunction: {
      break;
    }
    case WrapperType::ExtVector: {
      ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
      FFICall::DisposeFFIType(extVectorWrapper->FFIType(), extVectorWrapper->TypeEncoding());
      void* data = extVectorWrapper->Data();
      if (data) {
        std::free(data);
      }
      break;
    }
    case WrapperType::Worker: {
      WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
      // Final disposal lets go of the wrapper for good, and only deletes it
      // when the worker thread is done with it; otherwise that thread deletes
      // it when it ends.
      //
      // A weak callback deletes the wrapper only when the worker thread is
      // done with it, and changes nothing otherwise. A running worker's Worker
      // object is rooted (WorkerWrapper::RootWorkerObject), so a weak callback
      // should not reach a live worker at all. The refusal stays as the floor
      // under that: re-arming keeps the wrapper alive for another cycle, which
      // is safe, whereas freeing it while the thread still posts through it is
      // not. Reaching it is not free either -- a re-armed handle that is also a
      // weak-collection key can corrupt the collector's ephemeron bookkeeping
      // -- so it is a fallback, not a mechanism to rely on.
      bool lastHolder = isFinalDisposal ? worker->ReleaseFromParent() : worker->HeldByParentOnly();
      if (!lastHolder) {
        return false;
      }
      break;
    }

    default:
      break;
  }

  // A branch above can run arbitrary code -- [target release] reaching an ObjC
  // -dealloc is the reachable one -- and that code may detach this wrapper or
  // attach a different one. The object's internal field is the wrapper's owner,
  // so only a wrapper still sitting in it is ours to free.
  if (tns::GetValue(isolate, obj) == wrapper) {
    delete wrapper;
    if (type == WrapperType::ObjCObject) {
      tns::MarkReleased(isolate, obj,
                        isFinalDisposal ? tns::ReleasedReason::kTeardown
                                        : tns::ReleasedReason::kCollected);
    } else {
      tns::DeleteValue(isolate, obj);
    }
  }
  return true;
}

void ObjectManager::ReleaseNativeCounterpartCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  if (info.Length() != 1) {
    std::ostringstream errorStream;
    errorStream << "Actual arguments count: \"" << info.Length() << "\". Expected: \"1\".";
    std::string errorMessage = errorStream.str();
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
    isolate->ThrowException(error);
    return;
  }

  // The lookup, the Instances key and the final SetValue must all address the
  // same object, so a Proxy is resolved once here, and a "super" alias to the
  // receiver whose wrapper it reads.
  Local<Value> value = tns::UnwrapProxy(info[0]);
  if (!value.IsEmpty() && value->IsObject()) {
    Local<Object> receiver = tns::SuperAliasReceiver(value.As<Object>());
    if (!receiver.IsEmpty()) {
      value = receiver;
    }
  }
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);

  if (wrapper == nullptr) {
    std::string arg0 = tns::ToString(isolate, info[0]);
    std::ostringstream errorStream;
    errorStream << arg0 << " is an object which is not a native wrapper.";
    std::string errorMessage = errorStream.str();
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
    isolate->ThrowException(error);
    return;
  }

  if (wrapper->Type() != WrapperType::ObjCObject) {
    return;
  }

  ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
  if (objcWrapper->IsBorrowed()) {
    if (tns::GetValue(isolate, value) == wrapper) {
      tns::MarkReleased(isolate, value.As<Object>(), tns::ReleasedReason::kExplicit);
      delete wrapper;
    }
    return;
  }

  id data = objcWrapper->Data();
  if (data != nil) {
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->Instances.find(data);
    if (ObjectWeakCallbackState* managed = objcWrapper->OwnershipState()) {
      // The handle ReconcileOwnership manages is this wrapper's own, whatever
      // Instances maps the object to now.
      if (managed->disposing_) {
        return;
      }
      if (it != cache->Instances.end() && it->second == managed->target_) {
        cache->Instances.erase(it);
      }
      managed->target_->Reset();
      UnlinkRegistered(managed);
      ForgetOwnership(isolate, managed);
      delete managed;
      objcWrapper->SetOwnershipState(nullptr);
    } else if (ObjectWeakCallbackState* adopted = objcWrapper->LifetimeState()) {
      // An adopted wrapper (WrapperLifetime) owns its registration whether or not
      // the Instances entry still names it, and its handle may be strong.
      if (adopted->disposing_) {
        // The teardown walk owns this state and releases the object.
        return;
      }
      if (it != cache->Instances.end() && it->second == adopted->target_) {
        cache->Instances.erase(it);
      }
      adopted->target_->Reset();
      WrapperLifetime::Forget(isolate, adopted);
      objcWrapper->SetLifetimeState(nullptr);
      UnlinkRegistered(adopted);
      delete adopted;
    } else if (it != cache->Instances.end()) {
      std::shared_ptr<Persistent<Value>> handle = it->second;
      bool wasWeak = handle->IsWeak();
      ObjectWeakCallbackState* state =
          wasWeak ? handle->ClearWeak<ObjectWeakCallbackState>() : nullptr;
      if (state != nullptr && state->disposing_) {
        // Reached from a -dealloc running inside this handle's own finalizer
        // or the teardown walk: that frame already released the native
        // counterpart and owns the state, so restore the weakness and let it
        // finish.
        handle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
        return;
      }
      cache->Instances.erase(it);
      if (state != nullptr) {
        // Reset before deleting the state: it frees the node, which clears the
        // pending-finalizer bit and guarantees no callback can reach the freed
        // parameter.
        handle->Reset();
        UnlinkRegistered(state);
        ForgetOwnership(isolate, state);
        delete state;
      }
    }

    // Release the runtime's strong reference (taken when the object was first
    // wrapped or adopted from an alloc/new/copy return). For instances solely
    // owned by JS this deallocates them, on the runtime's thread (at once when
    // called there); for shared natives (e.g. an NSNotificationCenter observer
    // token) the remaining owners keep it alive.
    // Calling [data dealloc] here, as this used to do, destroyed objects that
    // were still referenced elsewhere and caused use-after-free crashes.
    // Read before the release below: an adapter claim's -dealloc frees the
    // wrapper, so it must not be touched afterwards.
    bool adapterClaim = objcWrapper->IsAdapterClaim();

    if (adapterClaim) {
      [data release];
    } else {
      ReleaseOnRuntimeThread(isolate, data, objcWrapper->BornOnRuntimeThread());
    }

    // The release above can run a -dealloc that detaches this wrapper; the
    // internal field owns it, so free only what is still attached. An
    // adapter's claim is exempt: the adapter owns it exclusively and deletes
    // it from its own -dealloc even after isolate teardown, so retiring it
    // here would leave the adapter holding a stale pointer it later frees
    // again.
    if (!adapterClaim && tns::GetValue(isolate, value) == wrapper) {
      delete wrapper;
      tns::MarkReleased(isolate, value.As<Object>(), tns::ReleasedReason::kExplicit);
    }
    if (LifetimeStats* stats = GetLifetimeStats(isolate)) {
      stats->releasedExplicitly++;
    }
  }
}

bool ObjectManager::IsInstanceOf(id obj, Class clazz) { return [obj isKindOfClass:clazz]; }

ObjectManager::LifetimeStats* ObjectManager::GetLifetimeStats(Isolate* isolate) {
  auto* state = Caches::StateFor<WrapperLifetimeState>(isolate);
  return state != nullptr ? &state->stats : nullptr;
}

long ObjectManager::GetRetainCount(id obj) {
  if (!obj) {
    return 0;
  }

  if (ObjectManager::IsInstanceOf(obj, NSTimerClass)) {
    return 0;
  }

  return CFGetRetainCount(obj);
}

}  // namespace tns
