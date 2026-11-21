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
  // The weak collections' key for a native object hangs off its state, and
  // names the object it stands for. A released canary holds a copy.
  Global<Private> keyOfState;
  Global<Private> objectOfKey;
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
#if NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION
    if (!extended && ForbidsAssociatedObjects(object)) {
      return false;
    }
#endif
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
        if (!record->reportsDeath) {
          if (objc_initWeakOrNil(&record->object, object) == nil) {
            // The class refuses weak references.
            registry->records.erase((__bridge void*)object);
            return false;
          }
          record->weakSet = true;
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

// unwrap(value, create): the weak collections' key for a canary's native
// object, a frozen, null-prototype object that lives as long as the object's
// state, that is, until the native object is deallocated, or as long as a
// released canary of the object holding a copy. Lookups pass
// `create` false and never make one: with no key yet, no entry can be keyed by
// it. The value itself for anything that is not a canary, a Proxy included (it
// is a key of its own, as in every other mode).
void UnwrapCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> value = info[0];
  bool create = info[1]->IsTrue();
  info.GetReturnValue().Set(value);
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  Local<Object> state;
  if (canaryState == nullptr || !value->IsObject() || value->IsProxy()) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Private> keyOfState = canaryState->keyOfState.Get(isolate);
  Local<Value> key;
  if (create ? !StateForWrite(isolate, value.As<Object>(), &state)
             : !ExistingState(isolate, value.As<Object>(), &state)) {
    // A released canary keeps its key itself, or null when it had none
    // (KeepWeakCollectionKey).
    if (value.As<Object>()->InternalFieldCount() == 0 ||
        !value.As<Object>()->GetPrivate(context, keyOfState).ToLocal(&key)) {
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
  return v8::Function::New(context, UnwrapCallback).ToLocal(&unwrap) &&
         v8::Function::New(context, WrapCallback).ToLocal(&wrap) &&
         binding->Set(context, tns::ToV8String(isolate, "unwrap"), unwrap).FromMaybe(false) &&
         binding->Set(context, tns::ToV8String(isolate, "wrap"), wrap).FromMaybe(false);
}

void WrapperLifetimeCanary::KeepWeakCollectionKey(Isolate* isolate, Local<Object> canary,
                                                  const std::shared_ptr<CanaryRecord>& record) {
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  if (canaryState == nullptr || canaryState->keyOfState.IsEmpty()) {
    return;
  }
  HandleScope scope(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  Local<Private> keyOfState = canaryState->keyOfState.Get(isolate);
  Local<Value> copy = v8::Null(isolate);
  if (Usable(record)) {
    record->released = true;
    Local<Value> key;
    if (Local<Object>::New(isolate, record->state)->GetPrivate(context, keyOfState).ToLocal(&key) &&
        key->IsObject()) {
      copy = key;
    }
  }
  // Private symbols bypass the canary's handlers.
  (void)canary->SetPrivate(context, keyOfState, copy);
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
  instanceTemplate->SetHandler(
      NamedPropertyHandlerConfiguration(nullptr, Setter, nullptr, Deleter, nullptr, Definer,
                                        nullptr, Local<Value>(), PropertyHandlerFlags::kNone));
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
}

void WrapperLifetimeCanary::ForEachState(
    Isolate* isolate, const std::function<void(id object, Local<Object> state)>& visit) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->count.load(std::memory_order_relaxed) == 0) {
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

}  // namespace tns
