#pragma once

#include "Caches.h"
#include "Common.h"

namespace tns {

// Base for self-owned C++ objects whose lifetime is bound to a single JS
// object through a weak handle. Instances die in exactly two places: the GC
// finalizer, or SweepAll at isolate teardown — weak callbacks never fire at
// isolate disposal, so anything still registered there must be deleted
// explicitly or it leaks. Never delete a bound instance directly; both
// deletion paths own the registry bookkeeping.
class IsolateTracked {
 public:
  virtual ~IsolateTracked() = default;

  void BindFinalizer(v8::Isolate* isolate,
                     const v8::Local<v8::Object>& object) {
    v8::HandleScope scopedHandle(isolate);
    weakHandle_.Reset(isolate, object);
    weakHandle_.SetWeak(this, Finalizer, v8::WeakCallbackType::kParameter);
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache != nullptr) {
      cache->TrackedInstances.insert(this);
    }
  }

  // Runs in ~Runtime under the Locker, while the isolate is still alive —
  // destructors may Reset v8::Global handles but must not create new ones.
  static void SweepAll(v8::Isolate* isolate) {
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache == nullptr) {
      return;
    }
    // Detach the set first so destructors can't mutate it mid-walk.
    auto survivors = std::move(cache->TrackedInstances);
    cache->TrackedInstances.clear();
    for (IsolateTracked* instance : survivors) {
      delete instance;
    }
  }

 private:
  static void Finalizer(const v8::WeakCallbackInfo<IsolateTracked>& data) {
    IsolateTracked* self = data.GetParameter();
    std::shared_ptr<Caches> cache = Caches::Get(data.GetIsolate());
    if (cache != nullptr) {
      cache->TrackedInstances.erase(self);
    }
    delete self;
  }

  v8::Global<v8::Object> weakHandle_;
};

}  // namespace tns
