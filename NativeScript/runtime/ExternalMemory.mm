#include "ExternalMemory.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <algorithm>

#include "Caches.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "IsolateWrapper.h"
#include "NSDataAdapter.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

ExternalMemoryCharge::~ExternalMemoryCharge() {
  if (bytes_ == 0) {
    return;
  }
  // A closed gate means the isolate is being disposed, which drops its
  // external memory total with it.
  if (IsolateGates::TryPin(gateId_)) {
    accounter_.Decrease(isolate_, bytes_);
    IsolateGates::Unpin(gateId_);
  }
}

void ExternalMemoryCharge::Set(size_t bytes) {
  if (bytes > bytes_) {
    accounter_.Increase(isolate_, bytes - bytes_);
  } else if (bytes < bytes_) {
    accounter_.Decrease(isolate_, bytes_ - bytes);
  }
  bytes_ = bytes;
}

namespace ExternalMemory {

namespace {

// Values of Caches::ExternalSizeEstimators.
enum Estimator : uint8_t {
  kNone,
  kNSData,
  kUIImage,
  // Toll-free bridged CF instances all share one class, so the estimator is
  // picked per object from its CFTypeID.
  kCFType,
};

typedef CFTypeID (*TypeIDFn)(void);
typedef size_t (*SizeOfFn)(CFTypeRef);

// Resolved at runtime so the runtime does not link CoreGraphics or CoreVideo
// itself; apps that never load them simply get no estimate.
struct CFEstimators {
  TypeIDFn cgImageTypeID = nullptr;
  SizeOfFn cgImageBytesPerRow = nullptr;
  SizeOfFn cgImageHeight = nullptr;
  TypeIDFn pixelBufferTypeID = nullptr;
  SizeOfFn pixelBufferDataSize = nullptr;
};

const CFEstimators& GetCFEstimators() {
  static CFEstimators estimators = [] {
    CFEstimators e;
    e.cgImageTypeID = (TypeIDFn)dlsym(RTLD_DEFAULT, "CGImageGetTypeID");
    e.cgImageBytesPerRow = (SizeOfFn)dlsym(RTLD_DEFAULT, "CGImageGetBytesPerRow");
    e.cgImageHeight = (SizeOfFn)dlsym(RTLD_DEFAULT, "CGImageGetHeight");
    e.pixelBufferTypeID = (TypeIDFn)dlsym(RTLD_DEFAULT, "CVPixelBufferGetTypeID");
    e.pixelBufferDataSize = (SizeOfFn)dlsym(RTLD_DEFAULT, "CVPixelBufferGetDataSize");
    return e;
  }();
  return estimators;
}

size_t CGImageSize(CFTypeRef image) {
  const CFEstimators& e = GetCFEstimators();
  if (image == nullptr || e.cgImageBytesPerRow == nullptr || e.cgImageHeight == nullptr) {
    return 0;
  }
  return e.cgImageBytesPerRow(image) * e.cgImageHeight(image);
}

Estimator ResolveEstimator(Class klass) {
  // NSDataAdapter exposes bytes of a JS buffer that V8 already accounts for.
  if ([klass isSubclassOfClass:[NSDataAdapter class]]) {
    return kNone;
  }
  if ([klass isSubclassOfClass:[NSData class]]) {
    return kNSData;
  }
  static Class uiImageClass = objc_getClass("UIImage");
  if (uiImageClass != nil && [klass isSubclassOfClass:uiImageClass]) {
    return kUIImage;
  }
  static Class cfTypeClass = objc_getClass("__NSCFType");
  if (cfTypeClass != nil && klass == cfTypeClass) {
    return kCFType;
  }
  return kNone;
}

size_t Estimate(Estimator estimator, id obj) {
  switch (estimator) {
    case kNSData:
      return [(NSData*)obj length];
    case kUIImage: {
      // UIKit is not linked by the runtime, so its selectors are registered
      // rather than declared. A symbol image rasterizes on -CGImage, and one
      // backed by a CIImage has no bitmap until it is rendered (NULL here).
      static SEL isSymbolImage = sel_registerName("isSymbolImage");
      static SEL cgImage = sel_registerName("CGImage");
      if ([obj respondsToSelector:isSymbolImage] &&
          ((BOOL (*)(id, SEL))objc_msgSend)(obj, isSymbolImage)) {
        return 0;
      }
      return CGImageSize(((CFTypeRef (*)(id, SEL))objc_msgSend)(obj, cgImage));
    }
    case kCFType: {
      const CFEstimators& e = GetCFEstimators();
      CFTypeID type = CFGetTypeID((CFTypeRef)obj);
      if (e.cgImageTypeID != nullptr && type == e.cgImageTypeID()) {
        return CGImageSize((CFTypeRef)obj);
      }
      if (e.pixelBufferTypeID != nullptr && e.pixelBufferDataSize != nullptr &&
          type == e.pixelBufferTypeID()) {
        return e.pixelBufferDataSize((CFTypeRef)obj);
      }
      return 0;
    }
    case kNone:
      return 0;
  }
  return 0;
}

Estimator EstimatorFor(Caches* cache, Class klass) {
  auto& estimators = cache->ExternalSizeEstimators;
  auto it = estimators.find(klass);
  if (it != estimators.end()) {
    return static_cast<Estimator>(it->second);
  }
  Estimator estimator = ResolveEstimator(klass);
  estimators.emplace(klass, estimator);
  return estimator;
}

}  // namespace

void SetSize(Isolate* isolate, BaseDataWrapper* wrapper, size_t bytes) {
  ExternalMemoryCharge* charge = wrapper->ExternalCharge();
  if (charge == nullptr) {
    if (bytes == 0) {
      return;
    }
    auto created =
        std::make_unique<ExternalMemoryCharge>(isolate, Caches::Get(isolate)->getGateId());
    charge = created.get();
    wrapper->SetExternalCharge(std::move(created));
  } else if (charge->Isolate() != isolate) {
    return;
  }
  charge->Set(bytes);
}

void ChargeEstimatedSize(Isolate* isolate, Local<Value> value) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject ||
      wrapper->ExternalCharge() != nullptr) {
    return;
  }
  ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
  id obj = objcWrapper->Data();
  if (obj == nil) {
    return;
  }

  Caches* cache = Caches::Get(isolate).get();
  Estimator estimator = EstimatorFor(cache, objcWrapper->Klass());
  if (estimator == kNone) {
    return;
  }

  // Wrapping the object just recorded it as a +0 candidate; drop that entry
  // so owned objects do not use up the bounded list.
  auto& candidates = cache->SoleOwnerCandidates.candidates_;
  if (!candidates.empty() && candidates.back().object == obj) {
    candidates.pop_back();
  }

  SetSize(isolate, wrapper, Estimate(estimator, obj));
}

