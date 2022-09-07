#include "ExtVector.h"
#include "ObjectManager.h"
#include "FFICall.h"
#include "Caches.h"
#include "Interop.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

Local<Value> ExtVector::NewInstance(Isolate* isolate, void* data, ffi_type* ffiType, const TypeEncoding* innerTypeEncoding) {
    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->InstanceTemplate()->SetHandler(IndexedPropertyHandlerConfiguration(IndexedPropertyGetCallback, IndexedPropertySetCallback));
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "ExtVector"));
    ExtVector::RegisterToStringMethod(isolate, ctorFuncTemplate->PrototypeTemplate());

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result;
    bool success = ctorFuncTemplate->InstanceTemplate()->NewInstance(context).ToLocal(&result);
    tns::Assert(success, isolate);

    // TODO: Validate that the inner type is supported (float, double)
    ExtVectorWrapper* wrapper = new ExtVectorWrapper(data, ffiType, innerTypeEncoding);
    tns::SetValue(isolate, result.As<Object>(), wrapper);

    return result;
}

void ExtVector::IndexedPropertyGetCallback(uint32_t index, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ExtVector, isolate);
    ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
    const TypeEncoding* innerTypeEncoding = extVectorWrapper->InnerTypeEncoding();
    ffi_type* innerFFIType = FFICall::GetArgumentType(innerTypeEncoding);
    size_t offset = index * innerFFIType->size;

    ffi_type* ffiType = extVectorWrapper->FFIType();
    if (offset >= ffiType->size) {
        // Trying to access an element outside of the vector size
        info.GetReturnValue().SetUndefined();
        return;
    }

    void* data = extVectorWrapper->Data();
    BaseCall call((uint8_t*)data, offset);
    Local<Value> result = Interop::GetPrimitiveReturnType(context, innerTypeEncoding->type, &call);
    info.GetReturnValue().Set(result);
}

void ExtVector::IndexedPropertySetCallback(uint32_t index, Local<Value> value, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ExtVector, isolate);
    ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
    const TypeEncoding* innerTypeEncoding = extVectorWrapper->InnerTypeEncoding();
    ffi_type* innerFFIType = FFICall::GetArgumentType(innerTypeEncoding);
    size_t offset = index * innerFFIType->size;

    ffi_type* ffiType = extVectorWrapper->FFIType();
    if (offset >= ffiType->size) {
        // Trying to access an element outside of the vector size
        return;
    }

    void* data = extVectorWrapper->Data();
    void* dest = (uint8_t*)data + offset;
    Interop::WriteValue(context, innerTypeEncoding, dest, value);
}

void ExtVector::RegisterToStringMethod(Isolate* isolate, Local<ObjectTemplate> prototypeTemplate) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        ExtVectorWrapper* wrapper = static_cast<ExtVectorWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();

        char buffer[100];
        snprintf(buffer, 100, "<Vector: %p>", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    prototypeTemplate->Set(tns::ToV8String(isolate, "toString"), funcTemplate);
}

}
