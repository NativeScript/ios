//
//  IsolateWrapper.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 8/4/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "IsolateWrapper.h"

#include <dispatch/dispatch.h>

#include <cstdint>
#include <mutex>

#include "NativeScriptPlatform.h"
#include "Runtime.h"
#include "UnfairLock.h"
#include "robin_hood.h"

namespace tns {

bool IsolateWrapper::IsValid() const {
  if (!Runtime::IsAlive(isolate_) ||
      isolate_->GetData(tns::Constants::CACHES_ISOLATE_SLOT) == nullptr) {
    return false;
  }
  std::shared_ptr<Caches> cache = GetCache();
  return cache->IsValid() && cache->getGateId() == gateId_;
}

namespace {

// Runs the teardown from the loop entry, or from the entry's destructor when
// the loop drops it unrun.
struct HandedOffTeardown {
  explicit HandedOffTeardown(std::function<void()> teardown)
      : teardown_(std::move(teardown)) {}
  ~HandedOffTeardown() { Run(); }
  void Run() {
    std::function<void()> teardown = std::move(teardown_);
    teardown_ = nullptr;
    if (teardown) {
      teardown();
    }
  }

 private:
  std::function<void()> teardown_;
};

}  // namespace

bool IsolateWrapper::HandOffTeardown(std::function<void()> teardown) const {
  v8::Isolate* current = v8::Isolate::TryGetCurrent();
  if (current == nullptr || current == isolate_) {
    return false;
  }
  // Keeps the isolate from being disposed while it is examined here.
  IsolatePin pin = Pin();
  if (!pin || v8::Locker::IsLocked(isolate_)) {
    return false;
  }
  std::shared_ptr<EventLoop> loop =
      NativeScriptPlatform::Instance()->LookupEventLoop(isolate_);
  auto pending = std::make_shared<HandedOffTeardown>(std::move(teardown));
  if (loop == nullptr || !loop->PostInternal([pending]() { pending->Run(); })) {
    // A stopped loop can still have an active wrapper walk. Finish from a
    // thread holding no isolate lock, so it may wait for that walk safely.
    dispatch_async_f(
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
        new std::shared_ptr<HandedOffTeardown>(pending), [](void* context) {
          std::unique_ptr<std::shared_ptr<HandedOffTeardown>> entry(
              static_cast<std::shared_ptr<HandedOffTeardown>*>(context));
          (*entry)->Run();
        });
  }
  // The loop may already have run the teardown, which frees this wrapper.
  return true;
}

namespace IsolateGates {

namespace {

struct Gate {
  uint32_t pins = 0;
  bool closed = false;
};

// Trivially destructible, so exit() leaves it usable.
static UnfairMutex gatesMutex;

// Never destroyed: exit() runs static destructors while other threads may
// still be pinning.
robin_hood::unordered_map<int, Gate>& Gates() {
  static auto* gates = new robin_hood::unordered_map<int, Gate>();
  return *gates;
}

}  // namespace

void Open(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  Gates()[id] = Gate();
}

bool TryPin(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  auto it = Gates().find(id);
  if (it == Gates().end() || it->second.closed) {
    return false;
  }
  it->second.pins++;
  return true;
}

void Unpin(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  auto it = Gates().find(id);
  if (it != Gates().end()) {
    it->second.pins--;
  }
}

void Close(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  auto it = Gates().find(id);
  if (it != Gates().end()) {
    it->second.closed = true;
  }
}

bool IsClosed(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  auto it = Gates().find(id);
  return it == Gates().end() || it->second.closed;
}

bool RetireIfUnpinned(int id) {
  std::lock_guard<UnfairMutex> lock(gatesMutex);
  auto it = Gates().find(id);
  if (it == Gates().end()) {
    return true;
  }
  if (it->second.pins > 0) {
    return false;
  }
  Gates().erase(it);
  return true;
}

}  // namespace IsolateGates
}
