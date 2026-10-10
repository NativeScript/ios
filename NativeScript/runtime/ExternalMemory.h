#ifndef ExternalMemory_h
#define ExternalMemory_h

#include <cstddef>

#include "v8-external-memory-accounter.h"
#include "v8.h"

namespace tns {

class BaseDataWrapper;

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

// Forwards the system's memory pressure events to every live isolate.
// Process-wide and idempotent.
void StartMemoryPressureMonitoring();

}  // namespace ExternalMemory

}  // namespace tns

#endif /* ExternalMemory_h */
