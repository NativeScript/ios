#include "WrapperLifetimeCanary.h"
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>
#include "Caches.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "ObjectManager.h"
#include "Runtime.h"
#import "TNSDerivedClass.h"
#include "WrapperLifetime.h"

// How canary mode learns that a native object with state was deallocated, so
// its state can be let go of. Instances of JS-extended classes are reported by
// their class's own -dealloc (InstallDeallocHook) either way; for others:
// - ASSOCIATION: a token associated with the object reports it from its
//   -dealloc, immediately and on any thread. The ObjC runtime aborts the
//   process for a class that forbids associated objects (no public query).
// - WEAK_SWEEP: each record holds a weak reference to the object, checked by a
//   sweep after every major collection, so state lingers until then. Classes
//   that refuse weak references keep their JS properties on the canary.
#define NS_CANARY_DEATH_ASSOCIATION 1
#define NS_CANARY_DEATH_WEAK_SWEEP 2
#ifndef NS_CANARY_DEATH_SIGNAL
#define NS_CANARY_DEATH_SIGNAL NS_CANARY_DEATH_ASSOCIATION
#endif

#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
extern "C" id objc_initWeakOrNil(id* location, id value);
#endif
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
  // deallocated, on any thread. Set for records nothing reports.
  id object = nil;

  ~CanaryRecord() { objc_destroyWeak(&object); }

  // A racy read is enough: the slot only goes from the object to nil, and is
  // never dereferenced here.
  bool ObjectAlive() const {
    return reportsDeath ||
           __atomic_load_n(reinterpret_cast<void* const*>(&object), __ATOMIC_ACQUIRE) != nullptr;
  }
};

namespace {

// Per-isolate. Shared with the tokens associated with native objects, which
// can be deallocated on any thread and after the isolate is gone.
struct CanaryRegistry {
  std::mutex mutex;
  std::unordered_map<void*, std::shared_ptr<CanaryRecord>> records;
  // Records whose token was deallocated; their handles are reset on the
  // runtime's thread.
  std::vector<std::shared_ptr<CanaryRecord>> dead;
  bool closed = false;
  bool drainPosted = false;
  bool sweepPosted = false;
  // Lets wrapper creation skip the lookup while no object has state.
  std::atomic<size_t> count{0};
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
};

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
  ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(registry->isolate);
  for (std::shared_ptr<CanaryRecord>& record : dead) {
    record->state.Reset();
    if (stats != nullptr) {
      stats->canaryNativeDeaths++;
    }
  }
}

// From a reporter's -dealloc, on whichever thread deallocates the object.
void NativeDied(const std::shared_ptr<CanaryRegistry>& registry, void* object) {
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
    if (it == registry->records.end()) {
      return;
    }
    // Erased now, inside the object's -dealloc: an object later allocated at
    // this address must not find this record.
    it->second->died.store(true, std::memory_order_release);
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

// After it returned: retires each record by identity. A record a new object at
// the address already displaced (RetireIfDead) is gone from the map.
void ReportDyingRecordsDied(const DyingRecords& dying, void* object) {
  for (const auto& [registry, record] : dying) {
    {
      std::lock_guard<std::mutex> lock(registry->mutex);
      auto it = registry->records.find(object);
      if (registry->closed || it == registry->records.end() || it->second != record) {
        continue;
      }
    }
    NativeDied(registry, object);
  }
}

// Not a message: a root class without -conformsToProtocol: would crash under
// scope "all". Walks the superclasses for key-value observing's subclass.
bool IsExtendedInstance(id object) {
  for (Class cls = object_getClass(object); cls != nil; cls = class_getSuperclass(cls)) {
    if (class_conformsToProtocol(cls, @protocol(TNSDerivedClass))) {
      return true;
    }
  }
  return false;
}

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
  ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(registry->isolate);
  for (std::shared_ptr<CanaryRecord>& record : dead) {
    record->state.Reset();
    if (stats != nullptr) {
      stats->canaryNativeDeaths++;
    }
  }
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
// they are reached through as `this`.
void CopyOwnProperties(Isolate* isolate, Local<Context> context, Local<Object> from,
                       Local<Object> to) {
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
    // The record died under a live canary (its token was removed): the
    // canary's properties seed the new state.
    bool replacesDied = canary->canaryRecord_ != nullptr;
    // A JS-extended class's own -dealloc reports its instances' deaths.
    bool extended = IsExtendedInstance(object);
    // Allocated before the lock: a collection this allocation starts can run
    // callbacks (the weak sweep's, a finalizer's -dealloc) that take it.
    Local<Object> freshState = Object::New(isolate, Null(isolate), nullptr, nullptr, 0);
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
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_WEAK_SWEEP
        if (!record->reportsDeath && objc_initWeakOrNil(&record->object, object) == nil) {
          // The class refuses weak references.
          registry->records.erase((__bridge void*)object);
          return false;
        }
#endif
        record->state.Reset(isolate, freshState);
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
      if (ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate)) {
        stats->canaryStates++;
      }
      if (replacesDied) {
        CopyOwnProperties(isolate, isolate->GetCurrentContext(), holder, freshState);
      }
    } else if (Usable(canary->canaryRecord_)) {
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

// The handlers mirror: each copies its write into the state and declines, so
// V8 also applies it to the canary, where reads find a real own property and
// never call into C++. There is no getter, query, enumerator or descriptor
// callback for the same reason. The handlers are masking, so they also see
// names the prototype chain has. After the setter declines, V8 adds a new name
// to the canary without calling the definer, so the setter itself decides what
// becomes state.
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
    if ((attributes & ReadOnly) != 0) {
      return Intercepted::kNo;
    }
    Local<Object> owner = OwnerOf(context, holder, property);
    if (owner.IsEmpty() || owner->HasRealNamedCallbackProperty(context, property).FromMaybe(true)) {
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

void WrapperLifetimeCanary::ConfigureInstanceTemplate(Local<ObjectTemplate> instanceTemplate) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  instanceTemplate->SetHandler(
      NamedPropertyHandlerConfiguration(nullptr, Setter, nullptr, Deleter, nullptr, Definer,
                                        nullptr, Local<Value>(), PropertyHandlerFlags::kNone));
}

bool WrapperLifetimeCanary::Intercepts(id object) {
  return GetWrapperLifetimeMode() == WrapperLifetimeMode::kCanary &&
         WrapperLifetime::InScope(object);
}

bool WrapperLifetimeCanary::NativeInstancesIntercept() {
  return GetWrapperLifetimeMode() == WrapperLifetimeMode::kCanary &&
         GetWrapperLifetimeScope() == WrapperLifetimeScope::kAll;
}

void WrapperLifetimeCanary::Hydrate(Isolate* isolate, Local<Object> wrapper) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
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
}

}  // namespace tns
