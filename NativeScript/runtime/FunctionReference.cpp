#include "FunctionReference.h"
#include "Caches.h"
#include "ObjectManager.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void FunctionReference::Register(Isolate* isolate, Local<Object> interop) {
    Local<v8::Function> ctorFunc = FunctionReference::GetFunctionReferenceCtorFunc(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = interop->Set(context, tns::ToV8String(isolate, "FunctionReference"), ctorFunc).FromMaybe(false);
    tns::Assert(success, isolate);
}

Local<v8::Function> FunctionReference::GetFunctionReferenceCtorFunc(Isolate* isolate) {
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* poFunctionReferenceCtor = cache->FunctionReferenceCtorFunc.get();
    if (poFunctionReferenceCtor != nullptr) {
        return poFunctionReferenceCtor->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, FunctionReferenceConstructorCallback);

    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "FunctionReference"));

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        tns::Assert(false, isolate);
    }

    tns::SetValue(isolate, ctorFunc, new FunctionReferenceTypeWrapper());

    cache->FunctionReferenceCtorFunc = std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc);

    return ctorFunc;
}

void FunctionReference::FunctionReferenceConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    tns::Assert(info.Length() == 1, isolate);
    tns::Assert(info[0]->IsFunction(), isolate);

    Local<v8::Function> arg = info[0].As<v8::Function>();
    std::shared_ptr<Persistent<v8::Value>> poArg = ObjectManager::Register(context, arg);
    FunctionReferenceWrapper* wrapper = new FunctionReferenceWrapper(poArg);
    tns::SetValue(isolate, arg, wrapper);
    info.GetReturnValue().Set(arg);
}

}
