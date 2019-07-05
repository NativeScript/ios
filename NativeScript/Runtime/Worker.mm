#include <Foundation/Foundation.h>
#include <functional>
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Worker.h"
#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

void Worker::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> workerFuncTemplate = FunctionTemplate::New(isolate, ConstructorCallback);
    workerFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<v8::String> workerFuncName = ToV8String(isolate, "Worker");
    workerFuncTemplate->SetClassName(workerFuncName);

    Local<ObjectTemplate> prototype = workerFuncTemplate->PrototypeTemplate();
    Local<FunctionTemplate> postMessageFuncTemplate = FunctionTemplate::New(isolate, PostMessageCallback);
    Local<FunctionTemplate> terminateWorkerFuncTemplate = FunctionTemplate::New(isolate, TerminateCallback);

    prototype->Set(ToV8String(isolate, "postMessage"), postMessageFuncTemplate);
    prototype->Set(ToV8String(isolate, "terminate"), terminateWorkerFuncTemplate);

    globalTemplate->Set(workerFuncName, workerFuncTemplate);
}

void Worker::ConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    if (!info.IsConstructCall()) {
        tns::ThrowError(isolate, "Worker function must be called as a constructor.");
        return;
    }

    if (info.Length() < 1) {
        tns::ThrowError(isolate, "Not enough arguments.");
        return;
    }

    if (info.Length() > 1) {
        tns::ThrowError(isolate, "Too many arguments passed.");
        return;
    }

    if (!tns::IsString(info[0])) {
        tns::ThrowError(isolate, "Worker function must be called as a constructor.");
        return;
    }

    Local<Object> thiz = info.This();
    std::string workerPath = ToString(isolate, info[0]);
    // TODO: Validate worker path and call worker.onerror if the script does not exist

    WorkerWrapper* worker = new WorkerWrapper(isolate, Worker::OnMessageCallback);
    tns::SetValue(isolate, thiz, worker);
    Persistent<Value>* poWorker = ObjectManager::Register(isolate, thiz);

    std::function<Isolate* ()> func([worker, workerPath]() {
        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        NSArray* components = [NSArray arrayWithObjects:resourcePath, @"app", nil];
        NSString* path = [NSString pathWithComponents:components];

        std::string baseDir = [path UTF8String];
        tns::Runtime* runtime = new tns::Runtime();
        runtime->Init(baseDir);
        runtime->SetWorkerId(worker->WorkerId());
        Isolate* workerIsolate = runtime->GetIsolate();

        TryCatch tc(workerIsolate);
        runtime->RunScript(workerPath, tc);
        if (tc.HasCaught()) {
            HandleScope scope(workerIsolate);
            worker->PassUncaughtExceptionFromWorkerToMain(workerIsolate, tc, false);
            worker->Terminate();
        }

        return workerIsolate;
    });

    worker->Start(poWorker, func);

    Caches::WorkerState* state = new Caches::WorkerState(isolate, poWorker);
    int workerId = worker->Id();
    Caches::Workers.Insert(workerId, state);
}

void Worker::RegisterGlobals(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> postMessageTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        // Send message from worker to main

        Isolate* isolate = info.GetIsolate();

        if (info.Length() < 1) {
            tns::ThrowError(isolate, "Not enough arguments.");
            return;
        }

        if (info.Length() > 1) {
            tns::ThrowError(isolate, "Too many arguments passed.");
            return;
        }

        Runtime* runtime = Runtime::GetCurrentRuntime();
        int workerId = runtime->WorkerId();
        Caches::WorkerState* state = Caches::Workers.Get(workerId);
        assert(state != nullptr);

        Local<Value> error;
        Local<Value> result = Worker::Serialize(isolate, info[0], error);
        if (result.IsEmpty()) {
            isolate->ThrowException(error);
            return;
        }

        std::string message = tns::ToString(isolate, result);

        tns::ExecuteOnMainThread([state, message]() {
            Isolate* isolate = state->GetIsolate();
            Local<Value> workerInstance = state->GetWorker()->Get(isolate);
            assert(!workerInstance.IsEmpty() && workerInstance->IsObject());
            Worker::OnMessageCallback(isolate, workerInstance, message);
        });
    });

    globalTemplate->Set(tns::ToV8String(isolate, "postMessage"), postMessageTemplate);
}

void Worker::PostMessageCallback(const FunctionCallbackInfo<Value>& info) {
    // Send message from main to worker

    Isolate* isolate = info.GetIsolate();

    if (info.Length() < 1) {
        tns::ThrowError(isolate, "Not enough arguments.");
        return;
    }

    if (info.Length() > 1) {
        tns::ThrowError(isolate, "Too many arguments passed.");
        return;
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    assert(wrapper != nullptr && wrapper->Type() == WrapperType::Worker);

    Local<Value> error;
    Local<Value> result = Worker::Serialize(isolate, info[0], error);
    if (result.IsEmpty()) {
        isolate->ThrowException(error);
        return;
    }

    std::string message = tns::ToString(isolate, result);

    WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
    worker->PostMessage(message);
}

void Worker::OnMessageCallback(Isolate* isolate, Local<Value> receiver, std::string message) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> onMessageValue;
    bool success = receiver.As<Object>()->Get(context, tns::ToV8String(isolate, "onmessage")).ToLocal(&onMessageValue);
    assert(success);

    if (!onMessageValue->IsFunction()) {
        return;
    }

    Local<v8::Function> onMessageFunc = onMessageValue.As<v8::Function>();
    Local<Value> result;

    Local<v8::String> messageStr = tns::ToV8String(isolate, message);
    Local<Value> arg;
    success = v8::JSON::Parse(context, messageStr).ToLocal(&arg);
    assert(success);

    Local<Value> args[1] { arg };
    success = onMessageFunc->Call(context, receiver, 1, args).ToLocal(&result);
}

void Worker::TerminateCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    assert(wrapper != nullptr && wrapper->Type() == WrapperType::Worker);

    WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
    worker->Terminate();
}

Local<v8::String> Worker::Serialize(Isolate* isolate, Local<Value> value, Local<Value>& error) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);

    Local<Object> obj;
    bool success = objTemplate->NewInstance(context).ToLocal(&obj);
    assert(success);

    success = obj->Set(context, tns::ToV8String(isolate, "data"), value).FromMaybe(false);
    assert(success);

    Local<Value> result;
    TryCatch tc(isolate);
    success = v8::JSON::Stringify(context, obj).ToLocal(&result);
    if (!success && tc.HasCaught()) {
        error = tc.Exception();
        return Local<v8::String>();
    }

    assert(success);

    return result.As<v8::String>();
}

}
