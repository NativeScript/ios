#include "Pointer.h"
#include "Caches.h"
#include "Helpers.h"
#include "ObjectManager.h"

using namespace v8;

namespace tns {

void Pointer::Register(Isolate* isolate, Local<Object> interop) {
    Local<v8::Function> ctorFunc = Pointer::GetPointerCtorFunc(isolate);
    interop->Set(tns::ToV8String(isolate, "Pointer"), ctorFunc);
}

Local<Value> Pointer::NewInstance(Isolate* isolate, void* handle) {
    intptr_t ptr = static_cast<intptr_t>(reinterpret_cast<size_t>(handle));

    Local<Value> arg = Number::New(isolate, ptr);
    Local<Value> args[1] { arg };
    Local<Value> result;
    Local<v8::Function> ctorFunc = Pointer::GetPointerCtorFunc(isolate);
    bool success = ctorFunc->NewInstance(isolate->GetCurrentContext(), 1, args).ToLocal(&result);
    assert(success);
    return result;
}

Local<v8::Function> Pointer::GetPointerCtorFunc(Isolate* isolate) {
    if (pointerCtorFunc_ != nullptr) {
        return pointerCtorFunc_->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, PointerConstructorCallback);

    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Pointer"));

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    tns::SetValue(isolate, ctorFunc, new PointerTypeWrapper());

    Local<Object> prototype = ctorFunc->Get(tns::ToV8String(isolate, "prototype")).As<Object>();
    Pointer::RegisterAddMethod(isolate, prototype);
    Pointer::RegisterSubtractMethod(isolate, prototype);
    Pointer::RegisterToStringMethod(isolate, prototype);
    Pointer::RegisterToHexStringMethod(isolate, prototype);
    Pointer::RegisterToDecimalStringMethod(isolate, prototype);
    Pointer::RegisterToNumberMethod(isolate, prototype);

    pointerCtorFunc_ = new Persistent<v8::Function>(isolate, ctorFunc);

    return ctorFunc;
}

void Pointer::PointerConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    void* ptr = nullptr;

    if (info.Length() == 1) {
        assert(tns::IsNumber(info[0]));

        Local<Number> arg = info[0].As<Number>();
        Local<Context> context = isolate->GetCurrentContext();

#if __SIZEOF_POINTER__ == 8
        // JSC stores 64-bit integers as doubles in JSValue.
        // Caution: This means that pointers with more than 54 significant bits
        // are likely to be rounded and misrepresented!
        // However, current OS and hardware implementations are using 48 bits,
        // so we're safe at the time being.
        // See https://en.wikipedia.org/wiki/X86-64#Virtual_address_space_details
        // and https://en.wikipedia.org/wiki/ARM_architecture#ARMv8-A
        int64_t value;
        assert(arg->IntegerValue(context).To(&value));
        ptr = reinterpret_cast<void*>(value);
#else
        int32_t value;
        assert(arg->Int32Value(context).To(&value));
        ptr = reinterpret_cast<void*>(value);
#endif
    }

    auto it = Caches::PointerInstances.find(ptr);
    if (it != Caches::PointerInstances.end()) {
        info.GetReturnValue().Set(it->second->Get(isolate));
        return;
    }

    PointerWrapper* wrapper = new PointerWrapper(ptr);
    tns::SetValue(isolate, info.This(), wrapper);

    ObjectManager::Register(isolate, info.This());

    Caches::PointerInstances.insert(std::make_pair(ptr, new Persistent<Object>(isolate, info.This())));
}

void Pointer::RegisterAddMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        assert(info.Length() == 1 && tns::IsNumber(info[0]));

        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();
        int32_t offset;
        assert(info[0].As<Number>()->Int32Value(context).To(&offset));

        void* newValue = reinterpret_cast<void*>(reinterpret_cast<char*>(value) + offset);
        Local<Value> result = Pointer::NewInstance(isolate, newValue);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "add"), func);
}

void Pointer::RegisterSubtractMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        assert(info.Length() == 1 && tns::IsNumber(info[0]));

        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();
        int32_t offset;
        assert(info[0].As<Number>()->Int32Value(context).To(&offset));

        void* newValue = reinterpret_cast<void*>(reinterpret_cast<char*>(value) - offset);
        intptr_t newValuePtr = static_cast<intptr_t>(reinterpret_cast<size_t>(newValue));

        Local<v8::Function> ctorFunc = pointerCtorFunc_->Get(isolate);
        Local<Value> arg = Number::New(isolate, newValuePtr);
        Local<Value> args[1] { arg };
        Local<Value> result;
        bool success = ctorFunc->NewInstance(context, 1, args).ToLocal(&result);
        assert(success);

        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "subtract"), func);
}

void Pointer::RegisterToStringMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();

        char buffer[100];
        sprintf(buffer, "<Pointer: %p>", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "toString"), func);
}

void Pointer::RegisterToHexStringMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();

        char buffer[100];
        sprintf(buffer, "%p", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "toHexString"), func);
}

void Pointer::RegisterToDecimalStringMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();
        intptr_t ptr = static_cast<intptr_t>(reinterpret_cast<size_t>(value));

        char buffer[100];
        sprintf(buffer, "%ld", ptr);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "toDecimalString"), func);
}

void Pointer::RegisterToNumberMethod(Isolate* isolate, Local<Object> prototype) {
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();
        size_t number = reinterpret_cast<size_t>(value);
        Local<Number> result = Number::New(isolate, number);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    assert(funcTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&func));

    prototype->Set(tns::ToV8String(isolate, "toNumber"), func);
}

Persistent<v8::Function>* Pointer::pointerCtorFunc_ = nullptr;

}
