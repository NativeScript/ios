#include "Pointer.h"
#include "Caches.h"
#include "Helpers.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Constants.h"

using namespace v8;

namespace tns {

void Pointer::Register(Local<Context> context, Local<Object> interop) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> ctorFunc = Pointer::GetPointerCtorFunc(context);
    bool success = interop->Set(context, tns::ToV8String(isolate, "Pointer"), ctorFunc).FromMaybe(false);
    tns::Assert(success, isolate);
}

Local<Value> Pointer::NewInstance(Local<Context> context, void* handle) {
    Isolate* isolate = context->GetIsolate();
    intptr_t ptr = static_cast<intptr_t>(reinterpret_cast<size_t>(handle));

    Local<Value> arg = BigInt::NewFromUnsigned(isolate, ptr);
    Local<Value> args[1] { arg };
    Local<Value> result;
    Local<v8::Function> ctorFunc = Pointer::GetPointerCtorFunc(context);
    bool success = ctorFunc->NewInstance(isolate->GetCurrentContext(), 1, args).ToLocal(&result);
    if (!success) {
        return v8::Undefined(isolate);
    }
    return result;
}

Local<v8::Function> Pointer::GetPointerCtorFunc(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* pointerCtorFunc = cache->PointerCtorFunc.get();
    if (pointerCtorFunc != nullptr) {
        return pointerCtorFunc->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, PointerConstructorCallback);

    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Pointer"));

    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        tns::Assert(false, isolate);
    }

    tns::SetValue(isolate, ctorFunc, MakeGarbageCollected<PointerTypeWrapper>(isolate));

    Local<Value> prototypeValue;
    bool success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
    tns::Assert(success && prototypeValue->IsObject(), isolate);
    Local<Object> prototype = prototypeValue.As<Object>();
    Pointer::RegisterAddMethod(context, prototype);
    Pointer::RegisterSubtractMethod(context, prototype);
    Pointer::RegisterToStringMethod(context, prototype);
    Pointer::RegisterToHexStringMethod(context, prototype);
    Pointer::RegisterToDecimalStringMethod(context, prototype);
    Pointer::RegisterToNumberMethod(context, prototype);
    Pointer::RegisterToBigIntMethod(context, prototype);

    cache->PointerCtorFunc = std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc);
    cache->PointerCtorFunc->SetWrapperClassId(Constants::ClassTypes::DataWrapper);

    return ctorFunc;
}

void Pointer::PointerConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    try {
        void* ptr = nullptr;

        if (info.Length() == 1) {
            bool isBigInt = tns::IsBigInt(info[0]);
            bool isNumber = !isBigInt && tns::IsNumber(info[0]);
            if (!isBigInt && !isNumber) {
                throw NativeScriptException("Pointer constructor's first arg must be an integer.");
            }

    #if __SIZEOF_POINTER__ == 8
            // JSC stores 64-bit integers as doubles in JSValue.
            // Caution: This means that pointers with more than 54 significant bits
            // are likely to be rounded and misrepresented!
            // However, current OS and hardware implementations are using 48 bits,
            // so we're safe at the time being.
            // See https://en.wikipedia.org/wiki/X86-64#Virtual_address_space_details
            // and https://en.wikipedia.org/wiki/ARM_architecture#ARMv8-A
            
            // The future is here, and turns out the OS is using more than 54 bits.
            // as a result,
            int64_t value;
            if (isBigInt) {
                value = info[0].As<BigInt>()->Int64Value();
            } else {
// TODO: Maybe log this?
//#ifdef DEBUG
//                syslog(LOG_WARNING, "Using JS Number to represent a pointer. Result might be wrong.");
//#endif
                tns::Assert(info[0].As<Number>()->IntegerValue(context).To(&value), isolate);
            }

            ptr = reinterpret_cast<void*>(value);
    #else
            int32_t value;
            if (isBigInt) {
                value = (int32_t)info[0].As<BigInt>()->Int64Value();
            } else {
                tns::Assert(info[0].As<Number>()->Int32Value    (context).To(&value), isolate);
            }
            ptr = reinterpret_cast<void*>(value);
    #endif
        }

        auto cache = Caches::Get(isolate);
        auto it = cache->PointerInstances.find(ptr);
        if (it != cache->PointerInstances.end()) {
            info.GetReturnValue().Set(it->second->Get(isolate));
            return;
        }

        PointerWrapper* wrapper = MakeGarbageCollected<PointerWrapper>(isolate, ptr);
        tns::SetValue(isolate, info.This(), wrapper);

        ObjectManager::Register(context, info.This());

        cache->PointerInstances.emplace(ptr, std::make_shared<Persistent<Object>>(isolate, info.This()));
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void Pointer::RegisterAddMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        tns::Assert(info.Length() == 1 && tns::IsNumber(info[0]), isolate);

        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();
        int32_t offset;
        tns::Assert(info[0].As<Number>()->Int32Value(context).To(&offset), isolate);

        void* newValue = reinterpret_cast<void*>(reinterpret_cast<char*>(value) + offset);
        Local<Value> result = Pointer::NewInstance(context, newValue);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "add"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterSubtractMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        tns::Assert(info.Length() == 1 && tns::IsNumber(info[0]), isolate);

        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();
        int32_t offset;
        tns::Assert(info[0].As<Number>()->Int32Value(context).To(&offset), isolate);

        void* newValue = reinterpret_cast<void*>(reinterpret_cast<char*>(value) - offset);
        intptr_t newValuePtr = static_cast<intptr_t>(reinterpret_cast<size_t>(newValue));

        Local<v8::Function> ctorFunc = Pointer::GetPointerCtorFunc(context);
        Local<Value> arg = Number::New(isolate, newValuePtr);
        Local<Value> args[1] { arg };
        Local<Value> result;
        bool success = ctorFunc->NewInstance(context, 1, args).ToLocal(&result);
        tns::Assert(success, isolate);

        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "subtract"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterToStringMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        void* value = wrapper->Data();

        char buffer[100];
        snprintf(buffer, 100, "<Pointer: %p>", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toString"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterToHexStringMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();

        char buffer[100];
        snprintf(buffer, 100, "%p", value);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toHexString"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterToDecimalStringMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();
        intptr_t ptr = static_cast<intptr_t>(reinterpret_cast<size_t>(value));

        char buffer[100];
        snprintf(buffer, 100, "%ld", ptr);

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toDecimalString"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterToNumberMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();
        size_t number = reinterpret_cast<size_t>(value);
        Local<Number> result = Number::New(isolate, number);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toNumber"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Pointer::RegisterToBigIntMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(info.This()->GetInternalField(0).As<External>()->Value());
        const void* value = wrapper->Data();
        size_t number = reinterpret_cast<size_t>(value);
        Local<BigInt> result = BigInt::NewFromUnsigned(isolate, number);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toBigInt"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

}
