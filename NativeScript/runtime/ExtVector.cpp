#include "ExtVector.h"

#include "Caches.h"
#include "FFICall.h"
#include "Helpers.h"
#include "Interop.h"
#include "ObjectManager.h"

using namespace v8;

namespace tns {

Local<Value> ExtVector::NewInstance(Isolate* isolate, void* data,
                                    ffi_type* ffiType,
                                    const TypeEncoding* innerTypeEncoding,
                                    const TypeEncoding* typeEncoding) {
  Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate);
  ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
  ctorFuncTemplate->InstanceTemplate()->SetHandler(
      IndexedPropertyHandlerConfiguration(IndexedPropertyGetCallback,
                                          IndexedPropertySetCallback));
  ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "ExtVector"));
  ExtVector::RegisterToStringMethod(isolate,
                                    ctorFuncTemplate->PrototypeTemplate());

  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result;
  bool success =
      ctorFuncTemplate->InstanceTemplate()->NewInstance(context).ToLocal(
          &result);
  tns::Assert(success, isolate);

  // TODO: Validate that the inner type is supported (float, double)
  ExtVectorWrapper* wrapper =
      new ExtVectorWrapper(data, ffiType, innerTypeEncoding, typeEncoding);
  tns::SetValue(isolate, result.As<Object>(), wrapper);

  return result;
}

v8::Intercepted ExtVector::IndexedPropertyGetCallback(
    uint32_t index, const PropertyCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  BaseDataWrapper* wrapper = tns::GetValue(isolate, info.Holder());
  tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ExtVector,
              isolate);
  ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
  const TypeEncoding* innerTypeEncoding = extVectorWrapper->InnerTypeEncoding();
  ffi_type* innerFFIType = FFICall::GetArgumentType(innerTypeEncoding);
  size_t offset = index * innerFFIType->size;
  FFICall::DisposeFFIType(innerFFIType, innerTypeEncoding);

  ffi_type* ffiType = extVectorWrapper->FFIType();
  if (offset >= ffiType->size) {
    // Trying to access an element outside of the vector size
    info.GetReturnValue().SetUndefined();
    return v8::Intercepted::kYes;
  }

  void* data = extVectorWrapper->Data();
  BaseCall call((uint8_t*)data, offset);
  Local<Value> result =
      Interop::GetPrimitiveReturnType(context, innerTypeEncoding->type, &call);
  info.GetReturnValue().Set(result);
  return v8::Intercepted::kYes;
}

v8::Intercepted ExtVector::IndexedPropertySetCallback(
    uint32_t index, Local<Value> value,
    const PropertyCallbackInfo<v8::Boolean>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();

  BaseDataWrapper* wrapper = tns::GetValue(isolate, info.Holder());
  tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ExtVector,
              isolate);
  ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
  const TypeEncoding* innerTypeEncoding = extVectorWrapper->InnerTypeEncoding();
  ffi_type* innerFFIType = FFICall::GetArgumentType(innerTypeEncoding);
  size_t offset = index * innerFFIType->size;
  FFICall::DisposeFFIType(innerFFIType, innerTypeEncoding);

  ffi_type* ffiType = extVectorWrapper->FFIType();
  if (offset >= ffiType->size) {
    // Trying to access an element outside of the vector size
    return v8::Intercepted::kNo;
  }

  void* data = extVectorWrapper->Data();
  void* dest = (uint8_t*)data + offset;
  Interop::WriteValue(context, innerTypeEncoding, dest, value);
  // Not intercepted: the native write is done, but V8 must still perform
  // the ordinary store, which is what the old void-returning callback did
  // by falling through without setting a return value.
  return v8::Intercepted::kNo;
}

void ExtVector::RegisterToStringMethod(
    Isolate* isolate, Local<ObjectTemplate> prototypeTemplate) {
  Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(
      isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        BaseDataWrapper* baseWrapper =
            tns::GetValueOrReport(isolate, info.This(), "ExtVector.toString");
        if (baseWrapper == nullptr) {
          if (tns::GetReleasedObjectPolicy() ==
              tns::ReleasedObjectPolicy::kReport) {
            info.GetReturnValue().Set(
                tns::ToV8String(isolate, "<Vector: released>"));
          }
          return;
        }
        ExtVectorWrapper* wrapper = static_cast<ExtVectorWrapper*>(baseWrapper);
        void* value = wrapper->Data();

        char buffer[100];
        snprintf(buffer, 100, "<Vector: %p>", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
      });

  prototypeTemplate->Set(tns::ToV8String(isolate, "toString"), funcTemplate);
}

}  // namespace tns
