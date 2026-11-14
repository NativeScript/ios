#ifndef ExternalMemory_h
#define ExternalMemory_h

#include <objc/objc.h>
#include <pthread.h>

#include <atomic>
#include <cstddef>
#include <memory>
#include <vector>

#include "v8-external-memory-accounter.h"
#include "v8.h"

namespace tns {

class BaseDataWrapper;
class Caches;
class ObjCDataWrapper;

// Native bytes a wrapper keeps alive, reported to V8 so the collector weighs
// them when scheduling collections. The wrapper owns it, so the bytes are
// returned whenever the wrapper is deleted, from whichever path deletes it.
//
// Releasing is safe from any thread and after the isolate is gone: it pins
// the isolate's gate instead of taking its Locker (the decrease is a single
// atomic in V8 and never collects), and once the gate is closed the isolate
// is being disposed and the bytes are dropped with it.
class ExternalMemoryCharge {
 public:
  ExternalMemoryCharge(v8::Isolate* isolate, int gateId)
      : isolate_(isolate), gateId_(gateId) {}
  ~ExternalMemoryCharge();
  ExternalMemoryCharge(const ExternalMemoryCharge&) = delete;
  ExternalMemoryCharge& operator=(const ExternalMemoryCharge&) = delete;

  size_t Bytes() const { return bytes_; }
  v8::Isolate* Isolate() const { return isolate_; }

  // Isolate thread only: an increase can run a collection before returning.
  void Set(size_t bytes);

 private:
  v8::Isolate* isolate_;
  int gateId_;
  size_t bytes_ = 0;
  v8::ExternalMemoryAccounter accounter_;
};

namespace ExternalMemory {

// Replaces the bytes `wrapper` reports for `isolate`; 0 drops the charge.
// Isolate thread only. A wrapper charged for another isolate keeps its charge.
void SetSize(v8::Isolate* isolate, BaseDataWrapper* wrapper, size_t bytes);

// Charges an estimate of the native footprint of the ObjC or CF object that
// `value` wraps, unless it already carries a charge or its class has no
// estimator. Only call it for objects JS plausibly holds the last reference
// to: collecting the wrapper of an object that native code also retains frees
// nothing, so charging it only buys collections that cannot pay off.
void ChargeEstimatedSize(v8::Isolate* isolate, v8::Local<v8::Value> value);

// Objects that reached JS at +0 (a block or override argument, an instance
// method's return) whose class has an estimator. Native code still holds such
// an object while the call that handed it over runs, and lets go once that
// call returns or its autorelease pool drains. Each candidate is checked
// exactly once after that point, from the home thread's run loop, and charged
// if no retain other than JS's own is left; one native still holds then is
// never charged, even after native lets go. Worker threads drain no
// autorelease pool per run loop pass, so on a worker only objects their native
// caller releases outright can qualify.
//
// Guarded by the isolate's Locker, except NextDueMs, which the run loop
// observer reads before deciding whether to take the Locker at all.
class SoleOwnerCandidates {
 public:
  // The thread whose run loop runs the checks. Runtime::Init, on that thread.
  void BindToCurrentThread() { homeThread_ = pthread_self(); }

  // When the earliest candidate becomes checkable (NowMs units), or infinity.
  double NextDueMs() const {
    return nextDueMs_.load(std::memory_order_acquire);
  }

 private:
  struct Candidate {
    id object;
    Class klass;
    uint8_t estimator;
    // The registry handle of the wrapper's JS object. Collection or an
    // explicit release empties it, and holding it never keeps the object.
    std::shared_ptr<v8::Persistent<v8::Value>> handle;
    double dueMs;
  };

  friend void RecordSoleOwnerCandidate(
      v8::Isolate*, Caches*, ObjCDataWrapper*,
      const std::shared_ptr<v8::Persistent<v8::Value>>&);
  friend void ChargeSoleOwners(v8::Isolate*, Caches*);
  friend void ChargeEstimatedSize(v8::Isolate*, v8::Local<v8::Value>);

  // The checks only run when the home run loop is about to sleep. A loop idling
  // between foreign callbacks would never get there, so a no-op internal post
  // makes it run one more pass no earlier than `dueMs`.
  void EnsureWake(v8::Isolate* isolate, double dueMs, double now);

  pthread_t homeThread_ = nullptr;
  std::vector<Candidate> candidates_;
  std::atomic<double> nextDueMs_{__builtin_inf()};
  // Fire time of the last wake posted for candidates recorded off the home
  // thread. Another is posted for a candidate this one fires before, or too
  // long after.
  double wakeAtMs_ = -1;
};

// Records the object of a wrapper just created for a +0 object as a candidate
// for a deferred charge (see SoleOwnerCandidates). Does nothing for classes
// without an estimator or once the bounded list is full. Isolate entered.
void RecordSoleOwnerCandidate(
    v8::Isolate* isolate, Caches* cache, ObjCDataWrapper* wrapper,
    const std::shared_ptr<v8::Persistent<v8::Value>>& handle);

// Checks the candidates that are due and charges those the wrapper alone
// still retains. Home thread, isolate entered, before teardown starts.
void ChargeSoleOwners(v8::Isolate* isolate, Caches* cache);

// Forwards the system's memory pressure events to every live isolate.
// Process-wide and idempotent.
void StartMemoryPressureMonitoring();

}  // namespace ExternalMemory

}  // namespace tns

#endif /* ExternalMemory_h */
