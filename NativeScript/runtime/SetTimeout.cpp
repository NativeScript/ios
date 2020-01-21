#include <dispatch/dispatch.h>
#include "SetTimeout.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void SetTimeout::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> setTimeoutFuncTemplate = FunctionTemplate::New(isolate, SetTimeoutCallback);
    globalTemplate->Set(ToV8String(isolate, "setTimeout"), setTimeoutFuncTemplate);

    Local<FunctionTemplate> clearTimeoutFuncTemplate = FunctionTemplate::New(isolate, ClearTimeoutCallback);
    globalTemplate->Set(ToV8String(isolate, "clearTimeout"), clearTimeoutFuncTemplate);
}

void SetTimeout::SetTimeoutCallback(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!args[0]->IsFunction()) {
        tns::Assert(false, isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();

    double timeout = 0.0;
    if (args.Length() > 1 && args[1]->IsNumber()) {
        if (!args[1]->NumberValue(context).To(&timeout)) {
            tns::Assert(false, isolate);
        }
    }

    // TODO: implement better unique number generator
    uint32_t key = ++count_;
    Local<v8::Function> callback = args[0].As<v8::Function>();
    dispatch_block_t block = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{ Elapsed(key); });
    CacheEntry entry(isolate, new Persistent<v8::Function>(isolate, callback));
    cache_.insert(std::make_pair(key, entry));

    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC);
    dispatch_after(time, dispatch_get_main_queue(), block);

    args.GetReturnValue().Set(key);
}

void SetTimeout::ClearTimeoutCallback(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!args[0]->IsNumber()) {
        tns::Assert(false, isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();
    double value;
    if (!args[0]->NumberValue(context).To(&value)) {
        tns::Assert(false, isolate);
    }

    uint32_t key = value;
    auto it = cache_.find(key);
    if (it == cache_.end()) {
        return;
    }

    RemoveKey(key);
}

void SetTimeout::Elapsed(const uint32_t key) {
    auto it = cache_.find(key);
    if (it == cache_.end()) {
        return;
    }

    Isolate* isolate = it->second.isolate_;
    Persistent<v8::Function>* poCallback = it->second.callback_;
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<v8::Function> cb = poCallback->Get(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> result;
    if (!cb->Call(context, global, 0, nullptr).ToLocal(&result)) {
        tns::Assert(false, isolate);
    }

    RemoveKey(key);
}

void SetTimeout::RemoveKey(const uint32_t key) {
    auto it = cache_.find(key);
    if (it == cache_.end()) {
        return;
    }

    Persistent<v8::Function>* poCallback = it->second.callback_;
    poCallback->Reset();
    delete poCallback;
    cache_.erase(it);
}

std::unordered_map<uint32_t, SetTimeout::CacheEntry> SetTimeout::cache_;
uint32_t SetTimeout::count_ = 0;

}
