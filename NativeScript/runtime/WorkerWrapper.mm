#include <Foundation/Foundation.h>
#include "Caches.h"
#include "Constants.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "Worker.h"
#include "inspector/JsV8InspectorClient.h"
#include "inspector/WorkerInspectorClient.h"

using namespace v8;

namespace tns {

static NSOperationQueue* workers_ = nil;

__attribute__((constructor)) void staticInitMethod() {
  workers_ = [[NSOperationQueue alloc] init];
  workers_.maxConcurrentOperationCount = 100;
}

// Posts to the target runtime's internal lane from the worker thread. When
// async is false, blocks until the entry ran - or until it is destroyed
// unrun by a shutdown that raced the post, which must release the waiter too.
static void PostToRuntimeLoop(Runtime* runtime, std::function<void()> fn, bool async) {
  auto loop = runtime->GetEventLoop();
  if (loop == nullptr) {
    return;
  }
  if (async) {
    loop->PostInternal(std::move(fn));
    return;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  // signals when the LAST reference dies: after fn ran, or when Shutdown
  // clears the queue and destroys the entry without running it
  std::shared_ptr<void> completion(nullptr, [done](void*) { dispatch_semaphore_signal(done); });
  bool posted = loop->PostInternal([fn = std::move(fn), completion]() { fn(); });
  completion.reset();
  if (posted) {
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  }
}

WorkerWrapper::WorkerWrapper(
    v8::Isolate* mainIsolate,
    std::function<void(v8::Isolate*, v8::Local<v8::Object> thiz, std::shared_ptr<worker::Message>)>
        onMessage)
    : mainIsolate_(mainIsolate),
      workerIsolate_(nullptr),
      isRunning_(false),
      isClosing_(false),
      isTerminating_(false),
      isDisposed_(false),
      isWeak_(false),
      messagesEnabled_(false),
      onMessage_(onMessage) {}

const WrapperType WorkerWrapper::Type() { return WrapperType::Worker; }

const int WorkerWrapper::Id() { return this->workerId_; }

const bool WorkerWrapper::IsRunning() { return this->isRunning_; }

const bool WorkerWrapper::IsClosing() { return this->isClosing_; }

const int WorkerWrapper::WorkerId() { return this->workerId_; }

void WorkerWrapper::PostMessage(std::shared_ptr<worker::Message> message) {
  if (!this->isTerminating_ && !this->isClosing_) {
    this->queue_.Push(message);
  }
}

void WorkerWrapper::Start(std::shared_ptr<Persistent<Value>> poWorker,
                          std::function<Isolate*()> func, int qualityOfService) {
  this->poWorker_ = poWorker;
  this->workerId_ = nextId_.fetch_add(1, std::memory_order_relaxed) + 1;

  NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
    this->BackgroundLooper(func);
  }];

  if (qualityOfService >= 0) {
    op.qualityOfService = static_cast<NSQualityOfService>(qualityOfService);
  }

  [workers_ addOperation:op];

  this->isRunning_ = true;
}

void WorkerWrapper::DrainPendingTasks() {
  // The drain source is armed (and can be signaled by a main-thread
  // PostMessage) BEFORE `workerIsolate_` is assigned in BackgroundLooper, and
  // worker creation spins this runloop inside that window: the entry's module
  // graph load pumps it while waiting on fetches, which fires this source with
  // a null isolate (crash in v8::Locker::Initialize). Bail until the isolate
  // exists — the messages stay queued and the explicit DrainPendingTasks()
  // call right after isolate creation delivers them.
  if (this->workerIsolate_ == nullptr) {
    return;
  }
  v8::Locker locker(this->workerIsolate_);
  Isolate::Scope isolate_scope(this->workerIsolate_);
  HandleScope handle_scope(this->workerIsolate_);

  // WHATWG parity: the implicit port's message queue starts disabled and is
  // enabled by Worker.mm once the entry script has finished evaluating
  // (including after a pending top-level await settles). Until then messages
  // stay buffered here; afterwards every message dispatches whether or not a
  // handler exists — a handler installed later misses earlier messages,
  // exactly as on the web.
  if (!this->messagesEnabled_.load(std::memory_order_acquire)) {
    return;
  }

  // Messages dispatch on the EventTarget backing the global scope's listener
  // methods rather than on globalThis, so app code replacing
  // globalThis.dispatchEvent cannot intercept delivery.
  auto cache = Caches::Get(this->workerIsolate_);
  if (cache->GlobalEventTarget == nullptr) {
    return;
  }
  Local<Object> globalTarget = cache->GlobalEventTarget->Get(this->workerIsolate_);
  if (globalTarget.IsEmpty()) {
    return;
  }

  std::vector<std::shared_ptr<worker::Message>> messages = this->queue_.PopAll();

  for (std::shared_ptr<worker::Message> message : messages) {
    if (this->isTerminating_ || this->isClosing_) {
      break;
    }
    TryCatch tc(this->workerIsolate_);
    this->onMessage_(this->workerIsolate_, globalTarget, message);

    if (tc.HasCaught()) {
      this->CallOnErrorHandlers(tc);
    }
  }

  if (this->isClosing_) {
    bool wasTerminating = this->isTerminating_.exchange(true);
    if (!wasTerminating) {
      this->queue_.Terminate();
      this->isRunning_ = false;
    }
  }
}

