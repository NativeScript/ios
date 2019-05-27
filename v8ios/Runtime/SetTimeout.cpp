#include <dispatch/dispatch.h>
#include "SetTimeout.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void SetTimeout::Init(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<Function> setTimeoutFunc;
    if (!Function::New(context, SetTimeoutCallback).ToLocal(&setTimeoutFunc)) {
        assert(false);
    }

    if (!global->Set(context, ToV8String(isolate, "setTimeout"), setTimeoutFunc).FromMaybe(false)) {
        assert(false);
    }

    Local<Function> clearTimeoutFunc;
    if (!Function::New(context, ClearTimeoutCallback).ToLocal(&clearTimeoutFunc)) {
        assert(false);
    }

    if (!global->Set(context, ToV8String(isolate, "clearTimeout"), clearTimeoutFunc).FromMaybe(false)) {
        assert(false);
    }
}

void SetTimeout::SetTimeoutCallback(const FunctionCallbackInfo<Value>& args) {
    if (!args[0]->IsFunction()) {
        assert(false);
    }

    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    double timeout = 0.0;
    if (args.Length() > 1 && args[1]->IsNumber()) {
        if (!args[1]->NumberValue(context).To(&timeout)) {
            assert(false);
        }
    }

    // TODO: implement better unique number generator
    uint32_t key = ++count_;
    Local<Function> callback = args[0].As<Function>();
    dispatch_block_t block = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{ Elapsed(key); });
    CacheEntry entry(isolate, new Persistent<Function>(isolate, callback));
    cache_.insert(std::make_pair(key, entry));

    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC);
    dispatch_after(time, dispatch_get_main_queue(), block);

    args.GetReturnValue().Set(key);
}

void SetTimeout::ClearTimeoutCallback(const FunctionCallbackInfo<Value>& args) {
    if (!args[0]->IsNumber()) {
        assert(false);
    }

    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    double value;
    if (!args[0]->NumberValue(context).To(&value)) {
        assert(false);
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
    Persistent<Function>* poCallback = it->second.callback_;
    HandleScope handle_scope(isolate);

    Local<Function> cb = Local<Function>::New(isolate, *poCallback);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> result;
    if (!cb->Call(context, global, 0, nullptr).ToLocal(&result)) {
        assert(false);
    }

    RemoveKey(key);
}

void SetTimeout::RemoveKey(const uint32_t key) {
    auto it = cache_.find(key);
    if (it == cache_.end()) {
        return;
    }

    Persistent<Function>* poCallback = it->second.callback_;
    poCallback->Reset();
    delete poCallback;
    cache_.erase(it);
}

std::map<uint32_t, SetTimeout::CacheEntry> SetTimeout::cache_;
uint32_t SetTimeout::count_ = 0;

}
