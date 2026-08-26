#include "Worker.h"
#include <functional>
#include "BuiltinLoader.h"
#include "Caches.h"
#include "Constants.h"
#include "Helpers.h"
#include "ModuleBinding.hpp"
#include "ModuleInternalCallbacks.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

namespace {

// The worker-events builtin's delivery callouts for this isolate. Both message
// directions share emitMessage; only the receiver differs. emitError is
// parent-side only.
struct WorkerEventsState {
  Global<v8::Function> emitMessage;
  Global<v8::Function> emitError;
};

}  // namespace

std::vector<std::string> Worker::GlobalFunctions = {"postMessage", "close"};

void Worker::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  Worker::Init(isolate, globalTemplate, Caches::Get(isolate)->isWorker);
}

void Worker::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate, bool isWorkerThread) {
  if (isWorkerThread) {
    // Register functions in the worker thread
    Local<FunctionTemplate> postMessageTemplate =
        FunctionTemplate::New(isolate, Worker::PostMessageToMainCallback);
    globalTemplate->Set(tns::ToV8String(isolate, "postMessage"), postMessageTemplate);

    Local<FunctionTemplate> closeTemplate =
        FunctionTemplate::New(isolate, Worker::CloseWorkerCallback);
    globalTemplate->Set(tns::ToV8String(isolate, "close"), closeTemplate);
  }
  // Register functions in the main thread
  Local<FunctionTemplate> workerFuncTemplate = FunctionTemplate::New(isolate, ConstructorCallback);
  workerFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
  Local<v8::String> workerFuncName = ToV8String(isolate, "Worker");
  workerFuncTemplate->SetClassName(workerFuncName);

  Local<ObjectTemplate> prototype = workerFuncTemplate->PrototypeTemplate();
  Local<FunctionTemplate> postMessageFuncTemplate =
      FunctionTemplate::New(isolate, PostMessageCallback);
  Local<FunctionTemplate> terminateWorkerFuncTemplate =
      FunctionTemplate::New(isolate, TerminateCallback);

  prototype->Set(ToV8String(isolate, "postMessage"), postMessageFuncTemplate);
  prototype->Set(ToV8String(isolate, "terminate"), terminateWorkerFuncTemplate);

  globalTemplate->Set(workerFuncName, workerFuncTemplate);
}

