#include "WrapperLifetimeCanary.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>
#include "ArgConverter.h"
#include "Caches.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "MetadataBuilder.h"
#include "ObjectManager.h"
#include "Runtime.h"
#import "TNSDerivedClass.h"
#include "WrapperLifetime.h"

// How canary mode learns that a native object with state was deallocated, so
// its state can be let go of. Instances of JS-extended classes are reported by
// their class's own -dealloc (InstallDeallocHook) either way; for others:
// - ASSOCIATION: a token associated with the object reports it from its
//   -dealloc, immediately and on any thread. The ObjC runtime aborts the
//   process for a class that forbids associated objects (Swift actors, for
//   one) and has no public query for it: ForbidsAssociatedObjects reads the
//   runtime's private flag instead.
// - WEAK_SWEEP: each record holds a weak reference to the object, checked by a
//   sweep after every major collection, so state lingers until then.
// An object the chosen signal cannot watch (a class forbidding associated
// objects, or refusing weak references) gets no state: its JS properties stay
// on the canary and the weak collections key its wrapper.
#define NS_CANARY_DEATH_ASSOCIATION 1
#define NS_CANARY_DEATH_WEAK_SWEEP 2
#ifndef NS_CANARY_DEATH_SIGNAL
#define NS_CANARY_DEATH_SIGNAL NS_CANARY_DEATH_ASSOCIATION
#endif

extern "C" id objc_initWeakOrNil(id* location, id value);
extern "C" id objc_loadWeakRetained(id* location);
extern "C" void objc_destroyWeak(id* location);

using namespace v8;

namespace tns {

// A native object's state in one isolate, shared by the registry and the
// object's live canary. Marked died once the object is known to be gone (with
// ASSOCIATION, also when objc_removeAssociatedObjects releases the token of a
// live object): its canary then sees no state and starts a new record on its
// next write. Teardown empties the handle.
struct CanaryRecord {
  Global<Object> state;
  std::atomic<bool> died{false};
  // A JS-implemented -dealloc of its object is running (WrapDealloc): the
  // object's own receiver still reads this record, but an object allocated
  // at the same address once the original -dealloc frees it must not.
  std::atomic<bool> dying{false};
  // Something reports this object's deallocation: a JS-extended class's
  // -dealloc, or the associated token. Otherwise only the weak reference below
  // tells, when a sweep reads it.
  bool reportsDeath = false;
  // An ObjC weak reference to the object, zeroed by the runtime when it is
  // deallocated, on any thread. Set for records nothing reports, and for any
  // record whose object became a weak-collection key (Wrap reads it).
  id object = nil;
  bool weakSet = false;
  // __releaseNativeCounterpart released a canary of the object and no canary
  // adopted the record since. Isolate thread only.
  bool released = false;
  // Its object's canaries forward (WrapperLifetimeCanary::Forwards): the state
  // is their only copy of the object's properties.
  bool forwards = false;
  // The object's address: after the record died, only a canary holding the
  // record keeps the object alive (ForEachState reads it then).
  void* address = nullptr;

  ~CanaryRecord() { objc_destroyWeak(&object); }

  // A racy read is enough: the slot only goes from the object to nil, and is
  // never dereferenced here.
  bool ObjectAlive() const {
    return reportsDeath ||
           __atomic_load_n(reinterpret_cast<void* const*>(&object), __ATOMIC_ACQUIRE) != nullptr;
  }
};

namespace {

// What the weak-collections builtin reads through a Uint32Array over `slots`
// (RegisterWrapFunctions). It drops every wrapper it cached from wrap once
// kEpoch changes, which can happen on any thread. After an unwrap that asked
// (UnwrapCallback), kLiveCanary is 1 when the value is a live canary standing
// for the key it answered: the wrapper wrap answers with for that key.
struct WeakCollectionCache {
  enum Slot { kEpoch, kLiveCanary, kSlotCount };
  std::atomic<uint32_t> slots[kSlotCount];

  // A wrapper wrap answered may no longer be the one it answers.
  void Invalidate() { slots[kEpoch].fetch_add(1, std::memory_order_release); }
  void SetLiveCanary(bool live) {
    slots[kLiveCanary].store(live ? 1 : 0, std::memory_order_relaxed);
  }
};

// Per-isolate. Shared with the tokens associated with native objects, which
// can be deallocated on any thread and after the isolate is gone.
struct CanaryRegistry {
  std::mutex mutex;
  std::unordered_map<void*, std::shared_ptr<CanaryRecord>> records;
  // Records whose token was deallocated; their handles are reset on the
  // runtime's thread.
  std::vector<std::shared_ptr<CanaryRecord>> dead;
  // Dead forwarding records a live canary still held when they were drained
  // (ReleaseStates). Isolate thread only.
  std::vector<std::shared_ptr<CanaryRecord>> orphaned;
  bool closed = false;
  bool drainPosted = false;
  bool sweepPosted = false;
  // Lets wrapper creation skip the lookup while no object has state.
  std::atomic<size_t> count{0};
  // Outlives the registry while the builtin's array does.
  std::shared_ptr<WeakCollectionCache> weakCollectionCache =
      std::make_shared<WeakCollectionCache>();
  Isolate* isolate = nullptr;
  std::weak_ptr<EventLoop> loop;
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
  // The association key: one per isolate, and never reused while a token
  // keeps this registry alive.
  char associationKey = 0;
#endif
};

struct CanaryState {
  std::shared_ptr<CanaryRegistry> registry = std::make_shared<CanaryRegistry>();
  // The weak collections' key for a native object hangs off its state, and
  // names the object it stands for. A released canary holds a copy.
  Global<Private> keyOfState;
  Global<Private> objectOfKey;
};

// Isolate thread. Lets go of orphaned records no canary holds any more, and
// of those whose state a canary took over. Only the list's own reference is
// left then, so each handle is reset on this thread.
void SweepOrphaned(CanaryRegistry* registry) {
  std::vector<std::shared_ptr<CanaryRecord>>& orphaned = registry->orphaned;
  for (auto it = orphaned.begin(); it != orphaned.end();) {
    if (it->use_count() > 1 && !(*it)->state.IsEmpty()) {
      ++it;
      continue;
    }
    (*it)->state.Reset();
    it = orphaned.erase(it);
  }
}

// Isolate thread. Lets go of the state of `dead` records, except that of a
// forwarding record a canary still holds: the record died under the live
// canary (its object's associations were removed), and its state stays the
// canary's only copy of the object's properties until the canary's next write
// moves it to a new record (StateForWrite). Such a record waits in `orphaned`
// until no canary holds it. Besides canaries, only a JS-implemented -dealloc
// (MarkDying, on the deallocating thread, also for a plain class whose
// -dealloc JS replaced) holds a record outside the registry; such a record is
// dying, and no canary can hold it, as a canary retains its object.
void ReleaseStates(CanaryRegistry* registry, std::vector<std::shared_ptr<CanaryRecord>>& dead) {
  ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(registry->isolate);
  for (std::shared_ptr<CanaryRecord>& record : dead) {
    if (record->forwards && !record->dying.load(std::memory_order_acquire) &&
        !record->state.IsEmpty() && record.use_count() > 1) {
      registry->orphaned.push_back(std::move(record));
    } else {
      record->state.Reset();
    }
    if (stats != nullptr) {
      stats->canaryNativeDeaths++;
    }
  }
  SweepOrphaned(registry);
}

void DrainDead(const std::shared_ptr<CanaryRegistry>& registry) {
  std::vector<std::shared_ptr<CanaryRecord>> dead;
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    registry->drainPosted = false;
    if (registry->closed) {
      return;
    }
    dead.swap(registry->dead);
  }
  ReleaseStates(registry.get(), dead);
}

// From a reporter's -dealloc, on whichever thread deallocates the object. With
// `expected`, retires the object's record only while it is still that one:
// once the object is freed, another thread can install a new object's record
// at the address, so the comparison must stay under the same lock as the erase.
void NativeDied(const std::shared_ptr<CanaryRegistry>& registry, void* object,
                const CanaryRecord* expected = nullptr) {
  if (registry->count.load(std::memory_order_relaxed) == 0) {
    return;
  }
  std::shared_ptr<EventLoop> loop;
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->closed) {
      return;
    }
    auto it = registry->records.find(object);
    if (it == registry->records.end() || (expected != nullptr && it->second.get() != expected)) {
      return;
    }
    // Erased now, inside the object's -dealloc: an object later allocated at
    // this address must not find this record.
    it->second->died.store(true, std::memory_order_release);
    // A record held outside the registry and not dying is a live canary's (its
    // associations were removed): wrap no longer answers with that canary.
    // A transient copy elsewhere bumps it spuriously, which only costs a refill.
    if (!it->second->dying.load(std::memory_order_acquire) && it->second.use_count() > 1) {
      registry->weakCollectionCache->Invalidate();
    }
    registry->dead.push_back(std::move(it->second));
    registry->records.erase(it);
    registry->count.fetch_sub(1, std::memory_order_relaxed);
    if (registry->drainPosted) {
      return;
    }
    loop = registry->loop.lock();
    registry->drainPosted = loop != nullptr;
  }
  // A post dropped at shutdown is fine: teardown resets every handle.
  if (loop != nullptr && !loop->PostInternal([registry]() { DrainDead(registry); })) {
    std::lock_guard<std::mutex> lock(registry->mutex);
    registry->drainPosted = false;
  }
}

