#include <Foundation/Foundation.h>
#include <notify.h>
#include <chrono>

#include "src/inspector/v8-console-message.h"
#include "src/inspector/v8-inspector-impl.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "src/inspector/v8-runtime-agent-impl.h"
#include "src/inspector/v8-stack-trace-impl.h"

#include "Caches.h"
#include "Helpers.h"
#include "InspectorServer.h"
#include "JsV8InspectorClient.h"
#include "include/libplatform/libplatform.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

#define NOTIFICATION(name)                                 \
  [[NSString stringWithFormat:@"%@:NativeScript.Debug.%s", \
                              [[NSBundle mainBundle] bundleIdentifier], name] UTF8String]

#define LOG_DEBUGGER_PORT(port)                                                      \
  Log(@"NativeScript debugger has opened inspector socket on port %d for %@.", port, \
      [[NSBundle mainBundle] bundleIdentifier])

JsV8InspectorClient::JsV8InspectorClient(tns::Runtime* runtime)
    : runtime_(runtime), isolate_(runtime_->GetIsolate()), messages_(), runningNestedLoops_(false) {
  this->messagesQueue_ =
      dispatch_queue_create("NativeScript.v8.inspector.message_queue", DISPATCH_QUEUE_SERIAL);
  this->messageLoopQueue_ =
      dispatch_queue_create("NativeScript.v8.inspector.message_loop_queue", DISPATCH_QUEUE_SERIAL);
  this->messageArrived_ = dispatch_semaphore_create(0);
}

void JsV8InspectorClient::enableInspector(int argc, char** argv) {
  int waitForDebuggerSubscription;
  notify_register_dispatch(
      NOTIFICATION("WaitForDebugger"), &waitForDebuggerSubscription, dispatch_get_main_queue(),
      ^(int token) {
        this->isWaitingForDebugger_ = YES;

        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 30);
        dispatch_after(delay, dispatch_get_main_queue(), ^{
          if (this->isWaitingForDebugger_) {
            this->isWaitingForDebugger_ = NO;
            NSLog(@"NativeScript waiting for debugger timeout elapsed. Continuing execution.");
          }
        });

        NSLog(@"NativeScript waiting for debugger.");
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
          do {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
          } while (this->isWaitingForDebugger_);
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
      });

  int attachRequestSubscription;
  notify_register_dispatch(
      NOTIFICATION("AttachRequest"), &attachRequestSubscription, dispatch_get_main_queue(),
      ^(int token) {
        in_port_t listenPort = InspectorServer::Init(
            [this](std::function<void(std::string)> sender) { this->onFrontendConnected(sender); },
            [this](std::string message) { this->onFrontendMessageReceived(message); });

        LOG_DEBUGGER_PORT(listenPort);
        notify_post(NOTIFICATION("ReadyForAttach"));
      });

  notify_post(NOTIFICATION("AppLaunching"));

  for (int i = 1; i < argc; i++) {
    BOOL startListening = NO;
    BOOL shouldWaitForDebugger = NO;

    if (strcmp(argv[i], "--nativescript-debug-brk") == 0) {
      shouldWaitForDebugger = YES;
    } else if (strcmp(argv[i], "--nativescript-debug-start") == 0) {
      startListening = YES;
    }

    if (startListening || shouldWaitForDebugger) {
      notify_post(NOTIFICATION("AttachRequest"));
      if (shouldWaitForDebugger) {
        notify_post(NOTIFICATION("WaitForDebugger"));
      }

      break;
    }
  }

  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
  notify_cancel(waitForDebuggerSubscription);
}

void JsV8InspectorClient::onFrontendConnected(std::function<void(std::string)> sender) {
  if (this->isWaitingForDebugger_) {
    this->isWaitingForDebugger_ = NO;
    CFRunLoopRef runloop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(runloop, (__bridge CFTypeRef)(NSRunLoopCommonModes), ^{
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
      this->scheduleBreak();
    });
    CFRunLoopWakeUp(runloop);
  }

  this->sender_ = sender;

  // this triggers a reconnection from the devtools so Debugger.scriptParsed etc. are all fired
  // again
  this->disconnect();
  this->isConnected_ = true;
}