void WorkerWrapper::BackgroundLooper(std::function<Isolate*()> func) {
  if (!this->isTerminating_) {
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    this->queue_.Initialize(
        runLoop,
        [](void* info) {
          WorkerWrapper* w = static_cast<WorkerWrapper*>(info);
          w->DrainPendingTasks();
        },
        this);

    this->workerIsolate_ = func();

    this->DrainPendingTasks();

    // check again as it could terminate before this
    if (!this->isTerminating_) {
      CFRunLoopRun();
    }
  }

  // The inspector must be gone before the Runtime (and with it the isolate)
  // is deleted below.
  this->DestroyInspector();

  this->isDisposed_ = true;
  Runtime* runtime = Runtime::GetCurrentRuntime();
  if (runtime != nullptr) {
    delete runtime;
  } else {
    // Runtime was never created (worker terminated before initialization).
    // The runtime destructor normally handles this cleanup, so do it here.
    int workerId = this->workerId_;
    bool found;
    auto state = Caches::Workers->Get(workerId, found);
    if (found) {
      Caches::Workers->Remove(workerId);
    }
  }
}

void WorkerWrapper::EnableMessageQueue() {
  this->messagesEnabled_.store(true, std::memory_order_release);
  this->queue_.Signal();
}

void WorkerWrapper::Close() { this->isClosing_ = true; }

void WorkerWrapper::Terminate() {
  // set terminating to true atomically
  bool wasTerminating = this->isTerminating_.exchange(true);
  if (!wasTerminating) {
    if (this->workerIsolate_ != nullptr) {
      // Flagged before the request so a pump that is between iterations sees
      // it on its next check, rather than only once V8 has some JS to
      // interrupt — which a parked graph never provides.
      //
      // NOTE: `workerIsolate_` is assigned only after the worker's ENTRY has
      // finished evaluating, so a worker still parked in its entry is not
      // reachable from here at all and terminate() does nothing for it. That
      // is a pre-existing worker-lifecycle gap, not something this flag can
      // close — see the follow-up filed for it.
      if (Runtime* workerRuntime = Runtime::GetRuntime(this->workerIsolate_)) {
        workerRuntime->RequestTermination();
      }
      this->workerIsolate_->TerminateExecution();
    }
    {
      // A worker paused at a breakpoint sits in the inspector's nested pause
      // loop, not in the CFRunLoop — kick it loose so TerminateExecution and
      // the runloop stop below can take effect.
      std::lock_guard<std::mutex> lock(this->inspectorMutex_);
      if (this->inspector_ != nullptr) {
        this->inspector_->NotifyTerminating();
      }
    }
    this->queue_.Terminate();
    this->isRunning_ = false;
  }
}

void WorkerWrapper::CreateInspector(Isolate* isolate, const std::string& scriptPath) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

  v8_inspector::JsV8InspectorClient* root = v8_inspector::JsV8InspectorClient::GetInstance();
  if (root == nullptr) {
    return;
  }

  // Same url scheme the module loader reports in Debugger.scriptParsed.
  std::string url = "file://" + ReplaceAll(scriptPath, RuntimeConfig.BaseDir, "");

  auto* client =
      new v8_inspector::WorkerInspectorClient(this->workerId_, isolate, CFRunLoopGetCurrent(), url);
  {
    std::lock_guard<std::mutex> lock(this->inspectorMutex_);
    this->inspector_ = client;
  }

  // Only register once the client is fully constructed: registration makes
  // it reachable from the socket thread.
  root->RegisterWorkerTarget(this->workerId_, client);
}