// Every isolate's registry, for the extended classes' -dealloc: an instance can
// have state in an isolate other than the one that defined its class.
std::mutex registriesMutex_;
std::vector<std::weak_ptr<CanaryRegistry>> registries_;

std::vector<std::shared_ptr<CanaryRegistry>> LiveRegistries() {
  std::vector<std::shared_ptr<CanaryRegistry>> live;
  std::lock_guard<std::mutex> lock(registriesMutex_);
  for (auto it = registries_.begin(); it != registries_.end();) {
    if (std::shared_ptr<CanaryRegistry> registry = it->lock()) {
      if (registry->count.load(std::memory_order_relaxed) > 0) {
        live.push_back(std::move(registry));
      }
      ++it;
    } else {
      it = registries_.erase(it);
    }
  }
  return live;
}

using DyingRecords =
    std::vector<std::pair<std::shared_ptr<CanaryRegistry>, std::shared_ptr<CanaryRecord>>>;

// Before a JS-implemented -dealloc runs: marks the object's records dying in
// every isolate.
DyingRecords MarkDying(void* object) {
  DyingRecords dying;
  for (std::shared_ptr<CanaryRegistry>& registry : LiveRegistries()) {
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->records.find(object);
    if (!registry->closed && it != registry->records.end()) {
      it->second->dying.store(true, std::memory_order_release);
      dying.emplace_back(registry, it->second);
    }
  }
  return dying;
}

// After it returned, with `object` freed: retires each record by identity. A
// record a new object at the address already displaced (RetireIfDead) is gone
// from the map. `dying` keeps each record alive, so no new record can share
// its address.
void ReportDyingRecordsDied(const DyingRecords& dying, void* object) {
  for (const auto& [registry, record] : dying) {
    NativeDied(registry, object, record.get());
  }
}

// Not a message: a root class without -conformsToProtocol: would crash under
// scope "all". Walks the superclasses for key-value observing's subclass.
// Cached per class and thread, as every wrap under scope "all" asks and the
// walk costs tens of nanoseconds a class: the answer for a class is fixed
// before it has instances (ClassBuilder adds TNSDerivedClass to a class it
// creates first thing). A class disposed with objc_disposeClassPair and
// another allocated at its address would read the old answer.
bool IsExtendedInstance(id object) {
  Class klass = object_getClass(object);
  thread_local std::unordered_map<Class, bool> extendedClasses;
  auto cached = extendedClasses.find(klass);
  if (cached != extendedClasses.end()) {
    return cached->second;
  }
  bool extended = false;
  for (Class cls = klass; cls != nil; cls = class_getSuperclass(cls)) {
    if (class_conformsToProtocol(cls, @protocol(TNSDerivedClass))) {
      extended = true;
      break;
    }
  }
  extendedClasses.emplace(klass, extended);
  return extended;
}

// Plain canaries forward unless the app config allows shadowing native members,
// which only the mirroring handlers capture.
bool PlainCanariesForward() {
  return GetWrapperLifetimeMode() == WrapperLifetimeMode::kCanary &&
         GetWrapperLifetimeScope() == WrapperLifetimeScope::kAll &&
         !GetAllowShadowingNativeMembers();
}

#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
// The check objc_setAssociatedObject aborts on: RW_FORBIDS_ASSOCIATED_OBJECTS
// in the class_rw_t flags of the object's own class, reached through the mask
// libobjc exports for debuggers. Private layout (objc_class keeps `bits` after
// isa, superclass and the cache; the flags lead class_rw_t), so anything it
// cannot read, a missing mask or an unrealized class, counts as forbidding. Not
// a message, as IsExtendedInstance.
bool ForbidsAssociatedObjects(id object) {
  static const uintptr_t* rwDataMask =
      static_cast<const uintptr_t*>(dlsym(RTLD_DEFAULT, "objc_debug_class_rw_data_mask"));
  if (rwDataMask == nullptr) {
    return true;
  }
  struct ClassLayout {
    void* isa;
    void* superclass;
    void* cache[2];
    uintptr_t bits;
  };
  const auto* cls = static_cast<const ClassLayout*>((__bridge const void*)object_getClass(object));
  const auto* flags = reinterpret_cast<const uint32_t*>(cls->bits & *rwDataMask);
  constexpr uint32_t kRealized = 1u << 31;
  constexpr uint32_t kForbidsAssociatedObjects = 1u << 20;
  return flags == nullptr || (*flags & kRealized) == 0 || (*flags & kForbidsAssociatedObjects) != 0;
}
#endif