void Worker::InitEvents(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Object> exports;
  bool success =
      BuiltinLoader::GetExports(context, BuiltinId::kWorkerEvents, nullptr).ToLocal(&exports);
  tns::Assert(success, isolate);

  Local<Value> emitMessage;
  success = exports->Get(context, tns::ToV8String(isolate, "emitMessage")).ToLocal(&emitMessage) &&
            emitMessage->IsFunction();
  tns::Assert(success, isolate);

  Local<Value> emitError;
  success = exports->Get(context, tns::ToV8String(isolate, "emitError")).ToLocal(&emitError) &&
            emitError->IsFunction();
  tns::Assert(success, isolate);

  WorkerEventsState* state = Caches::StateFor<WorkerEventsState>(isolate);
  tns::Assert(state != nullptr, isolate);
  state->emitMessage.Reset(isolate, emitMessage.As<v8::Function>());
  state->emitError.Reset(isolate, emitError.As<v8::Function>());
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

    if (info.Length() > 2) {
      throw NativeScriptException("Too many arguments passed.");
    }

    Local<Object> thiz = info.This();
    std::string workerPath;

    // Handle both string URLs and URL objects
    if (IsString(info[0])) {
      workerPath = ToString(isolate, info[0]);
    } else if (info[0]->IsObject()) {
      Local<Object> urlObj = info[0].As<Object>();
      Local<Value> toStringMethod;
      if (urlObj->Get(context, tns::ToV8String(isolate, "toString")).ToLocal(&toStringMethod)) {
        if (toStringMethod->IsFunction()) {
          Local<v8::Function> toString = toStringMethod.As<v8::Function>();
          Local<Value> result;
          if (toString->Call(context, urlObj, 0, nullptr).ToLocal(&result)) {
            if (result->IsString()) {
              std::string stringResult = ToString(isolate, result);
              // Reject plain objects that return "[object Object]" from toString()
              if (stringResult == "[object Object]") {
                throw NativeScriptException(
                    "Worker constructor expects a string URL or URL object.");
              }
              workerPath = stringResult;
            } else {
              throw NativeScriptException("Worker URL object toString() must return a string.");
            }
          } else {
            throw NativeScriptException("Error calling toString() on Worker URL object.");
          }
        } else {
          throw NativeScriptException("Worker URL object must have a toString() method.");
        }
      } else {
        throw NativeScriptException("Worker URL object must have a toString() method.");
      }
    } else {
      throw NativeScriptException("Worker constructor expects a string URL or URL object.");
    }

    // Relative worker paths are resolved against the calling module's directory,
    // matching the Android runtime and the legacy JSC iOS runtime. If no file is
    // found there, fall back to app-root-relative resolution, which is what this
    // runtime historically did.
    if (workerPath.rfind("./", 0) == 0 || workerPath.rfind("../", 0) == 0) {
      Local<StackTrace> stack = StackTrace::CurrentStackTrace(isolate, 1);
      if (!stack.IsEmpty() && stack->GetFrameCount() > 0) {
        Local<v8::String> scriptName = stack->GetFrame(isolate, 0)->GetScriptName();
        if (!scriptName.IsEmpty()) {
          std::string callerScript = ToString(isolate, scriptName);
          const std::string filePrefix = "file://";
          if (callerScript.rfind(filePrefix, 0) == 0) {
            callerScript = callerScript.substr(filePrefix.size());
          }
          // Script origins are relative to the app bundle root (BaseDir)
          if (!callerScript.empty() && callerScript[0] == '/' &&
              callerScript.rfind(RuntimeConfig.BaseDir, 0) != 0) {
            callerScript = RuntimeConfig.BaseDir + callerScript;
          }
          if (!callerScript.empty() && callerScript[0] == '/') {
            NSString* callerDir = [[NSString stringWithUTF8String:callerScript.c_str()]
                stringByDeletingLastPathComponent];
            NSString* candidate = [[callerDir
                stringByAppendingPathComponent:[NSString stringWithUTF8String:workerPath.c_str()]]
                stringByStandardizingPath];
            if (tns::Exists([candidate fileSystemRepresentation]) ||
                tns::Exists(
                    [[candidate stringByAppendingPathExtension:@"js"] fileSystemRepresentation]) ||
                tns::Exists([[candidate stringByAppendingPathComponent:@"index.js"]
                    fileSystemRepresentation])) {
              workerPath = [candidate UTF8String];
            }
          }
        }
      }

      if (workerPath.rfind("./", 0) == 0 || workerPath.rfind("../", 0) == 0) {
        NSString* fallback = [[[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:workerPath.c_str()]]
            stringByStandardizingPath];
        workerPath = [fallback UTF8String];
      }
    }

    int qos = -1;
    if (info.Length() >= 2 && info[1]->IsObject()) {
      Local<Object> options = info[1].As<Object>();
      Local<Value> iosPriorityVal;
      if (options->Get(context, tns::ToV8String(isolate, "iosPriority")).ToLocal(&iosPriorityVal) &&
          IsString(iosPriorityVal)) {
        std::string priority = ToString(isolate, iosPriorityVal);
        if (priority == "userInteractive") {
          qos = NSQualityOfServiceUserInteractive;
        } else if (priority == "userInitiated") {
          qos = NSQualityOfServiceUserInitiated;
        } else if (priority == "default") {
          qos = NSQualityOfServiceDefault;
        } else if (priority == "utility") {
          qos = NSQualityOfServiceUtility;
        } else if (priority == "background") {
          qos = NSQualityOfServiceBackground;
        }
      }
    }

    WorkerWrapper* worker = new WorkerWrapper(isolate, Worker::OnMessageCallback);
    tns::SetValue(isolate, thiz, worker);
    std::shared_ptr<Persistent<Value>> poWorker = ObjectManager::Register(context, thiz);

    // The loader vocabulary is per-isolate, so the worker gets a COPY taken
    // here, on the parent's thread, and installed on the worker's isolate
    // before it loads anything. Nothing is shared, so nothing needs
    // synchronizing — and a live worker deliberately does not observe a later
    // configureLoader on the parent (the dev client restarts workers on
    // vocabulary updates).
    tns::LoaderVocabulary inheritedVocabulary = tns::CaptureLoaderVocabulary(isolate);

    std::function<Isolate*()> func([worker, workerPath, inheritedVocabulary]() {
      // Resolve tilde paths before creating the runtime
      std::string resolvedPath = workerPath;
      if (!workerPath.empty() && workerPath[0] == '~') {
        // Convert ~/path to ApplicationPath/path
        std::string tail = workerPath.size() >= 2 && workerPath[1] == '/' ? workerPath.substr(2)
                                                                          : workerPath.substr(1);
        resolvedPath = RuntimeConfig.ApplicationPath + "/" + tail;
      }

      tns::Runtime* runtime = new tns::Runtime();
      Isolate* isolate = runtime->CreateIsolate();
      v8::Locker locker(isolate);
      runtime->Init(isolate, true);
      // Before any module load runs in this isolate.
      tns::InstallLoaderVocabulary(isolate, inheritedVocabulary);
      runtime->SetWorkerId(worker->WorkerId());
      int workerId = worker->WorkerId();
      Worker::SetWorkerId(isolate, workerId);

      // Expose this worker to an attached Chrome DevTools frontend as a
      // child target (no-op in release builds). Created before RunModule so
      // the worker's scripts are visible to the debugger from the start.
      worker->CreateInspector(isolate, resolvedPath);

      TryCatch tc(isolate);

      // If the script can be determined missing up-front, report it through
      // worker.onerror instead of running (and let the caller terminate us).
      if (!resolvedPath.empty() && resolvedPath[0] == '/' && !tns::Exists(resolvedPath.c_str())) {
        NSString* path = [NSString stringWithUTF8String:resolvedPath.c_str()];
        if (!tns::Exists([[path stringByAppendingPathExtension:@"js"] fileSystemRepresentation]) &&
            !tns::Exists(
                [[path stringByAppendingPathComponent:@"index.js"] fileSystemRepresentation])) {
          worker->PassUncaughtExceptionFromWorkerToMain(
              "Worker script does not exist: " + resolvedPath, resolvedPath, "", 1, true);
          return isolate;
        }
      }

      try {
        runtime->RunModule(resolvedPath);
      } catch (NativeScriptException& ex) {
        // Re-arm the failure as the pending V8 exception (the original JS
        // error when one was captured) so the tc.HasCaught() path below
        // routes it to worker.onerror with full detail.
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        ex.ReThrowToV8(isolate);
      }

      // WHATWG parity: enable the implicit port's message queue once the
      // entry has finished evaluating. RunModule returns settled for classic
      // scripts and pumped HTTP entries; a local top-level-await entry that
      // outlived the settle window enables when its evaluation promise
      // settles (fulfilled or rejected — a broken worker just dispatches
      // into a listenerless global, as on the web).
      {
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        Local<Context> context = Caches::Get(isolate)->GetContext();
        Context::Scope context_scope(context);
        Local<Promise> pendingEntry;
        if (!ModuleInternal::PendingEntryEvaluation(isolate, resolvedPath).ToLocal(&pendingEntry)) {
          worker->EnableMessageQueue();
        } else {
          // Both handlers resolve the wrapper by id — never capture it across
          // the settle; the worker may be gone by the time they run.
          auto enable = [](const FunctionCallbackInfo<Value>& info) {
            bool found = false;
            int lookupId = info.Data().As<v8::Int32>()->Value();
            auto state = Caches::Workers->Get(lookupId, found);
            if (found && state != nullptr) {
              WorkerWrapper* w = static_cast<WorkerWrapper*>(state->UserData());
              if (w != nullptr) {
                w->EnableMessageQueue();
              }
            }
          };
          // A separate reject handler: sharing one handler across both
          // outcomes marked the rejection handled, which swallowed a failing
          // top-level-await entry entirely — neither the worker's own onerror
          // nor the parent's error event ever saw it.
          auto enableAndReport = [](const FunctionCallbackInfo<Value>& info) {
            Isolate* iso = info.GetIsolate();
            HandleScope hs(iso);
            bool found = false;
            int lookupId = info.Data().As<v8::Int32>()->Value();
            auto state = Caches::Workers->Get(lookupId, found);
            if (!found || state == nullptr) {
              return;
            }
            WorkerWrapper* w = static_cast<WorkerWrapper*>(state->UserData());
            if (w == nullptr) {
              return;
            }
            w->EnableMessageQueue();
            Local<Context> ctx = Caches::Get(iso)->GetContext();
            Context::Scope ctxScope(ctx);
            Local<Value> reason = info.Length() > 0
                                      ? info[0]
                                      : Local<Value>(v8::Exception::Error(tns::ToV8String(
                                            iso, "Worker entry module evaluation rejected")));
            w->ReportEntryEvaluationRejection(ctx, reason);
          };
          Local<v8::Function> onFulfilled;
          Local<v8::Function> onRejected;
          Local<v8::Integer> workerIdData = v8::Integer::New(isolate, worker->WorkerId());
          if (v8::Function::New(context, enable, workerIdData).ToLocal(&onFulfilled) &&
              v8::Function::New(context, enableAndReport, workerIdData).ToLocal(&onRejected)) {
            pendingEntry->Then(context, onFulfilled, onRejected).FromMaybe(Local<Promise>());
          } else {
            worker->EnableMessageQueue();
          }
        }
      }

      if (tc.HasCaught()) {
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        Local<Context> context = Caches::Get(isolate)->GetContext();

        // Ensure we dispatch the error asynchronously to the main thread so
        // the caller has a chance to attach `worker.onerror` immediately
        // after construction. Delivering synchronously can race with the
        // test which sets the handler right after `new Worker(...)`.
        worker->PassUncaughtExceptionFromWorkerToMain(context, tc, true);
        worker->Terminate();
      }

      return isolate;
    });

    worker->Start(poWorker, func, qos);

    std::shared_ptr<Caches::WorkerState> state =
        std::make_shared<Caches::WorkerState>(isolate, poWorker, worker);
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

    if (info.Length() > 2) {
      throw NativeScriptException("Too many arguments passed.");
    }

    int workerId = Worker::GetWorkerId(isolate, info.This());
    std::shared_ptr<Caches::WorkerState> state = Caches::Workers->Get(workerId);
    tns::Assert(state != nullptr, isolate);
    WorkerWrapper* worker = static_cast<WorkerWrapper*>(state->UserData());
    if (!worker->IsRunning()) {
      return;
    }

    // Resolved before anything is serialized: serializing a transfer list
    // detaches the caller's buffers, so bailing out afterwards would destroy
    // their contents without ever delivering the message.
    auto runtime = static_cast<Runtime*>(state->GetIsolate()->GetData(Constants::RUNTIME_SLOT));
    if (runtime == nullptr) {
      return;
    }

    auto context = Caches::Get(isolate)->GetContext();
    auto message = std::make_shared<worker::Message>();
    Local<Value> transferList = info.Length() > 1 ? info[1] : v8::Undefined(isolate).As<Value>();
    if (message
            ->Serialize(isolate, context, info[0], transferList,
                        serialization::HostObjectPolicy::kDegrade)
            .IsNothing()) {
      // The transfer list was rejected or the value could not be cloned; the
      // exception is already pending and nothing may be posted.
      return;
    }

    runtime->GetEventLoop()->PostInternal([state, message]() {
      Isolate* isolate = state->GetIsolate();
      v8::Locker locker(isolate);
      Isolate::Scope isolate_scope(isolate);
      HandleScope handle_scope(isolate);
      Local<Value> workerInstance = state->GetWorker()->Get(isolate);
      if (workerInstance.IsEmpty() || !workerInstance->IsObject()) {
        // The parent dropped its reference to the worker object before the
        // message landed; there is nothing left to dispatch on.
        return;
      }
      Worker::OnMessageCallback(isolate, workerInstance.As<Object>(), message);
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

    if (info.Length() > 2) {
      throw NativeScriptException("Too many arguments passed.");
      return;
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Worker, isolate);

    WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
    if (!worker->IsRunning() || worker->IsClosing()) {
      return;
    }

    auto context = Caches::Get(isolate)->GetContext();
    auto message = std::make_shared<worker::Message>();
    Local<Value> transferList = info.Length() > 1 ? info[1] : v8::Undefined(isolate).As<Value>();
    if (message
            ->Serialize(isolate, context, info[0], transferList,
                        serialization::HostObjectPolicy::kDegrade)
            .IsNothing()) {
      // The transfer list was rejected or the value could not be cloned; the
      // exception is already pending and nothing may be posted.
      return;
    }

    worker->PostMessage(message);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }
}

void Worker::OnMessageCallback(Isolate* isolate, Local<Object> receiver,
                               std::shared_ptr<worker::Message> message) {
  WorkerEventsState* state = Caches::StateFor<WorkerEventsState>(isolate);
  if (state == nullptr || state->emitMessage.IsEmpty()) {
    return;
  }
  Local<Context> context = Caches::Get(isolate)->GetContext();

  Local<Value> data;
  Local<Value> ports;
  const char* type = "message";
  {
    TryCatch tc(isolate);
    if (!message->Deserialize(isolate, context, &ports).ToLocal(&data)) {
      if (tc.HasTerminated()) {
        return;
      }
      // HTML: a message that cannot be read still reaches its target, as a
      // `messageerror` event carrying nothing.
      tc.Reset();
      data = v8::Undefined(isolate);
      ports = Local<Value>();
      type = "messageerror";
    }
  }

  Local<Value> args[3]{data, ports.IsEmpty() ? v8::Undefined(isolate).As<Value>() : ports,
                       tns::ToV8String(isolate, type)};
  Local<Value> result;
  // A throw here is left pending on purpose: on the worker side the drain's
  // TryCatch turns it into the scope's error event, and on the parent side
  // V8's uncaught-message listener reports it.
  (void)state->emitMessage.Get(isolate)->Call(context, receiver, 3, args).ToLocal(&result);
}

bool Worker::EmitError(Isolate* isolate, Local<Object> receiver, const std::string& message,
                       const std::string& source, const std::string& stackTrace, int lineNumber) {
  WorkerEventsState* state = Caches::StateFor<WorkerEventsState>(isolate);
  if (state == nullptr || state->emitError.IsEmpty()) {
    return false;
  }
  Local<Context> context = Caches::Get(isolate)->GetContext();

  Local<Value> args[4]{tns::ToV8String(isolate, message), tns::ToV8String(isolate, source),
                       Number::New(isolate, lineNumber), tns::ToV8String(isolate, stackTrace)};
  Local<Value> result;
  if (!state->emitError.Get(isolate)->Call(context, receiver, 4, args).ToLocal(&result)) {
    return false;
  }
  return result->BooleanValue(isolate);
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
    Local<Value> args[0]{};
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

void Worker::SetWorkerId(Isolate* isolate, int workerId) {
  // Runs on the worker thread right after Runtime::Init(), whose Isolate::Scope
  // has already been unwound -- so this has to enter the isolate itself, and
  // take the context from the caches rather than GetCurrentContext().
  Isolate::Scope isolateScope(isolate);
  HandleScope scope(isolate);
  Local<Context> context = Caches::Get(isolate)->GetContext();
  Context::Scope contextScope(context);
  Local<Object> global = context->Global();
  global->SetPrivate(context, Private::ForApi(isolate, tns::ToV8String(isolate, "workerId")),
                     Number::New(isolate, workerId));
}

int Worker::GetWorkerId(Isolate* isolate, Local<Object> global) {
  Local<Value> value;

  Local<Context> context = isolate->GetCurrentContext();
  bool success =
      global->GetPrivate(context, Private::ForApi(isolate, tns::ToV8String(isolate, "workerId")))
          .ToLocal(&value);
  tns::Assert(success && value->IsNumber(), isolate);

  Local<Number> number = value.As<Number>();
  return number->Value();
}

}  // namespace tns

NODE_BINDING_PER_ISOLATE_INIT_OBJ(worker, tns::Worker::Init)