void JsV8InspectorClient::onFrontendMessageReceived(std::string message) {
  dispatch_sync(this->messagesQueue_, ^{
    this->messages_.push(message);
    dispatch_semaphore_signal(messageArrived_);
  });

  tns::ExecuteOnMainThread([this, message]() {
    dispatch_sync(this->messageLoopQueue_, ^{
      // prevent execution if we're already pumping messages
      if (runningNestedLoops_ && !terminated_) {
        return;
      };
      std::string message;
      do {
        message = this->PumpMessage();
        if (!message.empty()) {
          this->dispatchMessage(message);
        }
      } while (!message.empty());
    });
  });
}

void JsV8InspectorClient::init() {
  if (inspector_ != nullptr) {
    return;
  }

  Isolate* isolate = isolate_;

  Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

  inspector_ = V8Inspector::create(isolate, this);

  inspector_->contextCreated(
      v8_inspector::V8ContextInfo(context, JsV8InspectorClient::contextGroupId, {}));

  context_.Reset(isolate, context);

  this->createInspectorSession();

  tracing_agent_.reset(new tns::inspector::TracingAgentImpl());
}

void JsV8InspectorClient::connect(int argc, char** argv) {
  this->isConnected_ = true;
  this->enableInspector(argc, argv);
}

void JsV8InspectorClient::createInspectorSession() {
  this->session_ = this->inspector_->connect(JsV8InspectorClient::contextGroupId, this, {});
}

void JsV8InspectorClient::disconnect() {
  Isolate* isolate = isolate_;
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);

  session_->resume();
  session_.reset();

  this->isConnected_ = false;

  this->createInspectorSession();
}

void JsV8InspectorClient::runMessageLoopOnPause(int contextGroupId) {
  __block auto loopsRunning = false;
  dispatch_sync(this->messageLoopQueue_, ^{
    loopsRunning = runningNestedLoops_;
    terminated_ = false;
    if (runningNestedLoops_) {
      return;
    }
    this->runningNestedLoops_ = true;
  });

  if (loopsRunning) {
    return;
  }

  bool shouldWait = false;
  while (!terminated_) {
    std::string message = this->PumpMessage();
    if (!message.empty()) {
      this->dispatchMessage(message);
      shouldWait = false;
    } else {
      shouldWait = true;
    }

    std::shared_ptr<Platform> platform = tns::Runtime::GetPlatform();
    Isolate* isolate = isolate_;
    platform::PumpMessageLoop(platform.get(), isolate, platform::MessageLoopBehavior::kDoNotWait);
    if (shouldWait && !terminated_) {
      dispatch_semaphore_wait(messageArrived_,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_MSEC));  // 1ms
    }
  }

  dispatch_sync(this->messageLoopQueue_, ^{
    terminated_ = false;
    runningNestedLoops_ = false;
  });
}

void JsV8InspectorClient::quitMessageLoopOnPause() {
  dispatch_sync(this->messageLoopQueue_, ^{
    terminated_ = true;
  });
}

void JsV8InspectorClient::sendResponse(int callId, std::unique_ptr<StringBuffer> message) {
  this->notify(std::move(message));
}

void JsV8InspectorClient::sendNotification(std::unique_ptr<StringBuffer> message) {
  this->notify(std::move(message));
}

void JsV8InspectorClient::flushProtocolNotifications() {}

void JsV8InspectorClient::notify(std::unique_ptr<StringBuffer> message) {
  StringView stringView = message->string();
  std::string value = ToStdString(stringView);

  if (this->sender_) {
    this->sender_(value);
  }
}