#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
// Lets go of the state of every object that was deallocated. Runs as an event
// loop task (under the Locker, on the runtime's thread), never inside the GC.
void Sweep(const std::shared_ptr<CanaryRegistry>& registry) {
  std::vector<std::shared_ptr<CanaryRecord>> dead;
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    registry->sweepPosted = false;
    if (registry->closed) {
      return;
    }
    // Records a re-wrap or a write already found dead.
    dead.swap(registry->dead);
    for (auto it = registry->records.begin(); it != registry->records.end();) {
      if (it->second->ObjectAlive()) {
        ++it;
        continue;
      }
      it->second->died.store(true, std::memory_order_release);
      dead.push_back(std::move(it->second));
      it = registry->records.erase(it);
      registry->count.fetch_sub(1, std::memory_order_relaxed);
    }
  }
  ReleaseStates(registry.get(), dead);
}
#endif

std::shared_ptr<CanaryRegistry> RegistryFor(Isolate* isolate) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  return state != nullptr ? state->registry : nullptr;
}

}  // namespace

}  // namespace tns

#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
// Associated with a native object once it has state in an isolate; its
// -dealloc runs when the object is deallocated.
@interface TNSCanaryLifecycleToken : NSObject {
 @public
  std::shared_ptr<tns::CanaryRegistry> registry_;
  void* object_;
}
@end

@implementation TNSCanaryLifecycleToken
- (void)dealloc {
  if (registry_ != nullptr) {
    tns::NativeDied(registry_, object_);
  }
  [super dealloc];
}
@end
#endif

namespace tns {

namespace {

// The adopted canary registration of an interceptor's holder, or null when the
// holder is not a canary: a plain wrapper outside the scope, a released one, or
// a `super` accessor object (internal field 1 holds a class name).
ObjectWeakCallbackState* CanaryOf(Isolate* isolate, Local<Object> holder) {
  if (holder->InternalFieldCount() > 1 && holder->GetInternalField(1).As<Value>()->IsString()) {
    return nullptr;
  }
  BaseDataWrapper* wrapper = tns::GetValue(isolate, holder);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
    return nullptr;
  }
  ObjectWeakCallbackState* state = static_cast<ObjCDataWrapper*>(wrapper)->LifetimeState();
  return state != nullptr && state->lifetimeCanary_ ? state : nullptr;
}

// The record's state is usable: its object is not known to be gone and
// teardown has not emptied it. Handles are only reset under the Locker these
// callers hold.
bool Usable(const std::shared_ptr<CanaryRecord>& record) {
  return record != nullptr && !record->died.load(std::memory_order_acquire) &&
         !record->state.IsEmpty();
}

// Under the registry mutex: a record whose object is gone but which no sweep
// has reached yet is moved out, so an object now at that address starts over.
// True when it was; the caller then owes the registry a drain (PostDrain).
bool RetireIfDead(CanaryRegistry* registry,
                  std::unordered_map<void*, std::shared_ptr<CanaryRecord>>::iterator it) {
  if (it->second->ObjectAlive() && !it->second->dying.load(std::memory_order_acquire)) {
    return false;
  }
  it->second->died.store(true, std::memory_order_release);
  registry->dead.push_back(std::move(it->second));
  registry->records.erase(it);
  registry->count.fetch_sub(1, std::memory_order_relaxed);
  return true;
}

// Outside the registry mutex: lets go of retired records' state on the event
// loop, unless a drain is already on its way.
void PostDrain(const std::shared_ptr<CanaryRegistry>& registry) {
  std::shared_ptr<EventLoop> loop = registry->loop.lock();
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->closed || registry->drainPosted || registry->dead.empty() || loop == nullptr) {
      return;
    }
    registry->drainPosted = true;
  }
  if (!loop->PostInternal([registry]() { DrainDead(registry); })) {
    std::lock_guard<std::mutex> lock(registry->mutex);
    registry->drainPosted = false;
  }
}

// The record a receiver lent to JS from -dealloc reads: its object's record,
// dying or not. Such a receiver is never adopted, so it has no canary state.
std::shared_ptr<CanaryRecord> BorrowedRecord(Isolate* isolate, Local<Object> holder) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, holder);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject ||
      !static_cast<ObjCDataWrapper*>(wrapper)->IsBorrowed()) {
    return nullptr;
  }
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->count.load(std::memory_order_relaxed) == 0) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(state->registry->mutex);
  auto it =
      state->registry->records.find((__bridge void*)static_cast<ObjCDataWrapper*>(wrapper)->Data());
  return it != state->registry->records.end() ? it->second : nullptr;
}

// Set while this thread copies properties between a canary and its state, so
// the canary's handlers let those defines through. Per thread rather than per
// isolate: the copy runs no JS, so only its own defines reach an interceptor
// on this thread meanwhile.
thread_local bool copyingProperties_ = false;

Local<Value> DescriptorField(Isolate* isolate, Local<Context> context, Local<Object> descriptor,
                             const char* name) {
  Local<Value> value;
  return descriptor->Get(context, tns::ToV8String(isolate, name)).ToLocal(&value)
             ? value
             : Local<Value>(v8::Undefined(isolate));
}

// Copies `from`'s own string- and symbol-keyed properties onto `to`, with their
// attributes; an accessor keeps its functions, which run with whichever object
// they are reached through as `this`. With `keepExisting`, a name `to` already
// owns keeps its property.
void CopyOwnProperties(Isolate* isolate, Local<Context> context, Local<Object> from,
                       Local<Object> to, bool keepExisting = false) {
  HandleScope scope(isolate);
  TryCatch tc(isolate);
  bool wasCopying = copyingProperties_;
  copyingProperties_ = true;
  Local<v8::Array> names;
  if (from->GetPropertyNames(context, KeyCollectionMode::kOwnOnly, PropertyFilter::ALL_PROPERTIES,
                             IndexFilter::kSkipIndices, KeyConversionMode::kConvertToString)
          .ToLocal(&names)) {
    for (uint32_t i = 0; i < names->Length(); i++) {
      Local<Value> name;
      if (!names->Get(context, i).ToLocal(&name) || !name->IsName()) {
        continue;
      }
      Local<v8::Name> key = name.As<v8::Name>();
      if (keepExisting && to->HasRealNamedProperty(context, key).FromMaybe(true)) {
        continue;
      }
      if (!from->HasRealNamedCallbackProperty(context, key).FromMaybe(true)) {
        PropertyAttribute attributes;
        Local<Value> value;
        if (from->GetRealNamedPropertyAttributes(context, key).To(&attributes) &&
            from->GetRealNamedProperty(context, key).ToLocal(&value)) {
          (void)to->DefineOwnProperty(context, key, value, attributes);
        }
        continue;
      }
      Local<Value> descriptorValue;
      if (!from->GetOwnPropertyDescriptor(context, key).ToLocal(&descriptorValue) ||
          !descriptorValue->IsObject()) {
        continue;
      }
      Local<Object> descriptor = descriptorValue.As<Object>();
      PropertyDescriptor accessor(DescriptorField(isolate, context, descriptor, "get"),
                                  DescriptorField(isolate, context, descriptor, "set"));
      accessor.set_enumerable(
          DescriptorField(isolate, context, descriptor, "enumerable")->BooleanValue(isolate));
      accessor.set_configurable(
          DescriptorField(isolate, context, descriptor, "configurable")->BooleanValue(isolate));
      (void)to->DefineProperty(context, key, accessor);
    }
  }
  copyingProperties_ = wasCopying;
}

