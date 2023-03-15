#include <functional>
#include "ObjectManager.h"
#include "NativeScriptException.h"
#include "Worker.h"
#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"
#include "Constants.h"

using namespace v8;

namespace tns {

std::vector<std::string> Worker::GlobalFunctions = {
    "postMessage",
    "close"
};

void Worker::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate, bool isWorkerThread) {
    if (isWorkerThread) {
        // Register functions in the worker thread
        Local<FunctionTemplate> postMessageTemplate = FunctionTemplate::New(isolate, Worker::PostMessageToMainCallback);
        globalTemplate->Set(tns::ToV8String(isolate, "postMessage"), postMessageTemplate);

        Local<FunctionTemplate> closeTemplate = FunctionTemplate::New(isolate, Worker::CloseWorkerCallback);
        globalTemplate->Set(tns::ToV8String(isolate, "close"), closeTemplate);
    }
    // Register functions in the main thread
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
    Local<Context> context = isolate->GetCurrentContext();
    try {
        if (!info.IsConstructCall()) {
            throw NativeScriptException("Worker function must be called as a constructor.");
        }

        if (info.Length() < 1) {
            throw NativeScriptException("Not enough arguments.");
        }

        if (info.Length() > 1) {
            throw NativeScriptException("Too many arguments passed.");
        }

        if (!tns::IsString(info[0])) {
            throw NativeScriptException("Worker function must be called as a constructor.");
        }

        Local<Object> thiz = info.This();
        std::string workerPath = ToString(isolate, info[0]);
        // TODO: Validate worker path and call worker.onerror if the script does not exist

        WorkerWrapper* worker = new WorkerWrapper(isolate, Worker::OnMessageCallback);
        tns::SetValue(isolate, thiz, worker);
        std::shared_ptr<Persistent<Value>> poWorker = ObjectManager::Register(context, thiz);

        std::function<Isolate* ()> func([worker, workerPath]() {
            tns::Runtime* runtime = new tns::Runtime();
            Isolate* isolate = runtime->CreateIsolate();
            v8::Locker locker(isolate);
            runtime->Init(isolate, true);
            runtime->SetWorkerId(worker->WorkerId());
            int workerId = worker->WorkerId();
            Worker::SetWorkerId(isolate, workerId);

            TryCatch tc(isolate);
            runtime->RunModule(workerPath);
            if (tc.HasCaught()) {
                Isolate::Scope isolate_scope(isolate);
                HandleScope handle_scope(isolate);
                Local<Context> context = Caches::Get(isolate)->GetContext();
                worker->PassUncaughtExceptionFromWorkerToMain(context, tc, false);
                worker->Terminate();
            }

            return isolate;
        });

        worker->Start(poWorker, func);

        std::shared_ptr<Caches::WorkerState> state = std::make_shared<Caches::WorkerState>(isolate, poWorker, worker);
        int workerId = worker->Id();
        Caches::Workers->Insert(workerId, state);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void Worker::PostMessageToMainCallback(const FunctionCallbackInfo<Value>& info) {
    // Send message from worker to main
    Isolate* isolate = info.GetIsolate();

    try {
        if (info.Length() < 1) {
            throw NativeScriptException("Not enough arguments.");
        }
        
        if (info.Length() > 1) {
            throw NativeScriptException("Too many arguments passed.");
        }
        
        int workerId = Worker::GetWorkerId(isolate, info.This());
        std::shared_ptr<Caches::WorkerState> state = Caches::Workers->Get(workerId);
        tns::Assert(state != nullptr, isolate);
        WorkerWrapper* worker = static_cast<WorkerWrapper*>(state->UserData());
        if (!worker->IsRunning()) {
            return;
        }
        
        Local<Value> error;
        Local<Value> result = Worker::Serialize(isolate, info[0], error);
        if (result.IsEmpty()) {
            isolate->ThrowException(error);
            return;
        }
        
        std::string message = tns::ToString(isolate, result);
        
        auto runtime = static_cast<Runtime*>(state->GetIsolate()->GetData(Constants::RUNTIME_SLOT));
        if (runtime == nullptr) {
            return;
        }
        tns::ExecuteOnRunLoop(runtime->RuntimeLoop(), [state, message]() {
            Isolate* isolate = state->GetIsolate();
            v8::Locker locker(isolate);
            Isolate::Scope isolate_scope(isolate);
            HandleScope handle_scope(isolate);
            Local<Value> workerInstance = state->GetWorker()->Get(isolate);
            tns::Assert(!workerInstance.IsEmpty() && workerInstance->IsObject(), isolate);
            Worker::OnMessageCallback(isolate, workerInstance, message);
        });
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void Worker::PostMessageCallback(const FunctionCallbackInfo<Value>& info) {
    // Send message from main to worker
    Isolate* isolate = info.GetIsolate();
    try {
        if (info.Length() < 1) {
            throw NativeScriptException("Not enough arguments.");
            return;
        }

        if (info.Length() > 1) {
            throw NativeScriptException("Too many arguments passed.");
            return;
        }

        BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
        tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Worker, isolate);

        WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
        if (!worker->IsRunning() || worker->IsClosing()) {
            return;
        }

        Local<Value> error;
        Local<Value> result = Worker::Serialize(isolate, info[0], error);
        if (result.IsEmpty()) {
            isolate->ThrowException(error);
            return;
        }

        std::string message = tns::ToString(isolate, result);
        worker->PostMessage(message);
    } catch(NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void Worker::OnMessageCallback(Isolate* isolate, Local<Value> receiver, std::string message) {
    Local<Context> context = Caches::Get(isolate)->GetContext();
    Local<Value> onMessageValue;
    bool success = receiver.As<Object>()->Get(context, tns::ToV8String(isolate, "onmessage")).ToLocal(&onMessageValue);
    tns::Assert(success, isolate);

    if (!onMessageValue->IsFunction()) {
        return;
    }

    Local<v8::Function> onMessageFunc = onMessageValue.As<v8::Function>();
    Local<Value> result;

    Local<v8::String> messageStr = tns::ToV8String(isolate, message);
    Local<Value> arg;
    success = v8::JSON::Parse(context, messageStr).ToLocal(&arg);
    tns::Assert(success, isolate);

    Local<Value> args[1] { arg };
    success = onMessageFunc->Call(context, receiver, 1, args).ToLocal(&result);
}

void Worker::CloseWorkerCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    int workerId = Worker::GetWorkerId(isolate, info.This());
    std::shared_ptr<Caches::WorkerState> state = Caches::Workers->Get(workerId);
    tns::Assert(state != nullptr, isolate);
    WorkerWrapper* worker = static_cast<WorkerWrapper*>(state->UserData());

    if (!worker->IsRunning() || worker->IsClosing()) {
        return;
    }

    worker->Close();

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> onCloseVal;
    bool success = global->Get(context, tns::ToV8String(isolate, "onclose")).ToLocal(&onCloseVal);
    tns::Assert(success, isolate);
    if (!onCloseVal.IsEmpty() && onCloseVal->IsFunction()) {
        Local<v8::Function> onCloseFunc = onCloseVal.As<v8::Function>();
        Local<Value> args[0] { };
        Local<Value> result;
        TryCatch tc(isolate);
        success = onCloseFunc->Call(context, v8::Undefined(isolate), 0, args).ToLocal(&result);
        if (!success && tc.HasCaught()) {
            worker->CallOnErrorHandlers(tc);
        }
    }
}

void Worker::TerminateCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Worker, isolate);

    WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
    worker->Terminate();
}

Local<v8::String> Worker::Serialize(Isolate* isolate, Local<Value> value, Local<Value>& error) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);

    Local<Object> obj;
    bool success = objTemplate->NewInstance(context).ToLocal(&obj);
    tns::Assert(success, isolate);

    success = obj->Set(context, tns::ToV8String(isolate, "data"), value).FromMaybe(false);
    tns::Assert(success, isolate);

    Local<Value> result;
    TryCatch tc(isolate);
    success = v8::JSON::Stringify(context, obj).ToLocal(&result);
    if (!success && tc.HasCaught()) {
        error = tc.Exception();
        return Local<v8::String>();
    }

    tns::Assert(success, isolate);

    return result.As<v8::String>();
}

void Worker::SetWorkerId(Isolate* isolate, int workerId) {
    HandleScope scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    global->SetPrivate(context, Private::ForApi(isolate, tns::ToV8String(isolate, "workerId")), Number::New(isolate, workerId));
}

int Worker::GetWorkerId(Isolate* isolate, Local<Object> global) {
    Local<Value> value;

    Local<Context> context = isolate->GetCurrentContext();
    bool success = global->GetPrivate(context, Private::ForApi(isolate, tns::ToV8String(isolate, "workerId"))).ToLocal(&value);
    tns::Assert(success && value->IsNumber(), isolate);

    Local<Number> number = value.As<Number>();
    return number->Value();
}

}
