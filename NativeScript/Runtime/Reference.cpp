#include "Reference.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;

namespace tns {

void Reference::Register(Isolate* isolate, Local<Object> interop) {
    Local<v8::Function> ctorFunc = Reference::GetInteropReferenceCtorFunc(isolate);
    interop->Set(tns::ToV8String(isolate, "Reference"), ctorFunc);
}

Local<v8::Function> Reference::GetInteropReferenceCtorFunc(Isolate* isolate) {
    if (interopReferenceCtorFunc_ != nullptr) {
        return interopReferenceCtorFunc_->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, ReferenceConstructorCallback);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Reference"));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();
    proto->SetAccessor(tns::ToV8String(isolate, "value"), ValueCallback);

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    tns::SetValue(isolate, ctorFunc, new ReferenceTypeWrapper());
    Local<Object> prototype = ctorFunc->Get(tns::ToV8String(isolate, "prototype")).As<Object>();
    Reference::RegisterToStringMethod(isolate, prototype);

    interopReferenceCtorFunc_ = new Persistent<v8::Function>(isolate, ctorFunc);

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

void Reference::ValueCallback(Local<v8::String> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<External> ext = info.This()->GetInternalField(0).As<External>();
    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(ext->Value());
    Local<Value> result = Reference::GetInteropReferenceValue(isolate, wrapper);

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    } else {
        info.GetReturnValue().Set(v8::Undefined(isolate));
    }
}

Local<Value> Reference::GetInteropReferenceValue(Isolate* isolate, ReferenceWrapper* wrapper) {
    if (wrapper->Data() == nullptr) {
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

    const TypeEncoding* encoding = wrapper->Encoding();
    uint8_t* data = (uint8_t*)wrapper->Data();

    BaseCall call(data);
    Local<Value> jsResult = Interop::GetResult(isolate, encoding, &call, true);
    return jsResult;
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

    prototype->Set(tns::ToV8String(isolate, "toString"), func);
}

Persistent<v8::Function>* Reference::interopReferenceCtorFunc_ = nullptr;

}