void WorkerWrapper::DestroyInspector() {
  v8_inspector::WorkerInspectorClient* client = nullptr;
  {
    std::lock_guard<std::mutex> lock(this->inspectorMutex_);
    client = this->inspector_;
    this->inspector_ = nullptr;
  }

  if (client == nullptr) {
    return;
  }

  // Unregister first: after this returns no other thread can reach the
  // client (routing holds the registry lock while pushing messages).
  v8_inspector::JsV8InspectorClient* root = v8_inspector::JsV8InspectorClient::GetInstance();
  if (root != nullptr) {
    root->UnregisterWorkerTarget(this->workerId_);
  }

  delete client;
}

void WorkerWrapper::CallOnErrorHandlers(TryCatch& tc) {
  if (this->isTerminating_) {
    return;
  }
  Isolate* isolate = this->workerIsolate_;
  Local<Context> context = Caches::Get(isolate)->GetContext();
  Local<Object> global = context->Global();

  Local<Value> onErrorVal;
  if (global->Get(context, tns::ToV8String(isolate, "onerror")).ToLocal(&onErrorVal) &&
      !onErrorVal.IsEmpty() && onErrorVal->IsFunction()) {
    Local<Value> args[1] = {tc.Exception()};
    Local<Value> result;
    TryCatch innerTc(isolate);
    bool called = onErrorVal.As<v8::Function>()
                      ->Call(context, v8::Undefined(isolate), 1, args)
                      .ToLocal(&result);
    if (called && !result.IsEmpty() && result->BooleanValue(isolate)) {
      // Truthy return means handled, which is where the web stops propagation.
      return;
    }
    if (!called && innerTc.HasCaught()) {
      // The handler itself threw; that error is what the parent should see.
      this->PassUncaughtExceptionFromWorkerToMain(context, innerTc);
      return;
    }
  }

  // Unhandled at the worker scope — including when there is no scope handler
  // at all — so it becomes the parent's error event.
  this->PassUncaughtExceptionFromWorkerToMain(context, tc);
}

void WorkerWrapper::ReportEntryEvaluationRejection(Local<Context> context, Local<Value> reason) {
  if (this->isTerminating_) {
    return;
  }
  Isolate* isolate = this->workerIsolate_;
  Local<Object> global = context->Global();

  Local<Value> onErrorVal;
  if (global->Get(context, tns::ToV8String(isolate, "onerror")).ToLocal(&onErrorVal) &&
      !onErrorVal.IsEmpty() && onErrorVal->IsFunction()) {
    Local<Value> args[1] = {reason};
    Local<Value> result;
    TryCatch innerTc(isolate);
    bool called = onErrorVal.As<v8::Function>()
                      ->Call(context, v8::Undefined(isolate), 1, args)
                      .ToLocal(&result);
    if (called && !result.IsEmpty() && result->BooleanValue(isolate)) {
      // Truthy return means handled, which is where the web stops propagation.
      return;
    }
    if (!called && innerTc.HasCaught()) {
      // The handler itself threw; that error is what the parent should see.
      this->PassUncaughtExceptionFromWorkerToMain(context, innerTc);
      return;
    }
  }

  // Unhandled at the worker scope, so it becomes the parent's error event.
  // One emptiness test up front: every read below — the string conversion as
  // much as the stack lookup — needs a real handle, and only the stack read
  // used to be guarded.
  std::string message = "<no reason>";
  std::string stackTrace;
  std::string source;
  int lineNumber = 0;
  if (!reason.IsEmpty()) {
    message = tns::ToString(isolate, reason);
    if (reason->IsObject()) {
      Local<Object> reasonObj = reason.As<Object>();
      Local<Value> stackVal;
      if (reasonObj->Get(context, tns::ToV8String(isolate, "stack")).ToLocal(&stackVal) &&
          !stackVal->IsUndefined()) {
        stackTrace = tns::ToString(isolate, stackVal);
      }
    }
  }
  this->PassUncaughtExceptionFromWorkerToMain(message, source, stackTrace, lineNumber, true);
}

