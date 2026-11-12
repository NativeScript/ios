#include "ObjectManager.h"
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sstream>
#include "Caches.h"
#include "Constants.h"
#include "DataWrapper.h"
#include "FFICall.h"
#include "Helpers.h"
#include "Runtime.h"
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

// A finalized wrapper that carried JS properties while something other than
// the wrapper still retained its object. Confirmed a runloop turn later, so a
// co-queued owner or a pending autorelease does not produce a warning.
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
  std::unordered_set<std::string> warnedClasses;

  ~WrapperLifetimeState() {
    for (StateLostCandidate& candidate : candidates) {
      objc_destroyWeak(candidate.weakSlot);
      delete candidate.weakSlot;
    }
  }
};

bool IsTaggedPointer(id obj) {
#if defined(__arm64__)
  return reinterpret_cast<intptr_t>(obj) < 0;
#else
  return (reinterpret_cast<uintptr_t>(obj) & 1) != 0;
#endif
}

void ConfirmStateLost(Isolate* isolate) {
  auto* state = Caches::StateFor<WrapperLifetimeState>(isolate);
  if (state == nullptr) {
    return;
  }
  state->confirmPosted = false;
  std::vector<StateLostCandidate> candidates;
  candidates.swap(state->candidates);
  for (StateLostCandidate& candidate : candidates) {
    id obj = objc_loadWeakRetained(candidate.weakSlot);
    if (obj != nil) {
      state->stats.stateLostConfirmed++;
      if (state->warnedClasses.insert(candidate.className).second) {
        Log("NativeScript: JS properties (%s) set on %s were lost when its JavaScript wrapper was "
            "garbage collected, but the native object is still alive. If native code hands it "
            "back, it gets a new wrapper without them. Keep a JS reference to the object while "
            "its JS state is needed. Reported once per class; disable with \"wrapperLifetime\": "
            "{ \"warnings\": false }.",
            candidate.properties.c_str(), candidate.description.c_str());
      }
      [obj release];
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
  NSUInteger count = [target retainCount];
  if (count <= 1 || count >= (NSUIntegerMax >> 1)) {
    return;
  }
  SEL allowsWeak = sel_registerName("allowsWeakReference");
  if ([target respondsToSelector:allowsWeak] &&
      !reinterpret_cast<BOOL (*)(id, SEL)>(objc_msgSend)(target, allowsWeak)) {
    return;
  }

  HandleScope handleScope(isolate);
  TryCatch tryCatch(isolate);
  Local<Context> context = tns::GetCreationContextOrCurrent(isolate, obj);
  Local<v8::Array> names;
  if (context.IsEmpty() ||
      !obj->GetOwnPropertyNames(context, PropertyFilter::SKIP_SYMBOLS).ToLocal(&names) ||
      names->Length() == 0) {
    return;
  }

  auto* state = Caches::StateFor<WrapperLifetimeState>(isolate);
  if (state == nullptr) {
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

  const char* className = object_getClassName(target);
  char description[256];
  snprintf(description, sizeof(description), "<%s: %p>", className, (void*)target);

  id* slot = new id(nil);
  objc_initWeak(slot, target);
  state->candidates.push_back({slot, description, className, properties});

  if (!state->confirmPosted) {
    Runtime* runtime = Runtime::GetRuntime(isolate);
    std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
    if (loop != nullptr && loop->PostInternal([isolate]() { ConfirmStateLost(isolate); })) {
      state->confirmPosted = true;
    }
  }
}

}  // namespace

void ObjectManager::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  globalTemplate->Set(tns::ToV8String(isolate, "__releaseNativeCounterpart"),
                      FunctionTemplate::New(isolate, ReleaseNativeCounterpartCallback));
}

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

}  // namespace

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

  // Detach the whole list first so disposal can't walk into freed entries, and
  // claim every state up front: disposing one entry can re-enter JS from
  // -dealloc and reach __releaseNativeCounterpart for any other entry this
  // walk still owns.
  ObjectWeakCallbackState* state = cache->ObjectManagedValues;
  cache->ObjectManagedValues = nullptr;
  for (ObjectWeakCallbackState* claimed = state; claimed != nullptr; claimed = claimed->next_) {
    claimed->disposing_ = true;
  }

  while (state != nullptr) {
    ObjectWeakCallbackState* next = state->next_;

    std::shared_ptr<Persistent<Value>> handle = state->target_;
    if (handle != nullptr && !handle->IsEmpty()) {
      ObjectManager::DisposeValue(isolate, handle->Get(isolate), true);
      if (handle->IsWeak()) {
        handle->ClearWeak<ObjectWeakCallbackState>();
      }
      handle->Reset();
    }
    delete state;

    state = next;
  }

  DisposeHandleMap(isolate, cache->CtorFuncs);
  DisposeHandleMap(isolate, cache->ProtocolCtorFuncs);
  DisposeHandleMap(isolate, cache->CFunctions);
  DisposeHandleMap(isolate, cache->PrimitiveInteropTypes);
  DisposeHandle(isolate, cache->InteropReferenceCtorFunc);
  DisposeHandle(isolate, cache->PointerCtorFunc);
  DisposeHandle(isolate, cache->FunctionReferenceCtorFunc);
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
    delete state;
    return;
  }

  state->target_->ClearWeak<void>();
  state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
}

bool ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value, bool isFinalDisposal) {
  if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
    return true;
  }

  Local<Object> obj = value.As<Object>();
  if (obj->InternalFieldCount() > 1 && !isFinalDisposal) {
    Local<Value> superValue = obj->GetInternalField(1).As<v8::Value>();
    if (!superValue.IsEmpty() && superValue->IsString()) {
      // Do not dispose the ObjCWrapper contained in a "super" instance
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
        [target release];
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
      Block_release(blockWrapper->Block());
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
  // same object, so a Proxy is resolved once here.
  Local<Value> value = tns::UnwrapProxy(info[0]);
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
  id data = objcWrapper->Data();
  if (data != nil) {
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->Instances.find(data);
    if (it != cache->Instances.end()) {
      std::shared_ptr<Persistent<Value>> handle = it->second;
      ObjectWeakCallbackState* state =
          handle->IsWeak() ? handle->ClearWeak<ObjectWeakCallbackState>() : nullptr;
      if (state != nullptr && state->disposing_) {
        // Reached from a -dealloc running inside this handle's own finalizer:
        // that frame already released the native counterpart and owns the
        // state, so restore the weakness and let it finish.
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
        delete state;
      }
    }

    // Release the runtime's strong reference (taken when the object was first
    // wrapped or adopted from an alloc/new/copy return). For instances solely
    // owned by JS this deallocates immediately; for shared natives (e.g. an
    // NSNotificationCenter observer token) the remaining owners keep it alive.
    // Calling [data dealloc] here, as this used to do, destroyed objects that
    // were still referenced elsewhere and caused use-after-free crashes.
    // Read before the release below: an adapter claim's -dealloc frees the
    // wrapper, so it must not be touched afterwards.
    bool adapterClaim = objcWrapper->IsAdapterClaim();

    [data release];

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
