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
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* interopReferenceCtor = cache->InteropReferenceCtorFunc;
    if (interopReferenceCtor != nullptr) {
        return interopReferenceCtor->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, ReferenceConstructorCallback);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Reference"));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->InstanceTemplate()->SetHandler(IndexedPropertyHandlerConfiguration(nullptr, IndexedPropertySetCallback));
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

    cache->InteropReferenceCtorFunc = new Persistent<v8::Function>(isolate, ctorFunc);

    return ctorFunc;
}

void Reference::ReferenceConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Persistent<Value>* val = nullptr;
    PrimitiveDataWrapper* primitiveWrapper = nullptr;
    if (info.Length() == 1) {
        val = new Persistent<Value>(isolate, info[0]);
    } else if (info.Length() > 1) {
        Local<Value> typeValue = info[0];
        BaseDataWrapper* typeValueWrapper = tns::GetValue(isolate, typeValue);
        assert(typeValueWrapper != nullptr && typeValueWrapper->Type() == WrapperType::Primitive);
        primitiveWrapper = static_cast<PrimitiveDataWrapper*>(typeValueWrapper);
        val = new Persistent<Value>(isolate, info[1]);
    }

    ReferenceWrapper* wrapper = new ReferenceWrapper(primitiveWrapper, val);
    Local<Object> thiz = info.This();
    tns::SetValue(isolate, thiz, wrapper);

    ObjectManager::Register(isolate, thiz);
}

void Reference::IndexedPropertySetCallback(uint32_t index, v8::Local<v8::Value> value, const v8::PropertyCallbackInfo<v8::Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();

    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference);
    ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);

    if (refWrapper->TypeWrapper() == nullptr) {
        // TODO: Missing type when creating the Reference instance
        assert(false);
    }

    Local<Value> pointerObj = refWrapper->Value()->Get(isolate);
    BaseDataWrapper* wrappedValue = tns::GetValue(isolate, pointerObj);
    if (wrappedValue == nullptr || wrappedValue->Type() != WrapperType::Pointer) {
        assert(false);
    }

    PointerWrapper* pw = static_cast<PointerWrapper*>(wrappedValue);
    void* data = pw->Data();

    PrimitiveDataWrapper* typeWrapper = refWrapper->TypeWrapper();
    const TypeEncoding* typeEncoding = typeWrapper->TypeEncoding();
    size_t size = typeWrapper->Size();
    void* ptr = (uint8_t*)data + index * size;
    Interop::WriteValue(isolate, typeEncoding, ptr, value);
}

void Reference::GetValueCallback(Local<Name> name, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Value> result = GetReferredValue(isolate, info.This());
    if (result.IsEmpty()) {
        info.GetReturnValue().Set(v8::Undefined(isolate));
    } else {
        info.GetReturnValue().Set(result);
    }
}

void Reference::SetValueCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void>& info) {
    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, info.This());
    assert(baseWrapper->Type() == WrapperType::Reference);
    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    Persistent<Value>* poValue = new Persistent<Value>(isolate, value);

    wrapper->SetData(nullptr);
    wrapper->SetEncoding(nullptr);
    wrapper->SetValue(poValue);
}

Local<Value> Reference::GetReferredValue(Isolate* isolate, Local<Value> value) {
    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
    if (baseWrapper == nullptr || baseWrapper->Type() != WrapperType::Reference) {
        return value;
    }

    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    if (wrapper->Data() != nullptr && wrapper->Encoding() != nullptr) {
        const TypeEncoding* encoding = wrapper->Encoding();
        uint8_t* data = (uint8_t*)wrapper->Data();

        BaseCall call(data);
        Local<Value> jsResult = Interop::GetResult(isolate, encoding, &call, true);
        if (wrapper->Value() != nullptr) {
            wrapper->Value()->Reset(isolate, jsResult);
        } else {
            wrapper->SetValue(new Persistent<Value>(isolate, jsResult));
        }

        wrapper->SetData(nullptr);
        wrapper->SetEncoding(nullptr);
        return jsResult;
    }

    if (wrapper->Value() == nullptr) {
        return Local<Value>();
    }

    Local<Value> innerValue = wrapper->Value()->Get(isolate);
    baseWrapper = tns::GetValue(isolate, innerValue);
    if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::Reference) {
        wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
        if (wrapper->Value() != nullptr) {
            return GetReferredValue(isolate, wrapper->Value()->Get(isolate));
        }
    }

    return innerValue;
}

void* Reference::GetWrappedPointer(Isolate* isolate, const TypeEncoding* typeEncoding, Local<Object> reference) {
    if (reference.IsEmpty()) {
        return nullptr;
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, reference);
    assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference);
    ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);

    Local<Value> value = refWrapper->Value()->Get(isolate);
    BaseDataWrapper* wrappedValue = tns::GetValue(isolate, value);
    if (wrappedValue == nullptr || wrappedValue->Type() != WrapperType::Pointer) {
        return nullptr;
    }

    PointerWrapper* pw = static_cast<PointerWrapper*>(wrappedValue);
    void* data = pw->Data();

    return data;
}

void Reference::RegisterToStringMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
        assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference);
        ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);
        Persistent<Value>* value = refWrapper->Value();

        char buffer[100];
        if (value == nullptr) {
            sprintf(buffer, "<Reference: %p>", reinterpret_cast<void*>(0));
        } else {
            sprintf(buffer, "<Reference: %p>", value);
        }

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
