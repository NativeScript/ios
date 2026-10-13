#include "ExternalMemory.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include "Caches.h"
#include "DataWrapper.h"
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

  auto& estimators = Caches::Get(isolate)->ExternalSizeEstimators;
  Class klass = objcWrapper->Klass();
  auto it = estimators.find(klass);
  Estimator estimator;
  if (it != estimators.end()) {
    estimator = static_cast<Estimator>(it->second);
  } else {
    estimator = ResolveEstimator(klass);
    estimators.emplace(klass, estimator);
  }
  if (estimator == kNone) {
    return;
  }

  SetSize(isolate, wrapper, Estimate(estimator, obj));
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