void JsV8InspectorClient::dispatchMessage(const std::string& message) {
  std::vector<uint16_t> vector = tns::ToVector(message);
  StringView messageView(vector.data(), vector.size());
  Isolate* isolate = isolate_;
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  Local<Context> context = tns::Caches::Get(isolate)->GetContext();
  bool success;

  // livesync uses the inspector socket for HMR/LiveSync...
  if (message.find("Page.reload") != std::string::npos) {
    success = tns::LiveSync(this->isolate_);
    if (!success) {
      NSLog(@"LiveSync failed");
    }
    // todo: should we return here, or is it OK to pass onto a possible Page.reload domain handler?
  }

  if (message.find("Tracing.start") != std::string::npos) {
    tracing_agent_->start();

    // echo back the request to notify frontend the action was a success
    // todo: send an empty response for the incoming message id instead.
    this->sendNotification(StringBuffer::create(messageView));
    return;
  }

  if (message.find("Tracing.end") != std::string::npos) {
    tracing_agent_->end();
    std::string res = tracing_agent_->getLastTrace();
    tracing_agent_->SendToDevtools(context, res);
    return;
  }

  // parse incoming message as JSON
  Local<Value> arg;
  success = v8::JSON::Parse(context, tns::ToV8String(isolate, message)).ToLocal(&arg);

  // stop processing invalid messages
  if (!success) {
    NSLog(@"Inspector failed to parse incoming message: %s", message.c_str());
    // ignore failures to parse.
    return;
  }

  // Pass incoming message to a registerd domain handler if any
  if (!arg.IsEmpty() && arg->IsObject()) {
    Local<Object> domainDebugger;
    Local<Object> argObject = arg.As<Object>();
    Local<v8::Function> domainMethodFunc =
        v8_inspector::GetDebuggerFunctionFromObject(context, argObject, domainDebugger);

    Local<Value> result;
    success = this->CallDomainHandlerFunction(context, domainMethodFunc, argObject, domainDebugger,
                                              result);

    if (success) {
      auto requestId =
          arg.As<Object>()->Get(context, tns::ToV8String(isolate, "id")).ToLocalChecked();
      auto returnString = GetReturnMessageFromDomainHandlerResult(result, requestId);

      if (returnString.size() > 0) {
        std::vector<uint16_t> vector = tns::ToVector(returnString);
        StringView messageView(vector.data(), vector.size());
        auto msg = StringBuffer::create(messageView);
        this->sendNotification(std::move(msg));
      }
      return;
    }
  }

  // if no handler handled the message successfully, fall-through to the default V8 implementation
  this->session_->dispatchProtocolMessage(messageView);

  // TODO: check why this is needed (it should trigger automatically when script depth is 0)
  isolate->PerformMicrotaskCheckpoint();
}

Local<Context> JsV8InspectorClient::ensureDefaultContextInGroup(int contextGroupId) {
  return context_.Get(isolate_);
}

std::string JsV8InspectorClient::PumpMessage() {
  __block std::string result;
  dispatch_sync(this->messagesQueue_, ^{
    if (this->messages_.size() > 0) {
      result = this->messages_.front();
      this->messages_.pop();
    }
  });

  return result;
}

void JsV8InspectorClient::scheduleBreak() {
  Isolate* isolate = isolate_;
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  auto context = isolate->GetCurrentContext();
  Context::Scope context_scope(context);

  if (!this->hasScheduledDebugBreak_) {
    this->hasScheduledDebugBreak_ = true;
    // hack: force a debugger; statement in ModuleInternal to actually break before loading the next
    // (main) script...
    // FIXME: find a proper fix to not need to resort to this hack.
    context->Global()
        ->Set(context, tns::ToV8String(isolate, "__pauseOnNextRequire"),
              v8::Boolean::New(isolate, true))
        .ToChecked();
  }

  this->session_->schedulePauseOnNextStatement({}, {});
}

