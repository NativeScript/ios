#include "WrapperLifetimeCanary.h"
#import <Foundation/Foundation.h>
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
  // Something reports this object's deallocation: a JS-extended class's
  // -dealloc, or the associated token. Otherwise only the weak reference below
  // tells, when a sweep reads it.
  bool reportsDeath = false;
  // An ObjC weak reference to the object, zeroed by the runtime when it is
  // deallocated, on any thread. Set for records nothing reports, and for any
  // record whose object became a weak-collection key (Wrap reads it).
  id object = nil;
  bool weakSet = false;

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
  // names the object it stands for.
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

void ReportDeallocToAllRegistries(void* object) {
  std::vector<std::shared_ptr<CanaryRegistry>> live;
  {
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
  }
  for (const std::shared_ptr<CanaryRegistry>& registry : live) {
    NativeDied(registry, object);
  }
}

bool IsExtendedInstance(id object) {
  return [object_getClass(object) conformsToProtocol:@protocol(TNSDerivedClass)];
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
void RetireIfDead(CanaryRegistry* registry,
                  std::unordered_map<void*, std::shared_ptr<CanaryRecord>>::iterator it) {
  if (it->second->ObjectAlive()) {
    return;
  }
  it->second->died.store(true, std::memory_order_release);
  registry->dead.push_back(std::move(it->second));
  registry->records.erase(it);
  registry->count.fetch_sub(1, std::memory_order_relaxed);
}

// The state object of the holder, if it has one.
bool ExistingState(Isolate* isolate, Local<Object> holder, Local<Object>* out) {
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  if (canary == nullptr || !Usable(canary->canaryRecord_)) {
    return false;
  }
  *out = Local<Object>::New(isolate, canary->canaryRecord_->state);
  return true;
}

// The state object of the holder, created on its first write.
bool StateForWrite(Isolate* isolate, Local<Object> holder, Local<Object>* out) {
  ObjectWeakCallbackState* canary = CanaryOf(isolate, holder);
  if (canary == nullptr) {
    return false;
  }
  if (canary->canaryRecord_ == nullptr || canary->canaryRecord_->died.load(std::memory_order_acquire)) {
    std::shared_ptr<CanaryRegistry> registry = RegistryFor(isolate);
    if (registry == nullptr) {
      return false;
    }
    if (registry->loop.expired()) {
      if (Runtime* runtime = Runtime::GetRuntime(isolate)) {
        registry->loop = runtime->GetEventLoop();
      }
    }
    id object = canary->lifetimeTarget_;
    // A JS-extended class's own -dealloc reports its instances' deaths.
    bool extended = IsExtendedInstance(object);
    bool created = false;
    {
      std::lock_guard<std::mutex> lock(registry->mutex);
      if (registry->closed) {
        return false;
      }
      auto existing = registry->records.find((__bridge void*)object);
      if (existing != registry->records.end()) {
        RetireIfDead(registry.get(), existing);
      }
      std::shared_ptr<CanaryRecord>& slot = registry->records[(__bridge void*)object];
      if (slot == nullptr) {
        auto record = std::make_shared<CanaryRecord>();
        record->reportsDeath = extended || NS_CANARY_DEATH_SIGNAL == NS_CANARY_DEATH_ASSOCIATION;
        if (!record->reportsDeath) {
          if (objc_initWeakOrNil(&record->object, object) == nil) {
            // The class refuses weak references.
            registry->records.erase((__bridge void*)object);
            return false;
          }
          record->weakSet = true;
        }
        record->state.Reset(isolate, Object::New(isolate, Null(isolate), nullptr, nullptr, 0));
        slot = std::move(record);
        registry->count.fetch_add(1, std::memory_order_relaxed);
        created = true;
      }
      canary->canaryRecord_ = slot;
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

Intercepted Getter(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ExistingState(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (!HasOwn(context, state, property)) {
    return Intercepted::kNo;
  }
  Local<Value> value;
  // An accessor defined through the canary runs with the canary as `this`
  // (interceptors do not see the receiver, only the holder).
  if (state->Get(context, property, info.Holder()).ToLocal(&value)) {
    info.GetReturnValue().Set(value);
  }
  return Intercepted::kYes;
}

Intercepted Setter(Local<v8::Name> property, Local<Value> value,
                   const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!StateForWrite(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Maybe<bool> result = state->HasRealNamedCallbackProperty(context, property).FromMaybe(false)
                           ? state->Set(context, property, value, info.Holder())
                           : state->Set(context, property, value);
  if (result.IsJust()) {
    info.GetReturnValue().Set(result.FromJust());
  }
  return Intercepted::kYes;
}

Intercepted Query(Local<v8::Name> property, const PropertyCallbackInfo<v8::Integer>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ExistingState(isolate, info.Holder(), &state)) {
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

Intercepted Deleter(Local<v8::Name> property, const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ExistingState(isolate, info.Holder(), &state)) {
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

void Enumerator(const PropertyCallbackInfo<v8::Array>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ExistingState(isolate, info.Holder(), &state)) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Array> names;
  if (state
          ->GetPropertyNames(context, KeyCollectionMode::kOwnOnly, PropertyFilter::ALL_PROPERTIES,
                             IndexFilter::kSkipIndices)
          .ToLocal(&names)) {
    info.GetReturnValue().Set(names);
  }
}

Intercepted Definer(Local<v8::Name> property, const PropertyDescriptor& descriptor,
                    const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!StateForWrite(isolate, info.Holder(), &state)) {
    return Intercepted::kNo;
  }
  Local<Context> context = isolate->GetCurrentContext();
  bool defined;
  if (state->DefineProperty(context, property, const_cast<PropertyDescriptor&>(descriptor))
          .To(&defined)) {
    info.GetReturnValue().Set(defined);
  }
  return Intercepted::kYes;
}

Intercepted Descriptor(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Object> state;
  if (!ExistingState(isolate, info.Holder(), &state)) {
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
// Posts a sweep after each major collection: dead objects' weak references are
// zeroed by then. Only posts; the GC is no place to reset handles.
void PostSweepAfterGC(Isolate* isolate, GCType, GCCallbackFlags) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->count.load(std::memory_order_relaxed) == 0) {
    return;
  }
  std::shared_ptr<CanaryRegistry> registry = state->registry;
  std::shared_ptr<EventLoop> loop = registry->loop.lock();
  {
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->sweepPosted || loop == nullptr) {
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

// The weak collections' key for a canary's native object: a frozen,
// null-prototype object that lives exactly as long as the object's state, that
// is, until the native object is deallocated. The holder itself for anything
// that is not a canary.
void UnwrapCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> value = info[0];
  info.GetReturnValue().Set(value);
  CanaryState* canaryState = Caches::StateFor<CanaryState>(isolate);
  Local<Object> state;
  if (canaryState == nullptr || !value->IsObject() ||
      !StateForWrite(isolate, value.As<Object>(), &state)) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Private> keyOfState = canaryState->keyOfState.Get(isolate);
  Local<Value> key;
  if (state->GetPrivate(context, keyOfState).ToLocal(&key) && key->IsObject()) {
    info.GetReturnValue().Set(key);
    return;
  }
  ObjectWeakCallbackState* canary = CanaryOf(isolate, value.As<Object>());
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
  isolate->AddGCPrologueCallback(
      PostSweepAfterGC, static_cast<GCType>(kGCTypeMarkSweepCompact | kGCTypeIncrementalMarking));
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
  IMP dealloc = imp_implementationWithBlock(^(id self) {
    ReportDeallocToAllRegistries((__bridge void*)self);
    struct objc_super super = {.receiver = self, .super_class = superclass};
    reinterpret_cast<void (*)(struct objc_super*, SEL)>(objc_msgSendSuper)(&super,
                                                                           @selector(dealloc));
  });
  class_addMethod(extendedClass, @selector(dealloc), dealloc, "v@:");
}

void WrapperLifetimeCanary::ConfigureInstanceTemplate(Local<ObjectTemplate> instanceTemplate) {
  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  instanceTemplate->SetHandler(NamedPropertyHandlerConfiguration(
      Getter, Setter, Query, Deleter, Enumerator, Definer, Descriptor, Local<Value>(),
      PropertyHandlerFlags::kNonMasking));
}

std::shared_ptr<CanaryRecord> WrapperLifetimeCanary::Find(Isolate* isolate, id object) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  if (state == nullptr || state->registry->count.load(std::memory_order_relaxed) == 0) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(state->registry->mutex);
  auto it = state->registry->records.find((__bridge void*)object);
  if (it == state->registry->records.end()) {
    return nullptr;
  }
  std::shared_ptr<CanaryRecord> record = it->second;
  RetireIfDead(state->registry.get(), it);
  return record->ObjectAlive() ? record : nullptr;
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