// The state object of the holder, if it has one.
bool ExistingState(Isolate* isolate, Local<Object> holder, Local<Object>* out) {
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  std::shared_ptr<CanaryRecord> record =
      canary != nullptr ? canary->canaryRecord_ : BorrowedRecord(isolate, holder);
  if (!Usable(record)) {
    return false;
  }
  *out = Local<Object>::New(isolate, record->state);
  return true;
}

// The state object of the holder, created on its first write.
bool StateForWrite(Isolate* isolate, Local<Object> holder, Local<Object>* out) {
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  if (canary == nullptr) {
    // A -dealloc receiver writes to its object's existing state only.
    return ExistingState(isolate, holder, out);
  }
  if (canary->canaryRecord_ == nullptr ||
      canary->canaryRecord_->died.load(std::memory_order_acquire)) {
    std::shared_ptr<CanaryRegistry> registry = RegistryFor(isolate);
    if (registry == nullptr) {
      return false;
    }
    id object = canary->lifetimeTarget_;
    // The record died under a live canary (its token was removed): a
    // forwarding canary's new record takes over the dead record's state
    // object, weak-collection key included; a mirroring canary's own
    // properties seed a new one.
    std::shared_ptr<CanaryRecord> previous = canary->canaryRecord_;
    // A JS-extended class's own -dealloc reports its instances' deaths.
    bool extended = IsExtendedInstance(object);
    bool forwards = !extended && PlainCanariesForward();
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
    if (!extended && ForbidsAssociatedObjects(object)) {
      return false;
    }
#endif
    bool takesOver = forwards && previous != nullptr && !previous->state.IsEmpty();
    // Allocated before the lock: a collection this allocation starts can run
    // callbacks (the weak sweep's, a finalizer's -dealloc) that take it.
    Local<Object> freshState;
    if (!takesOver) {
      freshState = Object::New(isolate, Null(isolate), nullptr, nullptr, 0);
    }
    bool created = false;
    bool retired = false;
    {
      std::lock_guard<std::mutex> lock(registry->mutex);
      if (registry->closed) {
        return false;
      }
      auto existing = registry->records.find((__bridge void*)object);
      if (existing != registry->records.end()) {
        retired = RetireIfDead(registry.get(), existing);
      }
      std::shared_ptr<CanaryRecord>& slot = registry->records[(__bridge void*)object];
      if (slot == nullptr) {
        auto record = std::make_shared<CanaryRecord>();
        record->reportsDeath = extended || NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION;
        record->forwards = forwards;
        record->address = (__bridge void*)object;
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
        if (!record->reportsDeath) {
          if (objc_initWeakOrNil(&record->object, object) == nil) {
            // The class refuses weak references.
            registry->records.erase((__bridge void*)object);
            return false;
          }
          record->weakSet = true;
        }
#endif
        if (takesOver) {
          record->state = std::move(previous->state);
          // The weak collections reach the record of a key's object through
          // this slot (WrapCallback). The canary retains the object.
          if (previous->weakSet && !record->weakSet &&
              objc_initWeakOrNil(&record->object, object) != nil) {
            record->weakSet = true;
          }
        } else {
          record->state.Reset(isolate, freshState);
        }
        slot = std::move(record);
        registry->count.fetch_add(1, std::memory_order_relaxed);
        created = true;
      }
      canary->canaryRecord_ = slot;
    }
    if (retired) {
      PostDrain(registry);
    }
    if (created) {
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
      if (!extended) {
        TNSCanaryLifecycleToken* token = [[TNSCanaryLifecycleToken alloc] init];
        token->registry_ = registry;
        token->object_ = (__bridge void*)object;
        objc_setAssociatedObject(object, &registry->associationKey, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [token release];
      }
#endif
      if (ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate);
          stats != nullptr && !takesOver) {
        stats->canaryStates++;
      }
      if (previous != nullptr && !forwards) {
        CopyOwnProperties(isolate, isolate->GetCurrentContext(), holder, freshState);
      }
    } else if (!forwards && Usable(canary->canaryRecord_)) {
      // Joined state another wrapper of the object wrote: the canary mirrors it.
      CopyOwnProperties(isolate, isolate->GetCurrentContext(),
                        Local<Object>::New(isolate, canary->canaryRecord_->state), holder);
    }
  }
  if (!Usable(canary->canaryRecord_)) {
    return false;
  }
  *out = Local<Object>::New(isolate, canary->canaryRecord_->state);
  return true;
}

bool HasOwn(Local<Context> context, Local<Object> state, Local<v8::Name> property) {
  return state->HasOwnProperty(context, property).FromMaybe(false);
}

// The object of `holder`'s prototype chain, `holder` included, with a real own
// `property`, interceptors skipped; empty if there is none.
Local<Object> OwnerOf(Local<Context> context, Local<Object> holder, Local<v8::Name> property) {
  Local<Object> object = holder;
  while (!object->HasRealNamedProperty(context, property).FromMaybe(false)) {
    Local<Value> prototype = object->GetPrototype();
    if (!prototype->IsObject()) {
      return Local<Object>();
    }
    object = prototype.As<Object>();
  }
  return object;
}

// The mirroring handlers: each copies its write into the state and declines, so
// V8 also applies it to the canary, where reads find a real own property and
// never call into C++. There is no getter, query, enumerator or descriptor
// callback for the same reason. The handlers are masking, so they also see
// names the prototype chain has. After the setter declines, V8 adds a new name
// to the canary without calling the definer, so the setter itself decides what
// becomes state. V8 calls the setter only when the canary is the receiver.
Intercepted Setter(Local<v8::Name> property, Local<Value> value,
                   const PropertyCallbackInfo<v8::Boolean>& info) {
  // v8::Object::DefineOwnProperty reaches the setter, not the definer.
  if (copyingProperties_) {
    return Intercepted::kNo;
  }
  Isolate* isolate = info.GetIsolate();
  Local<Object> holder = info.Holder();
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  std::shared_ptr<CanaryRecord> borrowed;
  if (canary == nullptr) {
    borrowed = BorrowedRecord(isolate, holder);
    if (!Usable(borrowed)) {
      return Intercepted::kNo;
    }
  }
  if (ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate)) {
    stats->canaryInterceptedWrites++;
  }
  CanaryRecord* record = canary != nullptr ? canary->canaryRecord_.get() : borrowed.get();
  Local<Context> context = isolate->GetCurrentContext();
  if (record != nullptr && !record->died.load(std::memory_order_acquire) &&
      !record->state.IsEmpty()) {
    // Own on the state means own on the canary: a rewrite of a JS property.
    Local<Object> state = Local<Object>::New(isolate, record->state);
    if (HasOwn(context, state, property)) {
      if (!state->HasRealNamedCallbackProperty(context, property).FromMaybe(true)) {
        (void)state->Set(context, property, value);
      }
      return Intercepted::kNo;
    }
  }
  // Searches the prototype chain too: absent there means a new name.
  PropertyAttribute attributes;
  if (holder->GetRealNamedPropertyAttributes(context, property).To(&attributes)) {
    // V8 rejects a write to a read-only property and runs an accessor's
    // setter: a native property's (an accessor pair on its class's
    // prototype), a JS one's, or one defined on the canary, which runs with
    // the canary as `this` and so mirrors whatever it writes. None is state.
    // Calling a JS setter from here was measured slower than V8's own lookup
    // after the decline: the API hands a setter out only in a descriptor
    // object. A native property's setter runs from here when its class's
    // prototype vouches that the accessor found is still its own.
    if ((attributes & ReadOnly) != 0) {
      return Intercepted::kNo;
    }
    Local<Object> owner = OwnerOf(context, holder, property);
    if (owner.IsEmpty()) {
      return Intercepted::kNo;
    }
    Maybe<bool> accessor = owner->HasRealNamedCallbackProperty(context, property);
    if (accessor.IsNothing()) {
      return Intercepted::kNo;
    }
    if (accessor.FromJust()) {
      // The setter can run JS, a collection or a -dealloc: neither the canary
      // nor its record is touched after it.
      if (MetadataBuilder::TrySetNativeProperty(isolate, context, owner, property, holder, value)) {
        info.GetReturnValue().Set(true);
        return Intercepted::kYes;
      }
      return Intercepted::kNo;
    }
  }
  Local<Object> state;
  if (!StateForWrite(isolate, holder, &state)) {
    return Intercepted::kNo;
  }
  if (!HasOwn(context, state, property)) {
    (void)state->CreateDataProperty(context, property, value);
  } else if (!state->HasRealNamedCallbackProperty(context, property).FromMaybe(true)) {
    (void)state->Set(context, property, value);
  }
  return Intercepted::kNo;
}

