#include "DataWrapper.h"
#include "Caches.h"
#include "Runtime.h"

void tns::DisposeDataWrapper(void* wrapper_void) {
  auto wrapper = static_cast<tns::BaseDataWrapper*>(wrapper_void);
  switch (wrapper->Type()) {
    case WrapperType::ObjCObject: {
      auto w = static_cast<tns::ObjCDataWrapper*>(wrapper);
      auto isolate = Runtime::GetCurrentRuntime()->GetIsolate();
      auto cache = Caches::Get(isolate);
      auto it = cache->Instances.find(w->Data());
      if (it != cache->Instances.end()) {
        cache->Instances.erase(it);
      }
    } break;
    default:
      break;
  }
}
