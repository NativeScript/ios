//
//  IsolateWrapper.h
//  NativeScript
//
//  Created by Eduardo Speroni on 2/23/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#ifndef IsolateWrapper_h
#define IsolateWrapper_h

#include <type_traits>

#include "Caches.h"
#include "Constants.h"
#include "v8.h"

namespace tns {

// One gate per isolate, keyed by Caches::getGateId() (ids are never reused).
// A thread that has not entered the isolate pins its gate before waiting for
// or holding the isolate's Locker. A pin taken before Close() defers
// Isolate::Dispose until it is released. Once the teardown has closed the
// gate, no wrapper can be reached from JS any more and pins are refused. A
// missing entry reads as closed.
namespace IsolateGates {
void Open(int id);
bool TryPin(int id);
void Unpin(int id);
// Called by the teardown while it holds the isolate's Locker, after the last
// walk that reads wrappers through JS objects.
void Close(int id);
bool IsClosed(int id);
// Drops the entry unless a pin is held; the isolate may be disposed only once
// this returns true.
bool RetireIfUnpinned(int id);
}  // namespace IsolateGates

// Owns a pin for its scope. Declare it before the Locker it guards, so the
// Locker is released first. A thread that has entered the isolate takes no
// pin: an entered isolate stays in use, which already defers its disposal.
class IsolatePin {
 public:
  IsolatePin(int id, bool entered)
      : id_(id),
        pinned_(!entered && IsolateGates::TryPin(id)),
        usable_(entered || pinned_) {}
  ~IsolatePin() {
    if (pinned_) {
      IsolateGates::Unpin(id_);
    }
  }
  IsolatePin(const IsolatePin&) = delete;
  IsolatePin& operator=(const IsolatePin&) = delete;
  explicit operator bool() const { return usable_; }

 private:
  int id_;
  bool pinned_;
  bool usable_;
};

// Kept trivially copyable: ObjC blocks that live as long as the process (the
// extended classes' synthesized methods) capture it by value.
class IsolateWrapper {
public:
    bool IsValid() const;
    inline std::shared_ptr<tns::Caches> GetCache() const {
        return tns::Caches::Get(isolate_);
    }
    inline v8::Isolate* Isolate() { return isolate_; }
    inline IsolateWrapper(v8::Isolate* isolate) {
        isolate_ = isolate;
        gateId_ = tns::Caches::Get(isolate_)->getGateId();
    }
    // Hold the returned pin across any wait for the isolate's Locker from a
    // thread that is not already inside the isolate; an empty pin means the
    // isolate may already be disposed and must not be touched at all.
    inline IsolatePin Pin() const {
      return IsolatePin(gateId_, v8::Isolate::TryGetCurrent() == isolate_);
    }
    // True once the teardown has finished with every wrapper reachable from
    // JS. Read it while pinned.
    inline bool IsTornDown() const { return IsolateGates::IsClosed(gateId_); }

   private:
    v8::Isolate* isolate_;
    int gateId_;
};

static_assert(std::is_trivially_copyable_v<IsolateWrapper>);
}

#endif /* IsolateWrapper_h */