Intercepted Deleter(Local<v8::Name> property, const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (ExistingState(isolate, info.Holder(), &state)) {
    (void)state->Delete(isolate->GetCurrentContext(), property);
  }
  return Intercepted::kNo;
}

// Object.defineProperty, define-semantics class fields and `super.x = v` on a
// receiver that lacks `x` reach here.
Intercepted Definer(Local<v8::Name> property, const PropertyDescriptor& descriptor,
                    const PropertyCallbackInfo<v8::Boolean>& info) {
  if (copyingProperties_) {
    return Intercepted::kNo;
  }
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (StateForWrite(isolate, info.Holder(), &state)) {
    (void)state->DefineProperty(isolate->GetCurrentContext(), property,
                                const_cast<PropertyDescriptor&>(descriptor));
  }
  return Intercepted::kNo;
}

// The forwarding handlers: the state is the only copy of the canary's
// properties, so every access to them is answered from it and intercepted.
// Non-masking: V8 calls them only for names absent from the canary and its
// prototype chain, so native calls and native property writes never reach C++
// here.

// The state the forwarding handlers read: the canary's record's, also once
// that record died under the live canary, until the canary's next write
// carries it over to a new record (StateForWrite); or the record of a receiver
// lent to JS from -dealloc.
bool ForwardedState(Isolate* isolate, Local<Object> holder, Local<Object>* out) {
  // Copying the state onto the canary (KeepWeakCollectionKey) must find no
  // current property, or V8 skips defining an identical one.
  if (copyingProperties_) {
    return false;
  }
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  if (canary == nullptr) {
    std::shared_ptr<CanaryRecord> borrowed = BorrowedRecord(isolate, holder);
    if (!Usable(borrowed)) {
      return false;
    }
    *out = Local<Object>::New(isolate, borrowed->state);
    return true;
  }
  CanaryRecord* record = canary->canaryRecord_.get();
  if (record == nullptr || record->state.IsEmpty()) {
    return false;
  }
  *out = Local<Object>::New(isolate, record->state);
  return true;
}

Intercepted ForwardGetter(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ForwardedState(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (!HasOwn(context, state, property)) {
    return Intercepted::kNo;
  }
  Local<Value> value;
  // An accessor runs with the canary as `this` (interceptors see the holder,
  // not the receiver).
  if (state->Get(context, property, info.Holder()).ToLocal(&value)) {
    info.GetReturnValue().Set(value);
  }
  return Intercepted::kYes;
}

Intercepted ForwardSetter(Local<v8::Name> property, Local<Value> value,
                          const PropertyCallbackInfo<v8::Boolean>& info) {
  // v8::Object::DefineOwnProperty reaches the setter, not the definer.
  if (copyingProperties_) {
    return Intercepted::kNo;
  }
  Isolate* isolate = info.GetIsolate();
  Local<Object> holder = info.Holder();
  Local<Object> state;
  if (!StateForWrite(isolate, holder, &state)) {
    return Intercepted::kNo;
  }
  if (ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate)) {
    stats->canaryInterceptedWrites++;
  }
  Local<Context> context = isolate->GetCurrentContext();
  // v8::Object::Set reports success for a write [[Set]] rejects, so a
  // read-only property and an accessor without a setter are checked here: the
  // false return makes V8 throw in strict code.
  PropertyAttribute attributes;
  if (!state->GetRealNamedPropertyAttributes(context, property).To(&attributes)) {
    Maybe<bool> created = state->CreateDataProperty(context, property, value);
    if (created.IsJust()) {
      info.GetReturnValue().Set(created.FromJust());
    }
    return Intercepted::kYes;
  }
  if ((attributes & ReadOnly) != 0) {
    info.GetReturnValue().Set(false);
    return Intercepted::kYes;
  }
  if (!state->HasRealNamedCallbackProperty(context, property).FromMaybe(false)) {
    Maybe<bool> set = state->Set(context, property, value);
    if (set.IsJust()) {
      info.GetReturnValue().Set(set.FromJust());
    }
    return Intercepted::kYes;
  }
  Local<Value> descriptor;
  Local<Value> setter;
  if (!state->GetOwnPropertyDescriptor(context, property).ToLocal(&descriptor) ||
      !descriptor->IsObject() ||
      !descriptor.As<Object>()->Get(context, tns::ToV8String(isolate, "set")).ToLocal(&setter)) {
    return Intercepted::kYes;
  }
  if (!setter->IsFunction()) {
    info.GetReturnValue().Set(false);
    return Intercepted::kYes;
  }
  // An accessor runs with the canary as `this`.
  Local<Value> argv[] = {value};
  if (!setter.As<v8::Function>()->Call(context, holder, 1, argv).IsEmpty()) {
    info.GetReturnValue().Set(true);
  }
  return Intercepted::kYes;
}

