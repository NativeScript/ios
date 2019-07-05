#include "WeakRef.h"
#include "ArgConverter.h"
#include "Caches.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void WeakRef::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> weakRefCtorFuncTemplate = FunctionTemplate::New(isolate, ConstructorCallback, Local<Value>());

    Local<v8::String> name = tns::ToV8String(isolate, "WeakRef");
    weakRefCtorFuncTemplate->SetClassName(name);
    globalTemplate->Set(name, weakRefCtorFuncTemplate);
}

void WeakRef::ConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.IsConstructCall());
    Isolate* isolate = info.GetIsolate();

    if (info.Length() < 1 || !info[0]->IsObject()) {
        tns::ThrowError(isolate, "Argument must be an object.");
        return;
    }

    Local<Object> target = info[0].As<Object>();
    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> weakRef = ArgConverter::CreateEmptyObject(context);

    Persistent<Object>* poTarget = new Persistent<Object>(isolate, target);
    Persistent<Object>* poHolder = new Persistent<Object>(isolate, weakRef);
    CallbackState* callbackState = new CallbackState(poTarget, poHolder);

    poTarget->SetWeak(callbackState, WeakTargetCallback, WeakCallbackType::kFinalizer);
    poHolder->SetWeak(callbackState, WeakHolderCallback, WeakCallbackType::kFinalizer);

    bool success = weakRef->Set(context, tns::ToV8String(isolate, "get"), GetGetterFunction(isolate)).FromMaybe(false);
    assert(success);

    success = weakRef->Set(context, tns::ToV8String(isolate, "clear"), GetClearFunction(isolate)).FromMaybe(false);
    assert(success);

    tns::SetPrivateValue(isolate, weakRef, tns::ToV8String(isolate, "target"), External::New(isolate, poTarget));

    info.GetReturnValue().Set(weakRef);
}

void WeakRef::WeakTargetCallback(const WeakCallbackInfo<CallbackState>& data) {\
    CallbackState* callbackState = data.GetParameter();
    Persistent<Object>* poTarget = callbackState->target_;
    poTarget->Reset();
    delete poTarget;
    callbackState->target_ = nullptr;

    Isolate* isolate = data.GetIsolate();
    Persistent<Object>* poHolder = callbackState->holder_;
    if (poHolder != nullptr) {
        Local<Object> holder = poHolder->Get(isolate);
        tns::SetPrivateValue(isolate, holder, tns::ToV8String(isolate, "target"), External::New(isolate, nullptr));
    }

    if (callbackState->holder_ == nullptr) {
        delete callbackState;
    }
}

void WeakRef::WeakHolderCallback(const WeakCallbackInfo<CallbackState>& data) {
    CallbackState* callbackState = data.GetParameter();
    Persistent<Object>* poHolder = callbackState->holder_;
    Isolate* isolate = data.GetIsolate();
    Local<Object> holder = Local<Object>::New(isolate, *poHolder);

    Local<Value> hiddenVal = tns::GetPrivateValue(isolate, holder, tns::ToV8String(isolate, "target"));
    Persistent<Object>* poTarget = reinterpret_cast<Persistent<Object>*>(hiddenVal.As<External>()->Value());

    if (poTarget != nullptr) {
        poHolder->SetWeak(callbackState, WeakHolderCallback, WeakCallbackType::kFinalizer);
    } else {
        poHolder->Reset();
        delete poHolder;
        callbackState->holder_ = nullptr;
        if (callbackState->target_ == nullptr) {
            delete callbackState;
        }
    }
}

Local<v8::Function> WeakRef::GetGetterFunction(Isolate* isolate) {
    Persistent<v8::Function>* poGetter = Caches::Get(isolate)->WeakRefGetterFunc;
    if (poGetter != nullptr) {
        return poGetter->Get(isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> getterFunc = FunctionTemplate::New(isolate, GetCallback)->GetFunction(context).ToLocalChecked();
    Caches::Get(isolate)->WeakRefGetterFunc = new Persistent<v8::Function>(isolate, getterFunc);
    return getterFunc;
}

Local<v8::Function> WeakRef::GetClearFunction(Isolate* isolate) {
    Persistent<v8::Function>* poClear = Caches::Get(isolate)->WeakRefClearFunc;
    if (poClear != nullptr) {
        return poClear->Get(isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> clearFunc = FunctionTemplate::New(isolate, ClearCallback)->GetFunction(context).ToLocalChecked();
    Caches::Get(isolate)->WeakRefClearFunc = new Persistent<v8::Function>(isolate, clearFunc);
    return clearFunc;
}

void WeakRef::GetCallback(const FunctionCallbackInfo<Value>& info) {
    Local<Object> holder = info.This();
    Isolate* isolate = info.GetIsolate();
    Local<Value> hiddenVal = tns::GetPrivateValue(isolate, holder, tns::ToV8String(isolate, "target"));
    Persistent<Object>* poTarget = reinterpret_cast<Persistent<Object>*>(hiddenVal.As<External>()->Value());

    if (poTarget != nullptr) {
        Local<Object> target = poTarget->Get(isolate);
        info.GetReturnValue().Set(target);
    } else {
        info.GetReturnValue().Set(Null(isolate));
    }
}

void WeakRef::ClearCallback(const FunctionCallbackInfo<Value>& info) {
    Local<Object> holder = info.This();
    Isolate* isolate = info.GetIsolate();
    tns::SetPrivateValue(isolate, holder, tns::ToV8String(isolate, "target"), External::New(isolate, nullptr));
}

}
