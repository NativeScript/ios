#ifndef ExtVector_h
#define ExtVector_h

#include "Common.h"
#include "Metadata.h"
#include "libffi.h"

namespace tns {

class ExtVector {
 public:
  static v8::Local<v8::Value> NewInstance(v8::Isolate* isolate, void* data,
                                          ffi_type* ffiType,
                                          const TypeEncoding* innerTypeEncoding,
                                          const TypeEncoding* typeEncoding);

 private:
  static void RegisterToStringMethod(
      v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> prototypeTemplate);
  static v8::Intercepted IndexedPropertyGetCallback(
      uint32_t index, const v8::PropertyCallbackInfo<v8::Value>& info);
  static v8::Intercepted IndexedPropertySetCallback(
      uint32_t index, v8::Local<v8::Value> value,
      const v8::PropertyCallbackInfo<v8::Boolean>& info);
};

}  // namespace tns

#endif /* ExtVector_h */
