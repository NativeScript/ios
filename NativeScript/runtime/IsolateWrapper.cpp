//
//  IsolateWrapper.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 8/4/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "IsolateWrapper.h"

#include <cstdint>
#include <mutex>

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