Intercepted ForwardQuery(Local<v8::Name> property, const PropertyCallbackInfo<v8::Integer>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ForwardedState(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (!HasOwn(context, state, property)) {
    return Intercepted::kNo;
  }
  PropertyAttribute attributes;
  if (state->GetPropertyAttributes(context, property).To(&attributes)) {
    info.GetReturnValue().Set(v8::Integer::New(isolate, attributes));
  }
  return Intercepted::kYes;
}

Intercepted ForwardDeleter(Local<v8::Name> property,
                           const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ForwardedState(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (!HasOwn(context, state, property)) {
    return Intercepted::kNo;
  }
  bool deleted;
  if (state->Delete(context, property).To(&deleted)) {
    info.GetReturnValue().Set(deleted);
  }
  return Intercepted::kYes;
}

void ForwardEnumerator(const PropertyCallbackInfo<v8::Array>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ForwardedState(isolate, info.Holder(), &state)) {
    return;
  }
  Local<v8::Array> names;
  if (state
          ->GetPropertyNames(isolate->GetCurrentContext(), KeyCollectionMode::kOwnOnly,
                             PropertyFilter::ALL_PROPERTIES, IndexFilter::kSkipIndices)
          .ToLocal(&names)) {
    info.GetReturnValue().Set(names);
  }
}

Intercepted ForwardDefiner(Local<v8::Name> property, const PropertyDescriptor& descriptor,
                           const PropertyCallbackInfo<v8::Boolean>& info) {
  if (copyingProperties_) {
    return Intercepted::kNo;
  }
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!StateForWrite(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  bool defined;
  if (state
          ->DefineProperty(isolate->GetCurrentContext(), property,
                           const_cast<PropertyDescriptor&>(descriptor))
          .To(&defined)) {
    info.GetReturnValue().Set(defined);
  }
  return Intercepted::kYes;
}

Intercepted ForwardDescriptor(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ForwardedState(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (!HasOwn(context, state, property)) {
    return Intercepted::kNo;
  }
  Local<Value> descriptor;
  if (state->GetOwnPropertyDescriptor(context, property).ToLocal(&descriptor)) {
    info.GetReturnValue().Set(descriptor);
  }
  return Intercepted::kYes;
}

#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
// Posts a sweep when a major collection ends, behind the release drain the
// collection queued: objects it released are gone by the time the sweep runs.
// Only posts; the GC is no place to reset handles.
void PostSweepAfterGC(Isolate* isolate, GCType, GCCallbackFlags) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return;
  }
  std::shared_ptr<CanaryRegistry> registry = state->registry;
  std::shared_ptr<EventLoop> loop = registry->loop.lock();
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    // Records already retired wait in `dead` even once none is left in use.
    if (registry->sweepPosted || loop == nullptr ||
        (registry->count.load(std::memory_order_relaxed) == 0 && registry->dead.empty())) {
      return;
    }
    registry->sweepPosted = true;
  }
  if (!loop->PostInternal([registry]() { Sweep(registry); })) {
    std::lock_guard<std::mutex> lock(registry->mutex);
    registry->sweepPosted = false;
  }
}
#endif

// unwrap(value, create, reportLive): the weak collections' key for a canary's
// native object, a frozen, null-prototype object that lives as long as the
// object's state, that is, until the native object is deallocated, or as long
// as a released canary of the object holding a copy. Lookups pass `create`
// false and never make one: with no key yet, no entry can be keyed by it. The
// value itself for anything that is not a canary, a Proxy included (it is a key
// of its own, as in every other mode). With `reportLive`, also sets
// WeakCollectionCache::kLiveCanary.
void UnwrapCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> value = info[0];
  bool create = info[1]->IsTrue();
  bool reportLive = info[2]->IsTrue();
  info.GetReturnValue().Set(value);
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  Local<Object> state;
  if (reportLive && canaryState != nullptr) {
    canaryState->registry->weakCollectionCache->SetLiveCanary(false);
  }
  // Canaries and -dealloc receivers have internal fields; for any other object
  // the wrapper lookups below would each read a private property to find no
  // canary.
  if (canaryState == nullptr || !value->IsObject() || value->IsProxy() ||
      value.As<Object>()->InternalFieldCount() == 0) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Private> keyOfState = canaryState->keyOfState.Get(isolate);
  Local<Value> key;
  if (create ? !StateForWrite(isolate, value.As<Object>(), &state)
             : !ExistingState(isolate, value.As<Object>(), &state)) {
    // A released canary keeps its key itself, or null when it had none
    // (KeepWeakCollectionKey).
    if (!value.As<Object>()->GetPrivate(context, keyOfState).ToLocal(&key)) {
      return;
    }
    if (key->IsObject()) {
      info.GetReturnValue().Set(key);
    } else if (key->IsNull()) {
      // Such a canary is a key of its own, which nothing keyed on its object
      // can find: a released-object access.
      ReleasedReason reason = tns::GetReleasedReason(value);
      if (reason != ReleasedReason::kNone) {
        tns::ReportReleasedObject(
            isolate, value, reason,
            "weak collection key: WeakMap, WeakSet, WeakRef or FinalizationRegistry", true);
      }
    }
    return;
  }
  if (state->GetPrivate(context, keyOfState).ToLocal(&key) && key->IsObject()) {
    if (reportLive) {
      canaryState->registry->weakCollectionCache->SetLiveCanary(
          CanaryOf(isolate, value.As<Object>()) != nullptr);
    }
    info.GetReturnValue().Set(key);
    return;
  }
  if (!create) {
    return;
  }
  ObjectWeakCallbackState* canary = CanaryOf(isolate, value.As<Object>());
  if (canary == nullptr) {
    // A receiver lent to JS from -dealloc: its object is going away.
    return;
  }
  CanaryRecord* record = canary->canaryRecord_.get();
  if (!record->weakSet) {
    if (objc_initWeakOrNil(&record->object, canary->lifetimeTarget_) == nil) {
      return;
    }
    record->weakSet = true;
  }
  Local<Object> newKey = Object::New(isolate, Null(isolate), nullptr, nullptr, 0);
  uint64_t address = reinterpret_cast<uintptr_t>((__bridge void*)canary->lifetimeTarget_);
  if (!newKey
           ->SetPrivate(context, canaryState->objectOfKey.Get(isolate),
                        BigInt::NewFromUnsigned(isolate, address))
           .FromMaybe(false) ||
      !newKey->SetIntegrityLevel(context, IntegrityLevel::kFrozen).FromMaybe(false) ||
      !state->SetPrivate(context, keyOfState, newKey).FromMaybe(false)) {
    return;
  }
  if (reportLive) {
    canaryState->registry->weakCollectionCache->SetLiveCanary(true);
  }
  info.GetReturnValue().Set(newKey);
}