namespace {

// Bounds the list between two checks. A burst beyond it goes uncharged.
constexpr size_t kMaxSoleOwnerCandidates = 4096;

// How long a candidate recorded off the home thread waits before its check.
// Its native caller runs on that other thread and lets go on its own
// schedule, after the callback returns or once that thread's pool drains, so
// there is no point the home thread could observe; a frame is long enough for
// both in practice.
constexpr double kForeignSettleMs = 16;

// How late a wake may fire for a candidate, so that callbacks arriving within
// this window of each other share one wake.
constexpr double kWakeCoalesceMs = 4;
}  // namespace

void RecordSoleOwnerCandidate(Isolate* isolate, Caches* cache, ObjCDataWrapper* wrapper,
                              const std::shared_ptr<Persistent<Value>>& handle) {
  Estimator estimator = EstimatorFor(cache, wrapper->Klass());
  if (estimator == kNone) {
    return;
  }
  SoleOwnerCandidates& candidates = cache->SoleOwnerCandidates;
  if (candidates.candidates_.size() >= kMaxSoleOwnerCandidates) {
    return;
  }

  bool onHomeThread = pthread_equal(pthread_self(), candidates.homeThread_);
  double now = onHomeThread ? 0 : EventLoop::NowMs();
  double dueMs = onHomeThread ? 0 : now + kForeignSettleMs;
  candidates.candidates_.push_back({wrapper->Data(), wrapper->Klass(), estimator, handle, dueMs});
  if (dueMs < candidates.NextDueMs()) {
    candidates.nextDueMs_.store(dueMs, std::memory_order_release);
  }
  if (!onHomeThread) {
    candidates.EnsureWake(isolate, dueMs, now);
  }
}

