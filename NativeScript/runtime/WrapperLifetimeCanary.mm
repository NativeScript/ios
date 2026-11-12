#include "WrapperLifetimeCanary.h"
#import <Foundation/Foundation.h>
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
#include "WrapperLifetime.h"

using namespace v8;

namespace tns {

// A native object's state in one isolate, shared by the registry and the
// object's live canary. Its token's -dealloc marks it died: normally when the
// object is deallocated, but objc_removeAssociatedObjects can release the token
// of a live object, whose canary then sees no state and starts a new record on
// its next write. Teardown empties the handle.
struct CanaryRecord {
  Global<Object> state;
  std::atomic<bool> died{false};
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
  // Lets wrapper creation skip the lookup while no object has state.
  std::atomic<size_t> count{0};
  Isolate* isolate = nullptr;
  std::weak_ptr<EventLoop> loop;
  // The association key: one per isolate, and never reused while a token
  // keeps this registry alive.
  char associationKey = 0;
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

// From the token's -dealloc, on whichever thread deallocates the object.
void NativeDied(const std::shared_ptr<CanaryRegistry>& registry, void* object) {
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

std::shared_ptr<CanaryRegistry> RegistryFor(Isolate* isolate) {
  CanaryState* state = Caches::StateFor<CanaryState>(isolate);
  return state != nullptr ? state->registry : nullptr;
}

}  // namespace

}  // namespace tns

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

// The record's state is usable: its token is alive and teardown has not
// emptied it. Handles are only reset under the Locker these callers hold.
bool Usable(const std::shared_ptr<CanaryRecord>& record) {
  return record != nullptr && !record->died.load(std::memory_order_acquire) &&
         !record->state.IsEmpty();
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
    bool created = false;
    {
      std::lock_guard<std::mutex> lock(registry->mutex);
      if (registry->closed) {
        return false;
      }
      std::shared_ptr<CanaryRecord>& slot = registry->records[(__bridge void*)object];
      if (slot == nullptr) {
        slot = std::make_shared<CanaryRecord>();
        slot->state.Reset(isolate, Object::New(isolate, Null(isolate), nullptr, nullptr, 0));
        registry->count.fetch_add(1, std::memory_order_relaxed);
        created = true;
      }
      canary->canaryRecord_ = slot;
    }
    if (created) {
      TNSCanaryLifecycleToken* token = [[TNSCanaryLifecycleToken alloc] init];
      token->registry_ = registry;
      token->object_ = (__bridge void*)object;
      objc_setAssociatedObject(object, &registry->associationKey, token,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      [token release];
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
  return it != state->registry->records.end() ? it->second : nullptr;
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
