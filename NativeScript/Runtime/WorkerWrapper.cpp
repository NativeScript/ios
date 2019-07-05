#include <dispatch/dispatch.h>
#include "DataWrapper.h"
#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

void WorkerWrapper::PostMessage(std::string message) {
    if (!this->isTerminating_) {
        this->queue_->Push(message);
    }
}

void WorkerWrapper::Start(Persistent<Value>* poWorker, std::function<Isolate* ()> func) {
    this->poWorker_ = poWorker;
    nextId_++;
    this->workerId_ = nextId_;

    this->thread_ = std::thread(&WorkerWrapper::BackgroundLooper, this, func);

    this->isRunning_ = true;
}

void WorkerWrapper::BackgroundLooper(std::function<Isolate* ()> func) {
    this->workerIsolate_ = func();

    while (!this->isTerminating_) {
        std::string message = this->queue_->Pop();

        if (this->isTerminating_) {
            break;
        }

        HandleScope scope(this->workerIsolate_);
        Local<Context> context = this->workerIsolate_->GetCurrentContext();
        Local<Object> global = context->Global();

        TryCatch tc(this->workerIsolate_);
        this->onMessage_(this->workerIsolate_, global, message);

        if (tc.HasCaught()) {
            Local<Value> onErrorVal;
            bool success = global->Get(context, tns::ToV8String(this->workerIsolate_, "onerror")).ToLocal(&onErrorVal);
            assert(success);

            if (!onErrorVal.IsEmpty() && onErrorVal->IsFunction()) {
                Local<v8::Function> onErrorFunc = onErrorVal.As<v8::Function>();
                Local<Value> error = tc.Exception();
                Local<Value> args[1] = { error };
                Local<Value> result;
                TryCatch innerTc(this->workerIsolate_);
                success = onErrorFunc->Call(context, v8::Undefined(this->workerIsolate_), 1, args).ToLocal(&result);

                if (success && !result.IsEmpty() && result->BooleanValue(this->workerIsolate_)) {
                    // Do nothing, exception is handled and does not need to be raised to the main thread's onerror handler
                    continue;
                }

                if (!success && innerTc.HasCaught()) {
                    this->PassUncaughtExceptionFromWorkerToMain(this->workerIsolate_, innerTc);
                }

                this->PassUncaughtExceptionFromWorkerToMain(this->workerIsolate_, tc);
            }
        }
    }

    {
        HandleScope scope(this->workerIsolate_);
        Local<Context> context = this->workerIsolate_->GetCurrentContext();
        context->Exit();
        this->workerIsolate_->TerminateExecution();
    }

    this->workerIsolate_->Dispose();

    Caches::WorkerState* state = Caches::Workers.Get(this->workerId_);
    if (state != nullptr) {
        Caches::Workers.Remove(this->workerId_);
        delete state;
        state = nullptr;
    }

    Caches::Remove(this->workerIsolate_);

    Runtime* runtime = Runtime::GetCurrentRuntime();
    delete runtime;
}

void WorkerWrapper::Terminate() {
    if (!this->isTerminating_) {
        this->queue_->Notify();
        this->isTerminating_ = true;
        this->isRunning_ = false;
    }
}

void WorkerWrapper::PassUncaughtExceptionFromWorkerToMain(Isolate* workerIsolate, TryCatch& tc, bool async) {
    Local<Context> context = workerIsolate->GetCurrentContext();
    int lineNumber;
    bool success = tc.Message()->GetLineNumber(context).To(&lineNumber);
    assert(success);

    std::string message = tns::ToString(workerIsolate, tc.Message()->Get());
    Local<Value> source;
    success = tc.Message()->GetScriptResourceName()->ToString(context).ToLocal(&source);
    assert(success);
    std::string src = tns::ToString(workerIsolate, source);

    std::string stackTrace = "";

    Local<Value> stackTraceVal = tc.StackTrace(context).FromMaybe(Local<Value>());
    if (!stackTraceVal.IsEmpty()) {
        Local<v8::String> stackTraceStr = stackTraceVal->ToDetailString(context).FromMaybe(Local<v8::String>());
        if (!stackTraceStr.IsEmpty()) {
            stackTrace = tns::ToString(workerIsolate, stackTraceStr);
        }
    }

    tns::ExecuteOnMainThread([this, message, src, stackTrace, lineNumber]() {
        Local<Object> worker = this->poWorker_->Get(this->mainIsolate_).As<Object>();
        Local<Context> context = this->mainIsolate_->GetCurrentContext();

        Local<Value> onErrorVal;
        bool success = worker->Get(context, tns::ToV8String(this->mainIsolate_, "onerror")).ToLocal(&onErrorVal);
        assert(success);

        if (!onErrorVal.IsEmpty() && onErrorVal->IsFunction()) {
            Local<v8::Function> onErrorFunc = onErrorVal.As<v8::Function>();
            Local<Object> arg = this->ConstructErrorObject(this->mainIsolate_, message, src, stackTrace, lineNumber);
            Local<Value> args[1] = { arg };
            Local<Value> result;
            TryCatch tc(this->mainIsolate_);
            bool success = onErrorFunc->Call(context, v8::Undefined(this->mainIsolate_), 1, args).ToLocal(&result);
            if (!success && tc.HasCaught()) {
                Local<Value> error = tc.Exception();
                printf("%s\n", tns::ToString(this->mainIsolate_, error).c_str());
                this->mainIsolate_->ThrowException(error);
            }
        }
    }, async);
}

Local<Object> WorkerWrapper::ConstructErrorObject(Isolate* isolate, std::string message, std::string source, std::string stackTrace, int lineNumber) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);
    Local<Object> obj;
    bool success = objTemplate->NewInstance(context).ToLocal(&obj);
    assert(success);

    assert(obj->Set(context, tns::ToV8String(isolate, "message"), tns::ToV8String(isolate, message)).FromMaybe(false));
    assert(obj->Set(context, tns::ToV8String(isolate, "filename"), tns::ToV8String(isolate, source)).FromMaybe(false));
    assert(obj->Set(context, tns::ToV8String(isolate, "stackTrace"), tns::ToV8String(isolate, stackTrace)).FromMaybe(false));
    assert(obj->Set(context, tns::ToV8String(isolate, "lineno"), Number::New(isolate, lineNumber)).FromMaybe(false));

    return obj;
}

int WorkerWrapper::nextId_ = 0;

}