void JsV8InspectorClient::registerModules() {
  Isolate* isolate = isolate_;
  Local<Context> context = isolate->GetEnteredOrMicrotaskContext();
  Local<Object> global = context->Global();
  Local<Object> inspectorObject = Object::New(isolate);

  assert(global->Set(context, tns::ToV8String(isolate, "__inspector"), inspectorObject)
             .FromMaybe(false));
  Local<v8::Function> func;
  bool success = v8::Function::New(context, registerDomainDispatcherCallback).ToLocal(&func);
  assert(success &&
         global->Set(context, tns::ToV8String(isolate, "__registerDomainDispatcher"), func)
             .FromMaybe(false));

  Local<External> data = External::New(isolate, this);
  success = v8::Function::New(context, inspectorSendEventCallback, data).ToLocal(&func);
  assert(success && global->Set(context, tns::ToV8String(isolate, "__inspectorSendEvent"), func)
                        .FromMaybe(false));

  success = v8::Function::New(context, inspectorTimestampCallback).ToLocal(&func);
  assert(success && global->Set(context, tns::ToV8String(isolate, "__inspectorTimestamp"), func)
                        .FromMaybe(false));

  {
    v8::Locker locker(isolate);
    TryCatch tc(isolate);
    runtime_->RunModule("inspector_modules");
    // FIXME: This triggers some DCHECK failures, due to the entered v8::Context in
    // Runtime::init().
  }
}

void JsV8InspectorClient::registerDomainDispatcherCallback(
    const FunctionCallbackInfo<Value>& args) {
  Isolate* isolate = args.GetIsolate();
  std::string domain = tns::ToString(isolate, args[0].As<v8::String>());
  auto it = Domains.find(domain);
  if (it == Domains.end()) {
    Local<v8::Function> domainCtorFunc = args[1].As<v8::Function>();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> ctorArgs[0];
    Local<Value> domainInstance;
    bool success = domainCtorFunc->CallAsConstructor(context, 0, ctorArgs).ToLocal(&domainInstance);
    assert(success && domainInstance->IsObject());

    Local<Object> domainObj = domainInstance.As<Object>();
    Persistent<Object>* poDomainObj = new Persistent<Object>(isolate, domainObj);
    Domains.emplace(domain, poDomainObj);
  }
}

void JsV8InspectorClient::inspectorSendEventCallback(const FunctionCallbackInfo<Value>& args) {
  Local<External> data = args.Data().As<External>();
  v8_inspector::JsV8InspectorClient* client =
      static_cast<v8_inspector::JsV8InspectorClient*>(data->Value());
  Isolate* isolate = args.GetIsolate();
  Local<v8::String> arg = args[0].As<v8::String>();
  std::string message = tns::ToString(isolate, arg);

  std::vector<uint16_t> vector = tns::ToVector(message);
  StringView messageView(vector.data(), vector.size());
  auto msg = StringBuffer::create(messageView);
  client->sendNotification(std::move(msg));
}

void JsV8InspectorClient::inspectorTimestampCallback(const FunctionCallbackInfo<Value>& args) {
  double timestamp = std::chrono::seconds(std::chrono::seconds(std::time(NULL))).count();
  args.GetReturnValue().Set(timestamp);
}