void ChargeSoleOwners(Isolate* isolate, Caches* cache) {
  SoleOwnerCandidates& candidates = cache->SoleOwnerCandidates;
  if (candidates.candidates_.empty()) {
    return;
  }

  double now = EventLoop::NowMs();
  if (candidates.NextDueMs() > now) {
    return;
  }
  // Charging below can collect, and finalizers can run code that records new
  // candidates, so the due ones leave the list before any is charged.
  auto firstWaiting =
      std::partition(candidates.candidates_.begin(), candidates.candidates_.end(),
                     [now](const SoleOwnerCandidates::Candidate& c) { return c.dueMs <= now; });
  std::vector<SoleOwnerCandidates::Candidate> due(
      std::make_move_iterator(candidates.candidates_.begin()),
      std::make_move_iterator(firstWaiting));
  candidates.candidates_.erase(candidates.candidates_.begin(), firstWaiting);
  double nextDueMs = __builtin_inf();
  for (const auto& c : candidates.candidates_) {
    nextDueMs = std::min(nextDueMs, c.dueMs);
  }
  candidates.nextDueMs_.store(nextDueMs, std::memory_order_release);
  if (nextDueMs != __builtin_inf()) {
    candidates.EnsureWake(isolate, nextDueMs, now);
  }

  for (SoleOwnerCandidates::Candidate& c : due) {
    if (isolate->IsExecutionTerminating()) {
      return;
    }
    if (c.handle->IsEmpty()) {
      continue;
    }
    // Keeps the object alive while charging: an increase can collect.
    HandleScope handleScope(isolate);
    Local<Value> value = c.handle->Get(isolate);
    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject ||
        wrapper->ExternalCharge() != nullptr) {
      continue;
    }
    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    // A wrapper still attached to a live object owns its retain, so the object
    // can be read from here on.
    if (objcWrapper->Data() != c.object || objcWrapper->Klass() != c.klass) {
      continue;
    }
    // JS's retains are the wrapper's own plus one per interop.bufferFromData
    // buffer. Such a buffer's bytes are then weighed twice, by V8 and by this
    // charge, until it dies; V8 counting the buffer alone never brings the
    // collection that frees the wrapper. The buffer count is read before the
    // retain count, and a deleter racing on another thread drops its count
    // before its retain, so the race can only make the check miss. Immortal
    // objects (constants, tagged pointers) report a count far above these.
    uint32_t jsRetains = 1 + objcWrapper->BufferRetainCount();
    if (static_cast<uint64_t>(CFGetRetainCount((CFTypeRef)c.object)) != jsRetains) {
      continue;
    }
    SetSize(isolate, wrapper, Estimate(static_cast<Estimator>(c.estimator), c.object));
  }
}

void SoleOwnerCandidates::EnsureWake(Isolate* isolate, double dueMs, double now) {
  if (wakeAtMs_ >= dueMs && wakeAtMs_ <= dueMs + kWakeCoalesceMs) {
    return;
  }
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  if (loop == nullptr) {
    return;
  }
  wakeAtMs_ = dueMs + kWakeCoalesceMs;
  loop->PostInternalDelayed([] {}, std::max(0.0, wakeAtMs_ - now));
}

void StartMemoryPressureMonitoring() {
  static dispatch_source_t source;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                    DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
                                        DISPATCH_MEMORYPRESSURE_CRITICAL,
                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(source, ^{
      unsigned long status = dispatch_source_get_data(source);
      MemoryPressureLevel level = MemoryPressureLevel::kNone;
      if (status & DISPATCH_MEMORYPRESSURE_CRITICAL) {
        level = MemoryPressureLevel::kCritical;
      } else if (status & DISPATCH_MEMORYPRESSURE_WARN) {
        level = MemoryPressureLevel::kModerate;
      }
      Runtime::NotifyMemoryPressure(level);
    });
    dispatch_resume(source);
  });
}

}  // namespace ExternalMemory

}  // namespace tns