// The object a key stands for: its live canary or a new one, or undefined once
// the native object is gone. Anything that is not a key passes through.
void WrapCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> value = info[0];
  info.GetReturnValue().Set(value);
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  if (canaryState == nullptr || !value->IsObject()) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> key = value.As<Object>();
  Local<Value> address;
  if (!key->GetPrivate(context, canaryState->objectOfKey.Get(isolate)).ToLocal(&address) ||
      !address->IsBigInt()) {
    return;
  }
  info.GetReturnValue().SetUndefined();
  std::shared_ptr<CanaryRecord> record;
  {
    std::lock_guard<std::mutex> lock(canaryState->registry->mutex);
    auto it = canaryState->registry->records.find(
        reinterpret_cast<void*>(static_cast<uintptr_t>(address.As<BigInt>()->Uint64Value())));
    if (it == canaryState->registry->records.end()) {
      return;
    }
    record = it->second;
  }
  if (!Usable(record) || !record->weakSet) {
    return;
  }
  // A record at that address may belong to a later object: it must be the
  // key's own.
  Local<Value> recordKey;
  Local<Object> state = Local<Object>::New(isolate, record->state);
  if (!state->GetPrivate(context, canaryState->keyOfState.Get(isolate)).ToLocal(&recordKey) ||
      !recordKey->StrictEquals(key)) {
    return;
  }
  id object = objc_loadWeakRetained(&record->object);
  if (object == nil) {
    return;
  }
  // A live wrapper is handed back as is: building one through ConvertArgument
  // would reset a protocol-typed wrapper's prototype to its class's.
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  std::shared_ptr<Persistent<Value>> cached =
      ArgConverter::FindCachedInstance(isolate, cache, object);
  if (cached != nullptr && !cached->IsEmpty()) {
    [object release];
    info.GetReturnValue().Set(cached->Get(isolate));
    return;
  }
  if (record->released) {
    // Released by JS and not handed back by native code: JS holds no wrapper
    // of it until native code returns it.
    [object release];
    return;
  }
  ObjCDataWrapper* wrapper = new ObjCDataWrapper(object);
  Local<Value> result = ArgConverter::ConvertArgument(context, wrapper);
  tns::DeleteWrapperIfUnused(isolate, result, wrapper);
  [object release];
  info.GetReturnValue().Set(result);
}

}  // namespace

void WrapperLifetimeCanary::Init(Isolate* isolate) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return;
  }
  state->registry->isolate = isolate;
  state->keyOfState.Reset(isolate, Private::New(isolate));
  state->objectOfKey.Reset(isolate, Private::New(isolate));
  if (Runtime* runtime = Runtime::GetRuntime(isolate)) {
    state->registry->loop = runtime->GetEventLoop();
  }
  {
    std::lock_guard<std::mutex> lock(registriesMutex_);
    registries_.push_back(state->registry);
  }
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
  isolate->AddGCEpilogueCallback(PostSweepAfterGC, kGCTypeMarkSweepCompact);
#endif
}

bool WrapperLifetimeCanary::RegisterWrapFunctions(Local<Context> context, Local<Object> binding) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> unwrap;
  Local<v8::Function> wrap;
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return false;
  }
  auto* owner = new std::shared_ptr<WeakCollectionCache>(state->registry->weakCollectionCache);
  std::unique_ptr<BackingStore> store = ArrayBuffer::NewBackingStore(
      (*owner)->slots, sizeof((*owner)->slots),
      [](void*, size_t, void* data) {
        delete static_cast<std::shared_ptr<WeakCollectionCache>*>(data);
      },
      owner);
  Local<v8::Uint32Array> cache = v8::Uint32Array::New(ArrayBuffer::New(isolate, std::move(store)),
                                                      0, WeakCollectionCache::kSlotCount);
  return v8::Function::New(context, UnwrapCallback).ToLocal(&unwrap) &&
         v8::Function::New(context, WrapCallback).ToLocal(&wrap) &&
         binding->Set(context, tns::ToV8String(isolate, "unwrap"), unwrap).FromMaybe(false) &&
         binding->Set(context, tns::ToV8String(isolate, "wrap"), wrap).FromMaybe(false) &&
         binding->Set(context, tns::ToV8String(isolate, "cache"), cache).FromMaybe(false);
}

void WrapperLifetimeCanary::KeepWeakCollectionKey(Isolate* isolate, Local<Object> canary) {
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  if (canaryState == nullptr || canaryState->keyOfState.IsEmpty()) {
    return;
  }
  HandleScope scope(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  Local<Private> keyOfState = canaryState->keyOfState.Get(isolate);
  auto currentRecord = [&]() {
    ObjectWeakCallbackState* state = CanaryOf(isolate, canary);
    return state != nullptr ? state->canaryRecord_ : std::shared_ptr<CanaryRecord>();
  };
  auto keyOf = [&](const std::shared_ptr<CanaryRecord>& record) {
    Local<Value> key;
    if (Usable(record) &&
        Local<Object>::New(isolate, record->state)->GetPrivate(context, keyOfState).ToLocal(&key) &&
        key->IsObject()) {
      return key;
    }
    return Local<Value>(v8::Null(isolate));
  };
  // The write can allocate, and the finalizers of a collection that starts
  // there can run JS that gives the canary a record or its record a key: the
  // write repeats, a bounded number of times, until it stores the current key.
  constexpr int kMaxWrites = 4;
  std::shared_ptr<CanaryRecord> record = currentRecord();
  if (record != nullptr && record->forwards && !record->state.IsEmpty()) {
    // A name the prototype chain has never reaches a forwarding canary's
    // handlers, so a property the canary owns is newer than the state's.
    CopyOwnProperties(isolate, context, Local<Object>::New(isolate, record->state), canary, true);
  }
  Local<Value> copy = keyOf(record);
  for (int writes = 1;; writes++) {
    // Private symbols bypass the canary's handlers.
    (void)canary->SetPrivate(context, keyOfState, copy);
    std::shared_ptr<CanaryRecord> current = currentRecord();
    if (!Usable(current) || writes == kMaxWrites) {
      break;
    }
    Local<Value> currentCopy = keyOf(current);
    if (current == record && currentCopy->StrictEquals(copy)) {
      break;
    }
    record = std::move(current);
    copy = currentCopy;
  }
  // Last, with nothing that allocates after it: whichever record the canary
  // holds now is the one the release leaves behind.
  if (std::shared_ptr<CanaryRecord> current = currentRecord()) {
    current->released = true;
  }
  // wrap hands out no wrapper of the object now.
  canaryState->registry->weakCollectionCache->Invalidate();
}

void WrapperLifetimeCanary::InstallDeallocHook(Class extendedClass) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  static std::mutex hookedMutex;
  static std::unordered_map<Class, bool> hooked;
  {
    std::lock_guard<std::mutex> lock(hookedMutex);
    if (hooked[extendedClass]) {
      return;
    }
    hooked[extendedClass] = true;
  }
  Class superclass = class_getSuperclass(extendedClass);
  // The records stay dying, not gone, until the superclass's -dealloc returns,
  // as WrapDealloc keeps them: one implemented in JS reads the state.
  IMP dealloc = imp_implementationWithBlock(^(id self) {
    void* object = (__bridge void*)self;
    DyingRecords dying = MarkDying(object);
    struct objc_super super = {.receiver = self, .super_class = superclass};
    reinterpret_cast<void (*)(struct objc_super*, SEL)>(objc_msgSendSuper)(&super,
                                                                           @selector(dealloc));
    ReportDyingRecordsDied(dying, object);
  });
  class_addMethod(extendedClass, @selector(dealloc), dealloc, "v@:");
}

IMP WrapperLifetimeCanary::WrapDealloc(SEL selector, IMP imp) {
  if (selector != @selector(dealloc) || GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return imp;
  }
  return imp_implementationWithBlock(^(id self) {
    void* object = (__bridge void*)self;
    DyingRecords dying = MarkDying(object);
    reinterpret_cast<void (*)(id, SEL)>(imp)(self, @selector(dealloc));
    ReportDyingRecordsDied(dying, object);
  });
}

