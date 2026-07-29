#ifndef Reference_h
#define Reference_h

#include "Common.h"
#include "DataWrapper.h"

namespace tns {

class Reference {
 public:
  static void Register(v8::Local<v8::Context> context,
                       v8::Local<v8::Object> interop);
  static v8::Local<v8::Value> FromPointer(v8::Local<v8::Context> context,
                                          v8::Local<v8::Value> type,
                                          void* handle);
  static v8::Local<v8::Function> GetInteropReferenceCtorFunc(
      v8::Local<v8::Context> context);
  static void* GetWrappedPointer(v8::Local<v8::Context> context,
                                 v8::Local<v8::Value> reference,
                                 const TypeEncoding* typeEncoding);

 private:
  struct DataPair {
    DataPair(BaseDataWrapper* typeWrapper, const TypeEncoding* typeEncoding,
             void* data, size_t size)
        : typeWrapper_(typeWrapper),
          typeEncoding_(typeEncoding),
          data_(data),
          size_(size) {}

    BaseDataWrapper* typeWrapper_;
    const TypeEncoding* typeEncoding_;
    void* data_;
    size_t size_;
  };

  static v8::Local<v8::Value> GetReferredValue(v8::Local<v8::Context> context,
                                               v8::Local<v8::Value> value);
  static void ReferenceConstructorCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static v8::Intercepted IndexedPropertyGetCallback(
      uint32_t index, const v8::PropertyCallbackInfo<v8::Value>& info);
  static v8::Intercepted IndexedPropertySetCallback(
      uint32_t index, v8::Local<v8::Value> value,
      const v8::PropertyCallbackInfo<v8::Boolean>& info);

  static void GetValueCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void SetValueCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void RegisterToStringMethod(v8::Local<v8::Context> context,
                                     v8::Local<v8::Object> prototype);
  static DataPair GetDataPair(v8::Local<v8::Object> obj);
  static bool IsSupportedType(WrapperType type);
};

}  // namespace tns

#endif /* Reference_h */
