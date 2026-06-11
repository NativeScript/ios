#include "WorkerInspectorClient.h"

#include "src/inspector/v8-inspector-impl.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "src/inspector/v8-runtime-agent-impl.h"
#include "src/inspector/v8-stack-trace-impl.h"

#include "Caches.h"
#include "Helpers.h"
#include "JsV8InspectorClient.h"
#include "include/libplatform/libplatform.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

namespace {
StringView Make8BitStringView(const std::string& value) {
  return StringView(reinterpret_cast<const uint8_t*>(value.data()), value.size());
}
}  // namespace

WorkerInspectorClient::WorkerInspectorClient(int workerId, Isolate* isolate,
                                             CFRunLoopRef workerLoop, const std::string& url)
    : workerId_(workerId),
      sessionId_("NS_WORKER_" + std::to_string(workerId)),
      targetId_("ns-worker-" + std::to_string(workerId)),
      url_(url),
      isolate_(isolate),
      workerLoop_(workerLoop) {
  messageArrived_ = dispatch_semaphore_create(0);

  CFRunLoopSourceContext sourceContext = {
      0, this,
      0, 0,
      0, 0,
      0, 0,
      0, [](void* info) {
                                            static_cast<WorkerInspectorClient*>(info)
                                                ->DrainIncoming(); }};
  source_ = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext);
  CFRunLoopAddSource(workerLoop_, source_, kCFRunLoopCommonModes);

  v8::Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);
  Local<Context> context = tns::Caches::Get(isolate_)->GetContext();

  inspector_ = V8Inspector::create(isolate_, this);
  // Name the context after the worker script: the DevTools console context
  // selector labels entries with the context's name (or its origin as a
  // fallback) — with neither set the dropdown rows are blank and
  // unselectable.
  V8ContextInfo contextInfo(context, contextGroupId, Make8BitStringView(url_));
  contextInfo.origin = Make8BitStringView(url_);
  inspector_->contextCreated(contextInfo);
  context_.Reset(isolate_, context);
  session_ = inspector_->connect(contextGroupId, this, {});
}

WorkerInspectorClient::~WorkerInspectorClient() {
  dying_ = true;

  if (source_ != nullptr) {
    CFRunLoopRemoveSource(workerLoop_, source_, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(source_);
    CFRelease(source_);
    source_ = nullptr;
  }

  v8::Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);
  if (session_ != nullptr) {
    session_->resume();
    session_.reset();
  }
  inspector_.reset();
  context_.Reset();
}

void WorkerInspectorClient::PushMessage(const std::string& message) {
  if (dying_) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(incomingMutex_);
    incoming_.push(message);
  }

  if (source_ != nullptr && CFRunLoopSourceIsValid(source_)) {
    CFRunLoopSourceSignal(source_);
    CFRunLoopWakeUp(workerLoop_);
  }
  dispatch_semaphore_signal(messageArrived_);
}

std::string WorkerInspectorClient::PopMessage() {
  std::lock_guard<std::mutex> lock(incomingMutex_);
  if (incoming_.empty()) {
    return "";
  }
  std::string message = incoming_.front();
  incoming_.pop();
  return message;
}

void WorkerInspectorClient::DrainIncoming() {
  std::string message;
  while (!dying_ && !(message = this->PopMessage()).empty()) {
    this->DispatchOne(message);
  }
  this->MaybeResetSession();
}

void WorkerInspectorClient::DispatchOne(const std::string& message) {
  if (message == kResetSessionMessage) {
    this->HandleResetRequest();
    return;
  }

  if (session_ == nullptr) {
    return;
  }

  v8::Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);
  session_->dispatchProtocolMessage(Make8BitStringView(message));
  isolate_->PerformMicrotaskCheckpoint();
}

void WorkerInspectorClient::HandleResetRequest() {
  if (runningPauseLoop_) {
    // We're inside session_->dispatchProtocolMessage somewhere up the stack —
    // resume now (which exits the nested pause loop) and swap the session
    // only once that stack has fully unwound, from DrainIncoming.
    pendingReset_ = true;
    {
      v8::Locker locker(isolate_);
      Isolate::Scope isolate_scope(isolate_);
      HandleScope handle_scope(isolate_);
      if (session_ != nullptr) {
        session_->resume();
      }
    }
    if (source_ != nullptr && CFRunLoopSourceIsValid(source_)) {
      CFRunLoopSourceSignal(source_);
      CFRunLoopWakeUp(workerLoop_);
    }
    return;
  }

  this->DoResetSession();
}

void WorkerInspectorClient::DoResetSession() {
  v8::Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);
  if (session_ != nullptr) {
    session_->resume();
    session_.reset();
  }
  session_ = inspector_->connect(contextGroupId, this, {});
}