void WorkerWrapper::PassUncaughtExceptionFromWorkerToMain(Local<Context> context, TryCatch& tc,
                                                          bool async) {
  Isolate* workerIsolate = v8::Isolate::GetCurrent();
  int lineNumber = 0;
  std::string message = "";
  std::string src = "";

  // Check if we have a proper V8 message (for syntax errors, etc.)
  if (!tc.Message().IsEmpty()) {
    bool success = tc.Message()->GetLineNumber(context).To(&lineNumber);
    if (success) {
      message = tns::ToString(workerIsolate, tc.Message()->Get());
      Local<Value> source;
      success = tc.Message()->GetScriptResourceName()->ToString(context).ToLocal(&source);
      if (success) {
        src = tns::ToString(workerIsolate, source);
      }
    }
  }

  // If we couldn't get message info from tc.Message(), extract from the exception itself
  if (message.empty() && !tc.Exception().IsEmpty()) {
    message = tns::ToString(workerIsolate, tc.Exception());
    src = "Worker script";
    lineNumber = 1;
  }

  std::string stackTrace = "";

  Local<Value> stackTraceVal = tc.StackTrace(context).FromMaybe(Local<Value>());
  if (!stackTraceVal.IsEmpty()) {
    Local<v8::String> stackTraceStr =
        stackTraceVal->ToDetailString(context).FromMaybe(Local<v8::String>());
    if (!stackTraceStr.IsEmpty()) {
      stackTrace = tns::ToString(workerIsolate, stackTraceStr);
    }
  }

  this->ForwardErrorPayloadToMain(message, src, stackTrace, lineNumber, async);
}

void WorkerWrapper::PassUncaughtExceptionFromWorkerToMain(const std::string& message,
                                                          const std::string& source,
                                                          const std::string& stackTrace,
                                                          int lineNumber, bool async) {
  this->ForwardErrorPayloadToMain(message, source, stackTrace, lineNumber, async);
}

void WorkerWrapper::PassUncaughtRejectionToMain(const std::string& message,
                                                const std::string& source,
                                                const std::string& stackTrace, int lineNumber,
                                                bool async) {
  if (this->isTerminating_ || this->isDisposed_) {
    return;
  }
  this->ForwardErrorPayloadToMain(message, source, stackTrace, lineNumber, async);
}

void WorkerWrapper::ForwardErrorPayloadToMain(const std::string& message, const std::string& source,
                                              const std::string& stackTrace, int lineNumber,
                                              bool async) {
  auto runtime = static_cast<Runtime*>(mainIsolate_->GetData(Constants::RUNTIME_SLOT));
  if (runtime == nullptr) {
    return;
  }
  // Captured by value, never `this`: the wrapper dies with the worker thread's
  // teardown while this entry may still be queued on the parent's loop. The
  // shared_ptr keeps the Persistent object alive; a teardown-reset handle
  // surfaces as the empty-worker bail below. The isolate pointer stays valid
  // for as long as the loop runs entries — the loop shuts down before the
  // isolate is disposed, and posts after that are dropped.
  Isolate* mainIsolate = this->mainIsolate_;
  std::shared_ptr<Persistent<Value>> poWorker = this->poWorker_;
  if (poWorker == nullptr) {
    return;
  }
  PostToRuntimeLoop(
      runtime,
      [mainIsolate, poWorker, message, source, stackTrace, lineNumber]() {
        v8::Locker locker(mainIsolate);
        Isolate::Scope isolate_scope(mainIsolate);
        HandleScope handle_scope(mainIsolate);
        Local<Value> worker = poWorker->Get(mainIsolate);
        if (worker.IsEmpty() || !worker->IsObject()) {
          // The parent dropped its reference to the worker object; there is
          // nothing left to dispatch on.
          return;
        }

        TryCatch tc(mainIsolate);
        Worker::EmitError(mainIsolate, worker.As<Object>(), message, source, stackTrace,
                          lineNumber);
        if (tc.HasCaught()) {
          Local<Value> error = tc.Exception();
          Log(@"%s", tns::ToString(mainIsolate, error).c_str());
          mainIsolate->ThrowException(error);
        }
      },
      async);
}

std::atomic<int> WorkerWrapper::nextId_(0);

}  // namespace tns