void JsV8InspectorClient::consoleLog(v8::Isolate* isolate, ConsoleAPIType method,
                                     const std::vector<v8::Local<v8::Value>>& args) {
  if (!isConnected_) {
    return;
  }

  // Note, here we access private API
  auto* impl = reinterpret_cast<v8_inspector::V8InspectorImpl*>(inspector_.get());
  auto* session = reinterpret_cast<v8_inspector::V8InspectorSessionImpl*>(session_.get());

  if (impl->isolate() != isolate) {
    // we don't currently support logging from a worker thread/isolate
    return;
  }

  v8::Local<v8::StackTrace> stack =
      v8::StackTrace::CurrentStackTrace(isolate, 1, v8::StackTrace::StackTraceOptions::kDetailed);
  std::unique_ptr<V8StackTraceImpl> stackImpl = impl->debugger()->createStackTrace(stack);

  v8::Local<v8::Context> context = context_.Get(isolate);
  const int contextId = V8ContextInfo::executionContextId(context);

  std::unique_ptr<v8_inspector::V8ConsoleMessage> msg =
      v8_inspector::V8ConsoleMessage::createForConsoleAPI(context, contextId, contextGroupId, impl,
                                                          currentTimeMS(), method, args, String16{},
                                                          std::move(stackImpl));

  session->runtimeAgent()->messageAdded(msg.get());
}

bool JsV8InspectorClient::CallDomainHandlerFunction(Local<Context> context,
                                                    Local<Function> domainMethodFunc,
                                                    const Local<Object>& arg,
                                                    Local<Object>& domainDebugger,
                                                    Local<Value>& result) {
  if (domainMethodFunc.IsEmpty() || !domainMethodFunc->IsFunction()) {
    return false;
  }

  bool success;
  Isolate* isolate = this->isolate_;
  TryCatch tc(isolate);

  Local<Value> params;
  success = arg.As<Object>()->Get(context, tns::ToV8String(isolate, "params")).ToLocal(&params);

  if (!success) {
    return false;
  }

  Local<Value> args[2] = {params, arg};
  success = domainMethodFunc->Call(context, domainDebugger, 2, args).ToLocal(&result);

  if (tc.HasCaught()) {
    std::string error = tns::ToString(isolate, tc.Message()->Get());

    // backwards compatibility
    if (error.find("may be enabled at a time") != std::string::npos) {
      // not returning false here because we are catching bogus errors from core...
      // Uncaught Error: One XXX may be enabled at a time...
      result = v8::Boolean::New(isolate, true);
      return true;
    }

    // log any other errors - they are caught, but still make them visible to the user.
    tns::LogError(isolate, tc);

    return false;
  }

  return success;
}

std::string JsV8InspectorClient::GetReturnMessageFromDomainHandlerResult(
    const Local<Value>& result, const Local<Value>& requestId) {
  if (result.IsEmpty() ||
      !(result->IsBoolean() || result->IsObject() || result->IsNullOrUndefined())) {
    return "";
  }

  Isolate* isolate = this->isolate_;

  if (!result->IsObject()) {
    // if there return value is a "true" boolean or undefined/null we send back an "ack" response
    // with an empty result object
    if (result->IsNullOrUndefined() || result->BooleanValue(isolate_)) {
      return "{ \"id\":" + tns::ToString(isolate, requestId) + ", \"result\": {} }";
    }

    return "";
  }

  Local<Context> context = tns::Caches::Get(isolate)->GetContext();
  Local<Object> resObject = result.As<v8::Object>();
  Local<Value> stringified;

  bool success = true;
  // already a { result: ... } object
  if (resObject->Has(context, tns::ToV8String(isolate, "result")).ToChecked()) {
    success = JSON::Stringify(context, result).ToLocal(&stringified);
  } else {
    // backwards compatibility - we wrap the response in a new object with the { id, result } keys
    // since the returned response only contained the result part.
    Context::Scope context_scope(context);

    Local<Object> newResObject = v8::Object::New(isolate);
    success = success &&
              newResObject->Set(context, tns::ToV8String(isolate, "id"), requestId).ToChecked();
    success = success &&
              newResObject->Set(context, tns::ToV8String(isolate, "result"), resObject).ToChecked();
    success = success && JSON::Stringify(context, newResObject).ToLocal(&stringified);
  }

  if (!success) {
    return "";
  }

  return tns::ToString(isolate, stringified);
}

std::map<std::string, Persistent<Object>*> JsV8InspectorClient::Domains;

}  // namespace v8_inspector