void WrapperLifetimeCanary::ConfigureInstanceTemplate(Local<ObjectTemplate> instanceTemplate,
                                                      CanaryKind kind) {
  if (kind == CanaryKind::kNone || GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  if (Forwards(kind)) {
    instanceTemplate->SetHandler(NamedPropertyHandlerConfiguration(
        ForwardGetter, ForwardSetter, ForwardQuery, ForwardDeleter, ForwardEnumerator,
        ForwardDefiner, ForwardDescriptor, Local<Value>(), PropertyHandlerFlags::kNonMasking));
    return;
  }
  instanceTemplate->SetHandler(
      NamedPropertyHandlerConfiguration(nullptr, Setter, nullptr, Deleter, nullptr, Definer,
                                        nullptr, Local<Value>(), PropertyHandlerFlags::kNone));
}

bool WrapperLifetimeCanary::Forwards(CanaryKind kind) {
  return kind == CanaryKind::kPlain && PlainCanariesForward();
}

CanaryKind WrapperLifetimeCanary::KindOf(id object) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary ||
      !WrapperLifetime::InScope(object)) {
    return CanaryKind::kNone;
  }
  return IsExtendedInstance(object) ? CanaryKind::kExtended : CanaryKind::kPlain;
}

CanaryKind WrapperLifetimeCanary::NativeInstancesKind() {
  return GetWrapperLifetimeMode() == WrapperLifetimeMode::kCanary &&
                 GetWrapperLifetimeScope() == WrapperLifetimeScope::kAll
             ? CanaryKind::kPlain
             : CanaryKind::kNone;
}

void WrapperLifetimeCanary::Hydrate(Isolate* isolate, Local<Object> wrapper, CanaryKind kind) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary || Forwards(kind)) {
    return;
  }
  HandleScope scope(isolate);
  Local<Object> state;
  if (!ExistingState(isolate, wrapper, &state)) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (context.IsEmpty()) {
    context = Caches::Get(isolate)->GetContext();
  }
  CopyOwnProperties(isolate, context, state, wrapper);
}

void WrapperLifetimeCanary::DropRecord(Isolate* isolate, std::shared_ptr<CanaryRecord> record) {
  if (record == nullptr || !record->forwards || !record->died.load(std::memory_order_acquire)) {
    return;
  }
  record.reset();
  CanaryState* state = Caches::ExistingStateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->orphaned.empty()) {
    return;
  }
  SweepOrphaned(state->registry.get());
}

std::shared_ptr<CanaryRecord> WrapperLifetimeCanary::Find(Isolate* isolate, id object) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->count.load(std::memory_order_relaxed) == 0) {
    return nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(state->registry->mutex);
    auto it = state->registry->records.find((__bridge void*)object);
    if (it == state->registry->records.end()) {
      return nullptr;
    }
    std::shared_ptr<CanaryRecord> record = it->second;
    if (!RetireIfDead(state->registry.get(), it)) {
      record->released = false;
      return record;
    }
  }
  PostDrain(state->registry);
  return nullptr;
}

void WrapperLifetimeCanary::CloseForTeardown(Isolate* isolate) {
  CanaryState* state = Caches::ExistingStateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(state->registry->mutex);
  state->registry->closed = true;
  for (auto& entry : state->registry->records) {
    entry.second->state.Reset();
  }
  for (std::shared_ptr<CanaryRecord>& record : state->registry->dead) {
    record->state.Reset();
  }
  for (std::shared_ptr<CanaryRecord>& record : state->registry->orphaned) {
    record->state.Reset();
  }
}

void WrapperLifetimeCanary::ForEachState(
    Isolate* isolate, const std::function<void(id object, Local<Object> state)>& visit) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || (state->registry->count.load(std::memory_order_relaxed) == 0 &&
                           state->registry->orphaned.empty())) {
    return;
  }
  std::vector<std::pair<id, std::shared_ptr<CanaryRecord>>> live;
  {
    std::lock_guard<std::mutex> lock(state->registry->mutex);
    if (state->registry->closed) {
      return;
    }
    live.reserve(state->registry->records.size());
    for (auto& entry : state->registry->records) {
      const std::shared_ptr<CanaryRecord>& record = entry.second;
      // A dying record's object may already be freed: its superclass's
      // -dealloc runs outside this lock, before the record is retired.
      if (record->state.IsEmpty() || record->died.load(std::memory_order_acquire) ||
          record->dying.load(std::memory_order_acquire) || !record->ObjectAlive()) {
        continue;
      }
      // Only a weak load retains an object whose -dealloc may have started.
      // A record without a weak slot is one whose object's deallocation takes
      // this lock before freeing it, so it is readable here.
      id object = nil;
      if (record->weakSet) {
        object = objc_loadWeakRetained(&record->object);
      } else {
        id weak = nil;
        if (objc_initWeakOrNil(&weak, (__bridge id)entry.first) != nil) {
          object = objc_loadWeakRetained(&weak);
        }
        objc_destroyWeak(&weak);
      }
      if (object != nil) {
        live.emplace_back(object, record);
      }
    }
  }
  // Isolate thread only, as is the list: a record held by a canary has a live
  // object, retained by that canary.
  for (const std::shared_ptr<CanaryRecord>& record : state->registry->orphaned) {
    if (record.use_count() < 2 || record->state.IsEmpty() ||
        record->dying.load(std::memory_order_acquire)) {
      continue;
    }
    live.emplace_back([(__bridge id)record->address retain], record);
  }
  // Read before any visit, whose release can run JS. Only this thread resets
  // state handles.
  std::vector<Local<Object>> states;
  states.reserve(live.size());
  for (const auto& entry : live) {
    states.push_back(entry.second->state.Get(isolate));
  }
  for (size_t i = 0; i < live.size(); i++) {
    visit(live[i].first, states[i]);
  }
}

void WrapperLifetimeCanary::ForEachStateHandle(
    Isolate* isolate, const std::function<void(Local<Object> state)>& visit) {
  CanaryState* state = Caches::ExistingStateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return;
  }
  // Not gated on the live count: dead records outlast it.
  std::vector<Local<Object>> handles;
  {
    std::lock_guard<std::mutex> lock(state->registry->mutex);
    if (state->registry->closed) {
      return;
    }
    for (auto& entry : state->registry->records) {
      if (!entry.second->state.IsEmpty()) {
        handles.push_back(entry.second->state.Get(isolate));
      }
    }
    for (const std::shared_ptr<CanaryRecord>& record : state->registry->dead) {
      if (!record->state.IsEmpty()) {
        handles.push_back(record->state.Get(isolate));
      }
    }
  }
  // Isolate thread only, as is the list.
  for (const std::shared_ptr<CanaryRecord>& record : state->registry->orphaned) {
    if (!record->state.IsEmpty()) {
      handles.push_back(record->state.Get(isolate));
    }
  }
  for (Local<Object> handle : handles) {
    visit(handle);
  }
}

void WrapperLifetimeCanary::ReleaseDeadStates(Isolate* isolate) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  CanaryState* state = Caches::ExistingStateFor<CanaryState>(isolate);
  if (state == nullptr) {
    return;
  }
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
  Sweep(state->registry);
#else
  DrainDead(state->registry);
#endif
}

}  // namespace tns
