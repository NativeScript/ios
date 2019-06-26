#include "FunctionReference.h"
#include "ObjectManager.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void FunctionReference::Register(Isolate* isolate, Local<Object> interop) {
    Local<v8::Function> ctorFunc = FunctionReference::GetFunctionReferenceCtorFunc(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = interop->Set(context, tns::ToV8String(isolate, "FunctionReference"), ctorFunc).FromMaybe(false);
    assert(success);
}

Local<v8::Function> FunctionReference::GetFunctionReferenceCtorFunc(Isolate* isolate) {
    if (functionReferenceCtorFunc_ != nullptr) {
        return functionReferenceCtorFunc_->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, FunctionReferenceConstructorCallback);

    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "FunctionReference"));

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    tns::SetValue(isolate, ctorFunc, new FunctionReferenceTypeWrapper());

    functionReferenceCtorFunc_ = new Persistent<v8::Function>(isolate, ctorFunc);

    return ctorFunc;
}

void FunctionReference::FunctionReferenceConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    assert(info.Length() == 1);
    assert(info[0]->IsFunction());

    Isolate* isolate = info.GetIsolate();

    Local<v8::Function> arg = info[0].As<v8::Function>();
    Persistent<v8::Function>* poArg = new Persistent<v8::Function>(isolate, arg);

    FunctionReferenceWrapper* wrapper = new FunctionReferenceWrapper(poArg);
    tns::SetValue(isolate, info.This(), wrapper);
    ObjectManager::Register(isolate, info.This());
}

Persistent<v8::Function>* FunctionReference::functionReferenceCtorFunc_;

}