void WorkerInspectorClient::MaybeResetSession() {
  if (pendingReset_ && !runningPauseLoop_ && !dying_) {
    pendingReset_ = false;
    this->DoResetSession();
  }
}

void WorkerInspectorClient::runMessageLoopOnPause(int contextGroupId) {
  if (runningPauseLoop_ || dying_) {
    return;
  }
  runningPauseLoop_ = true;
  pauseTerminated_ = false;

  while (!pauseTerminated_ && !dying_) {
    std::string message = this->PopMessage();
    bool shouldWait = message.empty();
    if (!shouldWait) {
      this->DispatchOne(message);
    }

    std::shared_ptr<Platform> platform = tns::Runtime::GetPlatform();
    platform::PumpMessageLoop(platform.get(), isolate_, platform::MessageLoopBehavior::kDoNotWait);
    if (shouldWait && !pauseTerminated_ && !dying_) {
      dispatch_semaphore_wait(messageArrived_,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_MSEC));  // 1ms
    }
  }

  runningPauseLoop_ = false;
}

void WorkerInspectorClient::quitMessageLoopOnPause() { pauseTerminated_ = true; }

void WorkerInspectorClient::NotifyTerminating() {
  dying_ = true;
  pauseTerminated_ = true;
  dispatch_semaphore_signal(messageArrived_);
}

void WorkerInspectorClient::RequestPauseInterrupt() {
  isolate_->RequestInterrupt(
      [](Isolate* isolate, void* data) {
        // Runs on the worker thread mid-JS. Teardown also happens on the
        // worker thread, so the client either still exists or this resolves
        // to nothing — re-resolve through the registry instead of capturing
        // the pointer.
        int workerId = static_cast<int>(reinterpret_cast<intptr_t>(data));
        JsV8InspectorClient* root = JsV8InspectorClient::GetInstance();
        if (root != nullptr) {
          root->SchedulePauseInWorker(workerId);
        }
      },
      reinterpret_cast<void*>(static_cast<intptr_t>(workerId_)));
}

void WorkerInspectorClient::SchedulePauseFromInterrupt() {
  if (session_ != nullptr) {
    session_->schedulePauseOnNextStatement({}, {});
  }
}

void WorkerInspectorClient::sendResponse(int callId, std::unique_ptr<StringBuffer> message) {
  this->SendWrapped(ToStdString(message->string()));
}

void WorkerInspectorClient::sendNotification(std::unique_ptr<StringBuffer> message) {
  this->SendWrapped(ToStdString(message->string()));
}

void WorkerInspectorClient::flushProtocolNotifications() {}

void WorkerInspectorClient::SendWrapped(const std::string& message) {
  if (message.empty() || message[0] != '{') {
    return;
  }

  // Flat-session protocol: tag everything this session emits with its
  // sessionId so the frontend routes it to the right child target.
  std::string wrapped;
  wrapped.reserve(message.size() + sessionId_.size() + 16);
  wrapped += "{\"sessionId\":\"";
  wrapped += sessionId_;
  wrapped += "\"";
  if (message.size() > 2) {
    wrapped += ",";
  }
  wrapped.append(message, 1, std::string::npos);

  JsV8InspectorClient* root = JsV8InspectorClient::GetInstance();
  if (root != nullptr) {
    root->SendToFrontend(wrapped);
  }
}

void WorkerInspectorClient::consoleLog(ConsoleAPIType method,
                                       const std::vector<Local<Value>>& args) {
  if (inspector_ == nullptr) {
    return;
  }

  // Note, here we access private API (mirrors JsV8InspectorClient::consoleLog)
  auto* impl = reinterpret_cast<V8InspectorImpl*>(inspector_.get());

  Local<StackTrace> stack =
      StackTrace::CurrentStackTrace(isolate_, 1, StackTrace::StackTraceOptions::kDetailed);
  std::unique_ptr<V8StackTraceImpl> stackImpl = impl->debugger()->createStackTrace(stack);

  Local<Context> context = context_.Get(isolate_);
  const int contextId = V8ContextInfo::executionContextId(context);

  std::unique_ptr<V8ConsoleMessage> msg = V8ConsoleMessage::createForConsoleAPI(
      context, contextId, contextGroupId, impl, currentTimeMS(), method, args, String16{},
      std::move(stackImpl));

  // Going through the message storage both reports to the session when the
  // frontend has enabled the Runtime agent AND keeps the message for replay
  // on Runtime.enable. Workers log most of their output (module top-level,
  // early onmessage work) before DevTools attaches and enables the session;
  // delivering straight to the runtime agent would silently drop all of it.
  impl->ensureConsoleMessageStorage(contextGroupId)->addMessage(std::move(msg));
}

Local<Context> WorkerInspectorClient::ensureDefaultContextInGroup(int contextGroupId) {
  return context_.Get(isolate_);
}

}  // namespace v8_inspector
