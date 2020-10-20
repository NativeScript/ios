#include "UnmanagedType.h"
#include "NativeScriptException.h"
#include "Caches.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;

namespace tns {

Local<Value> UnmanagedType::Create(Local<Context> context, UnmanagedTypeWrapper* wrapper) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    if (cache->UnmanagedTypeCtorFunc.get() == nullptr) {
        Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, ConstructorCallback);
        ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Unmanaged"));
        Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

        Local<FunctionTemplate> takeUnretainedValueFuncTemplate = FunctionTemplate::New(isolate, UnmanagedType::TakeUnretainedValueCallback);
        Local<FunctionTemplate> takeRetainedValueFuncTemplate = FunctionTemplate::New(isolate, UnmanagedType::TakeRetainedValueCallback);
        proto->Set(tns::ToV8String(isolate, "takeUnretainedValue"), takeUnretainedValueFuncTemplate);
        proto->Set(tns::ToV8String(isolate, "takeRetainedValue"), takeRetainedValueFuncTemplate);

        Local<v8::Function> ctorFunc;
        bool success = ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc);
        tns::Assert(success, isolate);
        
        cache->UnmanagedTypeCtorFunc = std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc);
    }

    Local<External> ext = External::New(isolate, wrapper);

    Local<v8::Function> ctorFunc = cache->UnmanagedTypeCtorFunc->Get(isolate);
    Local<Value> result;
    Local<Value> args[] = { ext };
    bool success = ctorFunc->NewInstance(context, 1, args).ToLocal(&result);
    tns::Assert(success, isolate);

    return result;
}

void UnmanagedType::ConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Local<External> ext = info[0].As<External>();
    UnmanagedTypeWrapper* wrapper = static_cast<UnmanagedTypeWrapper*>(ext->Value());
    tns::SetValue(info.GetIsolate(), info.This(), wrapper);
}

void UnmanagedType::TakeUnretainedValueCallback(const FunctionCallbackInfo<Value>& info) {
    try {
        info.GetReturnValue().Set(UnmanagedType::TakeValue(info, false));
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(info.GetIsolate());
    }
}

void UnmanagedType::TakeRetainedValueCallback(const FunctionCallbackInfo<Value>& info) {
    try {
        info.GetReturnValue().Set(UnmanagedType::TakeValue(info, true));
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(info.GetIsolate());
    }
}

Local<Value> UnmanagedType::TakeValue(const FunctionCallbackInfo<Value>& info, bool retained) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, info.This());
    UnmanagedTypeWrapper* wrapper = static_cast<UnmanagedTypeWrapper*>(baseWrapper);
    
    if (wrapper->ValueTaken()) {
        throw NativeScriptException("Unmanaged value has already been consumed.");
    }

    uint8_t* data = wrapper->Data();
    const TypeEncoding* typeEncoding = wrapper->TypeEncoding();

    BaseCall call((uint8_t*)&data);
    Local<Value> result = Interop::GetResult(context, typeEncoding, &call, false);

    if (retained) {
        id value = static_cast<id>((void*)data);
        [value release];
    }

    return result;
}

}
