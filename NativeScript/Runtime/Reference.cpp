#include "Reference.h"
#include "Caches.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;

namespace tns {

void Reference::Register(Isolate* isolate, Local<Object> interop) {
    Local<v8::Function> ctorFunc = Reference::GetInteropReferenceCtorFunc(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = interop->Set(context, tns::ToV8String(isolate, "Reference"), ctorFunc).FromMaybe(false);
    assert(success);
}

Local<v8::Function> Reference::GetInteropReferenceCtorFunc(Isolate* isolate) {
    Persistent<v8::Function>* interopReferenceCtor = Caches::Get(isolate)->InteropReferenceCtorFunc;
    if (interopReferenceCtor != nullptr) {
        return interopReferenceCtor->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, ReferenceConstructorCallback);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Reference"));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();
    Local<Context> context = isolate->GetCurrentContext();
    proto->SetAccessor(tns::ToV8String(isolate, "value"), GetValueCallback, SetValueCallback);

    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    tns::SetValue(isolate, ctorFunc, new ReferenceTypeWrapper());
    Local<Value> prototypeValue;
    bool success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
    assert(success && prototypeValue->IsObject());
    Local<Object> prototype = prototypeValue.As<Object>();
    Reference::RegisterToStringMethod(isolate, prototype);

    Caches::Get(isolate)->InteropReferenceCtorFunc = new Persistent<v8::Function>(isolate, ctorFunc);

    return ctorFunc;
}

void Reference::ReferenceConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Persistent<Value>* val = nullptr;
    if (info.Length() == 1) {
        val = new Persistent<Value>(isolate, info[0]);
    } else if (info.Length() > 1) {
        val = new Persistent<Value>(isolate, info[1]);
    }

    ReferenceWrapper* wrapper = new ReferenceWrapper(val);
    Local<Object> thiz = info.This();
    tns::SetValue(isolate, thiz, wrapper);

    ObjectManager::Register(isolate, thiz);
}

void Reference::GetValueCallback(Local<Name> name, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, info.This());
    assert(baseWrapper->Type() == WrapperType::Reference);
    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    Local<Value> result = Reference::GetInteropReferenceValue(isolate, wrapper);

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    } else {
        info.GetReturnValue().Set(v8::Undefined(isolate));
    }
}

void Reference::SetValueCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void>& info) {
    Isolate* isolate = info.GetIsolate();

    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, info.This());
    assert(baseWrapper->Type() == WrapperType::Reference);
    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    if (wrapper->Data() != nullptr) {
        std::free(wrapper->Data());
        wrapper->SetData(nullptr);
    }

    BaseDataWrapper* argWrapper = tns::GetValue(isolate, value);

    if (argWrapper != nullptr && argWrapper->Type() == WrapperType::Pointer) {
        PointerWrapper* pw = static_cast<PointerWrapper*>(argWrapper);
        wrapper->SetData(pw->Data());
    } else {
        Persistent<Value>* poValue = new Persistent<Value>(isolate, value);
        wrapper->SetValue(poValue);

        const TypeEncoding* typeEncoding = wrapper->Encoding();
        if (typeEncoding != nullptr) {
            ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding);
            void* data = calloc(ffiType->size, 1);
            Interop::WriteValue(isolate, typeEncoding, data, value);
            wrapper->SetData(data);
        }
    }
}

Local<Value> Reference::GetInteropReferenceValue(Isolate* isolate, ReferenceWrapper* wrapper) {
    if (wrapper->Data() != nullptr && wrapper->Encoding() != nullptr) {
        const TypeEncoding* encoding = wrapper->Encoding();
        uint8_t* data = (uint8_t*)wrapper->Data();

        BaseCall call(data);
        Local<Value> jsResult = Interop::GetResult(isolate, encoding, &call, true);
        return jsResult;
    }

    if (wrapper->Value() == nullptr) {
        return Local<Value>();
    }

    Local<Value> result = wrapper->Value()->Get(isolate);

    if (result->IsObject() && result.As<Object>()->InternalFieldCount() > 0) {
        Local<Value> internalField = result.As<Object>()->GetInternalField(0);
        if (!internalField.IsEmpty() && internalField->IsExternal()) {
            Local<External> ext = internalField.As<External>();
            BaseDataWrapper* w = static_cast<BaseDataWrapper*>(ext->Value());
            if (w->Type() == WrapperType::Reference) {
                ReferenceWrapper* rw = static_cast<ReferenceWrapper*>(w);
                return Reference::GetInteropReferenceValue(isolate, rw);
            }
        }
    }

    return result;
}

void Reference::RegisterToStringMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();
        if (value == nullptr) {
            value = reinterpret_cast<void*>(0);
        }

        char buffer[100];
        sprintf(buffer, "<Reference: %p>", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    Local<Context> context = isolate->GetCurrentContext();
    bool success = prototype->Set(context, tns::ToV8String(isolate, "toString"), func).FromMaybe(false);
    assert(success);
}

}
