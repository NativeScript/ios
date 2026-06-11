#include <Foundation/Foundation.h>
#include <notify.h>
#include <algorithm>
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
#include "RuntimeConfig.h"
#include "WorkerInspectorClient.h"
#include "include/libplatform/libplatform.h"
#include "third_party/json.hpp"
#include "utils.h"

using namespace v8;
using json = nlohmann::json;

namespace v8_inspector {

namespace {
// Build an 8-bit `StringView` directly over a `std::string`'s storage.
// V8 inspector messages on this side are ASCII/UTF-8 JSON, so the
// previous `std::string -> std::vector<uint16_t> -> StringView` path
// inflated each byte to two and then handed it to a 16-bit constructor.
// Going straight through the 8-bit constructor avoids that doubling AND
// dodges the libc++ deprecation that prompted the inspector's
// `UChar = uint16_t -> char16_t` switch.
StringView Make8BitStringView(const std::string& value) {
  return StringView(reinterpret_cast<const uint8_t*>(value.data()), value.size());
}

// Scheme advertised to the frontend for source maps the runtime can serve.
// Chrome DevTools never loads `file:` (or `data:`/`devtools:`) resources
// through the target -- PageResourceLoader routes those to the frontend host
// machine, which cannot see files on the device. Any other scheme is fetched
// with Network.loadNetworkResource, which we answer from disk.
constexpr const char* kSourceMapScheme = "nsruntime://";

// Opt-out via nativescript.config.ts (serialized into the bundled
// package.json): `ios: { disableSourceMapURLRewrite: true }`, or the same key
// at the top level.
bool ShouldRewriteSourceMapURLs() {
  static bool disabled = []() {
    id ios = tns::Runtime::GetAppConfigValue("ios");
    id value = [ios isKindOfClass:[NSDictionary class]] ? ios[@"disableSourceMapURLRewrite"] : nil;
    if (value == nil) {
      value = tns::Runtime::GetAppConfigValue("disableSourceMapURLRewrite");
    }
    return value != nil && [value boolValue];
  }();
  return !disabled;
}

// Rewrites the sourceMapURL of outgoing Debugger.scriptParsed /
// Debugger.scriptFailedToParse events from a file url (or a url relative to
// the script's file url) to an absolute nsruntime:// url, so DevTools
// requests the map through the target instead of the frontend host.
std::string MaybeRewriteSourceMapURL(const std::string& message) {
  if (!ShouldRewriteSourceMapURLs()) {
    return message;
  }

  if (message.find("\"Debugger.scriptParsed\"") == std::string::npos &&
      message.find("\"Debugger.scriptFailedToParse\"") == std::string::npos) {
    return message;
  }

  auto parsed = json::parse(message, nullptr, false);
  if (parsed.is_discarded() || !parsed.contains("params")) {
    return message;
  }

  auto& params = parsed["params"];
  std::string sourceMapURL = params.value("sourceMapURL", "");
  if (sourceMapURL.empty() || sourceMapURL.rfind("data:", 0) == 0 ||
      sourceMapURL.rfind("http:", 0) == 0 || sourceMapURL.rfind("https:", 0) == 0 ||
      sourceMapURL.rfind(kSourceMapScheme, 0) == 0) {
    return message;
  }

  std::string path;
  if (sourceMapURL.rfind("file://", 0) == 0) {
    path = sourceMapURL.substr(strlen("file://"));
  } else if (sourceMapURL[0] == '/') {
    path = sourceMapURL;
  } else {
    // Relative to the script url, e.g. "bundle.js.map".
    std::string scriptUrl = params.value("url", "");
    if (scriptUrl.rfind("file://", 0) != 0) {
      return message;
    }
    @autoreleasepool {
      NSString* scriptPath =
          [NSString stringWithUTF8String:scriptUrl.substr(strlen("file://")).c_str()];
      NSString* mapPath = [NSString stringWithUTF8String:sourceMapURL.c_str()];
      if (scriptPath != nil && mapPath != nil) {
        NSString* resolved = [[[scriptPath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:mapPath] stringByStandardizingPath];
        if (resolved != nil) {
          path = [resolved UTF8String];
        }
      }
    }
  }

  if (path.empty()) {
    return message;
  }

  params["sourceMapURL"] = kSourceMapScheme + path;
  return parsed.dump();
}
}  // namespace

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
  instance_ = this;
}

JsV8InspectorClient* JsV8InspectorClient::GetInstance() { return instance_; }

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
            [this](std::function<void(const std::string&)> sender) {
              this->onFrontendConnected(sender);
            },
            [this](const std::string& message) { this->onFrontendMessageReceived(message); });

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

void JsV8InspectorClient::onFrontendConnected(std::function<void(const std::string&)> sender) {
  if (this->isWaitingForDebugger_) {
    this->isWaitingForDebugger_ = NO;
    CFRunLoopRef runloop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(runloop, (__bridge CFTypeRef)(NSRunLoopCommonModes), ^{
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
      this->scheduleBreak();
    });
    CFRunLoopWakeUp(runloop);
  }

  {
    std::lock_guard<std::mutex> lock(this->senderMutex_);
    this->sender_ = sender;
  }

  // this triggers a reconnection from the devtools so Debugger.scriptParsed etc. are all fired
  // again
  this->disconnect();
  this->isConnected_ = true;
}

void JsV8InspectorClient::onFrontendMessageReceived(const std::string& message) {
  // Single parse, on the socket thread, used for routing and fast paths.
  auto parsed = json::parse(message, nullptr, false);
  std::string sessionId;
  std::string method;
  long long msgId = -1;
  if (!parsed.is_discarded() && parsed.is_object()) {
    if (parsed.contains("sessionId") && parsed["sessionId"].is_string()) {
      sessionId = parsed["sessionId"].get<std::string>();
    }
    if (parsed.contains("method") && parsed["method"].is_string()) {
      method = parsed["method"].get<std::string>();
    }
    if (parsed.contains("id") && parsed["id"].is_number()) {
      msgId = parsed["id"].get<long long>();
    }
  }

  // Network.loadNetworkResource and IO.read/IO.close are filesystem-only and
  // session-agnostic (DevTools sends them on whichever session owns the
  // script whose source map it wants). Serve them right here so they work
  // for any session — even while the main isolate is paused.
  if (method == "Network.loadNetworkResource") {
    std::string url;
    if (parsed.contains("params") && parsed["params"].contains("url")) {
      url = parsed["params"]["url"].get<std::string>();
    }
    this->HandleLoadNetworkResource(static_cast<int>(msgId), url, sessionId);
    return;
  }

  if (method == "IO.read" || method == "IO.close") {
    std::string handle;
    int size = 0;
    if (parsed.contains("params")) {
      const auto& params = parsed["params"];
      if (params.contains("handle")) {
        handle = params["handle"].get<std::string>();
      }
      if (params.contains("size")) {
        size = params["size"].get<int>();
      }
    }

    if (method == "IO.read") {
      this->HandleIORead(static_cast<int>(msgId), handle, size, sessionId);
    } else {
      this->HandleIOClose(static_cast<int>(msgId), handle, sessionId);
    }
    return;
  }

  // Messages carrying a sessionId belong to a worker target (flat-session
  // protocol); route them to the worker's own thread.
  if (!sessionId.empty()) {
    this->RouteToWorker(sessionId, method, msgId, message);
    return;
  }

  dispatch_sync(this->messagesQueue_, ^{
    this->messages_.push(message);
    dispatch_semaphore_signal(messageArrived_);
  });

  // Debugger.pause needs to interrupt V8 even if the main thread is busy
  // executing JS. RequestInterrupt fires at the next safe bytecode boundary.
  if (method == "Debugger.pause") {
    isolate_->RequestInterrupt(
        [](Isolate* isolate, void* data) {
          auto client = static_cast<JsV8InspectorClient*>(data);
          client->session_->schedulePauseOnNextStatement({}, {});
        },
        this);
  }

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

void JsV8InspectorClient::RouteToWorker(const std::string& sessionId, const std::string& method,
                                        long long msgId, const std::string& message) {
  std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
  auto it = this->workerTargets_.find(sessionId);
  if (it == this->workerTargets_.end()) {
    // The worker died (Target.detachedFromTarget was sent) or never existed.
    if (msgId >= 0) {
      json error = {{"id", msgId},
                    {"sessionId", sessionId},
                    {"error", {{"code", -32001}, {"message", "Session not found"}}}};
      this->SendToFrontend(error.dump());
    }
    return;
  }

  WorkerInspectorClient* client = it->second.client;

  // Same fast path as the main session: pause a worker that is busy
  // executing JS. The worker isolate is guaranteed alive while we hold the
  // registry lock (teardown unregisters before disposing it).
  if (method == "Debugger.pause") {
    client->RequestPauseInterrupt();
  }

  client->PushMessage(message);
}

void JsV8InspectorClient::init() {
  if (inspector_ != nullptr) {
    return;
  }

  Isolate* isolate = isolate_;

  Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

  inspector_ = V8Inspector::create(isolate, this);

  // Named so the DevTools console context selector has a label for the main
  // isolate alongside the worker contexts (which are named by script url).
  static const std::string mainContextName = "main";
  inspector_->contextCreated(v8_inspector::V8ContextInfo(
      context, JsV8InspectorClient::contextGroupId, Make8BitStringView(mainContextName)));

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
  // Resource stream handles only have meaning to the frontend that opened
  // them, so drop any streams it never closed via IO.close.
  {
    std::lock_guard<std::mutex> lock(this->resourceStreamsMutex_);
    this->resourceStreams_.clear();
  }

  Isolate* isolate = isolate_;
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);

  session_->resume();
  session_.reset();

  this->isConnected_ = false;

  this->createInspectorSession();

  // Reset worker sessions too: resume any paused worker and recreate its
  // session so the (re)connecting frontend gets a clean slate, then forget
  // the auto-attach state until it sends Target.setAutoAttach again.
  {
    std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
    this->autoAttach_ = false;
    for (auto& entry : this->workerTargets_) {
      entry.second.announced = false;
      entry.second.client->PushMessage(WorkerInspectorClient::kResetSessionMessage);
    }
  }
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
  notify(ToStdString(stringView));
}

void JsV8InspectorClient::notify(const std::string& message) { this->SendToFrontend(message); }

void JsV8InspectorClient::SendToFrontend(const std::string& message) {
  std::function<void(const std::string&)> sender;
  {
    std::lock_guard<std::mutex> lock(this->senderMutex_);
    sender = this->sender_;
  }
  if (sender) {
    sender(MaybeRewriteSourceMapURL(message));
  }
}

void JsV8InspectorClient::dispatchMessage(const std::string& message) {
  StringView messageView = Make8BitStringView(message);
  Isolate* isolate = isolate_;
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  Local<Context> context = tns::Caches::Get(isolate)->GetContext();
  bool success;

  auto json_message = json::parse(message);
  std::string method = json_message["method"];

  // livesync uses the inspector socket for HMR/LiveSync...
  if (method == "Page.reload") {
    success = tns::LiveSync(this->isolate_);
    if (!success) {
      NSLog(@"LiveSync failed");
    }
    // todo: should we return here, or is it OK to pass onto a possible Page.reload domain handler?
  }

  if (method == "Tracing.start") {
    std::vector<std::string> categories;

    // Support new traceConfig format
    if (json_message.contains("params") && json_message["params"].contains("traceConfig")) {
      auto traceConfig = json_message["params"]["traceConfig"];
      if (traceConfig.contains("includedCategories")) {
        for (const auto& category : traceConfig["includedCategories"]) {
          categories.push_back(category.get<std::string>());
        }
      }
    }
    // Fall back to deprecated categories format
    else if (json_message.contains("params") && json_message["params"].contains("categories")) {
      for (const auto& category : json_message["params"]["categories"]) {
        categories.push_back(category.get<std::string>());
      }
    }

    tracing_agent_->start(categories);

    json json_response = {
        {"id", json_message["id"]},
        {"result", json::object()},
    };
    this->notify(json_response.dump());
    return;
  }

  if (method == "Tracing.end") {
    tracing_agent_->end();
    for (const auto& traceMessage : tracing_agent_->getLastTrace()) {
      notify(traceMessage);
    }
    return;
  }

  // Note: Network.loadNetworkResource and IO.read/IO.close are handled
  // earlier, in onFrontendMessageReceived, so they also work for worker
  // sessions and while this (main) isolate is paused.

  // Chrome DevTools discovers worker targets through the Target domain: its
  // ChildTargetManager sends Target.setAutoAttach {flatten: true} right
  // after connecting and expects Target.attachedToTarget events for every
  // worker. V8's inspector doesn't implement this embedder domain.
  if (method == "Target.setAutoAttach") {
    bool autoAttach = json_message.contains("params") &&
                      json_message["params"].contains("autoAttach") &&
                      json_message["params"]["autoAttach"].get<bool>();
    {
      std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
      this->autoAttach_ = autoAttach;
    }

    json response = {{"id", json_message["id"]}, {"result", json::object()}};
    this->notify(response.dump());

    if (autoAttach) {
      this->AnnounceWorkerTargets();
    }
    return;
  }

  // Ack the rest of the Target methods DevTools may send so they don't
  // produce method-not-found errors from the V8 session.
  if (method == "Target.setDiscoverTargets" || method == "Target.setRemoteLocations" ||
      method == "Target.detachFromTarget") {
    json response = {{"id", json_message["id"]}, {"result", json::object()}};
    this->notify(response.dump());
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
        StringView messageView = Make8BitStringView(returnString);
        auto msg = StringBuffer::create(messageView);
        this->sendNotification(std::move(msg));
      }
      return;
    }
  }

  // if no handler handled the message successfully, fall-through to the default V8 implementation
  this->session_->dispatchProtocolMessage(messageView);
  // if needed to test, disable the default handling and use this
  //  json error = {
  //    {"id", json_message["id"]},
  //    {"error", {
  //      {"code", -32601},
  //      {
  //        "message", "Method not found: " + method
  //      }
  //    }}
  //  };
  //  notify(error.dump());

  // TODO: check why this is needed (it should trigger automatically when script depth is 0)
  isolate->PerformMicrotaskCheckpoint();
}

namespace {
// Echo the flat-protocol sessionId so the frontend routes the reply to the
// right (worker) session; root-session messages carry none.
json WithSessionId(json message, const std::string& sessionId) {
  if (!sessionId.empty()) {
    message["sessionId"] = sessionId;
  }
  return message;
}
}  // namespace

void JsV8InspectorClient::HandleLoadNetworkResource(int msgId, const std::string& url,
                                                    const std::string& sessionId) {
  std::string path;
  if (url.rfind(kSourceMapScheme, 0) == 0) {
    path = url.substr(strlen(kSourceMapScheme));
  } else if (url.rfind("file://", 0) == 0) {
    path = url.substr(strlen("file://"));
  } else {
    // Reply with a protocol error (not success:false) so DevTools falls back
    // to loading the resource from the frontend host, which is the
    // pre-existing behavior for http(s) urls.
    json error = {{"id", msgId},
                  {"error", {{"code", -32000}, {"message", "Unsupported URL scheme"}}}};
    this->SendToFrontend(WithSessionId(error, sessionId).dump());
    return;
  }

  std::string content;
  bool loaded = false;

  if (!path.empty()) {
    @autoreleasepool {
      NSString* urlPath = [NSString stringWithUTF8String:path.c_str()];
      if (urlPath != nil) {
        // Script urls are built by stripping RuntimeConfig.BaseDir (see
        // ModuleInternal::LoadClassicScript), so map the url path back to
        // disk; fall back to the raw path for absolute urls, and to
        // percent-decoded variants for urls the frontend encoded.
        NSString* basePath = [NSString stringWithUTF8String:RuntimeConfig.BaseDir.c_str()];
        NSMutableArray<NSString*>* candidates = [NSMutableArray new];
        [candidates addObject:[basePath stringByAppendingPathComponent:urlPath]];
        [candidates addObject:urlPath];
        NSString* decoded = [urlPath stringByRemovingPercentEncoding];
        if (decoded != nil && ![decoded isEqualToString:urlPath]) {
          [candidates addObject:[basePath stringByAppendingPathComponent:decoded]];
          [candidates addObject:decoded];
        }

        for (NSString* candidate in candidates) {
          NSData* data = [NSData dataWithContentsOfFile:candidate];
          if (data != nil) {
            content.assign(static_cast<const char*>(data.bytes), data.length);
            loaded = true;
            break;
          }
        }
      }
    }
  }

  json resource;
  if (loaded) {
    std::string handle;
    {
      std::lock_guard<std::mutex> lock(this->resourceStreamsMutex_);
      handle = "ns-network-resource-" + std::to_string(++lastStreamId_);
      resourceStreams_[handle] = {std::move(content), 0};
    }
    resource = {{"success", true}, {"httpStatusCode", 200}, {"stream", handle}};
  } else {
    resource = {{"success", false},
                {"netError", -6},
                {"netErrorName", "net::ERR_FILE_NOT_FOUND"},
                {"httpStatusCode", 404}};
  }

  json response = {{"id", msgId}, {"result", {{"resource", resource}}}};
  this->SendToFrontend(WithSessionId(response, sessionId).dump());
}

void JsV8InspectorClient::HandleIORead(int msgId, const std::string& handle, int size,
                                       const std::string& sessionId) {
  json result;
  {
    std::lock_guard<std::mutex> lock(this->resourceStreamsMutex_);
    auto it = resourceStreams_.find(handle);
    if (it == resourceStreams_.end()) {
      json error = {{"id", msgId},
                    {"error", {{"code", -32602}, {"message", "Invalid stream handle"}}}};
      this->SendToFrontend(WithSessionId(error, sessionId).dump());
      return;
    }

    ResourceStream& stream = it->second;
    constexpr size_t kDefaultChunkSize = 1024 * 1024;
    size_t chunkSize = size > 0 ? static_cast<size_t>(size) : kDefaultChunkSize;
    size_t remaining = stream.data.size() - stream.offset;
    chunkSize = std::min(chunkSize, remaining);

    if (chunkSize == 0) {
      // DevTools ignores any data sent alongside eof, so only signal it once
      // the whole stream has been delivered.
      result = {{"data", ""}, {"eof", true}, {"base64Encoded", false}};
    } else {
      // Base64 keeps arbitrary file bytes intact through the JSON transport.
      NSData* chunk = [NSData dataWithBytes:stream.data.data() + stream.offset length:chunkSize];
      NSString* encoded = [chunk base64EncodedStringWithOptions:0];
      stream.offset += chunkSize;
      result = {{"data", [encoded UTF8String]}, {"eof", false}, {"base64Encoded", true}};
    }
  }

  json response = {{"id", msgId}, {"result", result}};
  this->SendToFrontend(WithSessionId(response, sessionId).dump());
}

void JsV8InspectorClient::HandleIOClose(int msgId, const std::string& handle,
                                        const std::string& sessionId) {
  {
    std::lock_guard<std::mutex> lock(this->resourceStreamsMutex_);
    resourceStreams_.erase(handle);
  }
  json response = {{"id", msgId}, {"result", json::object()}};
  this->SendToFrontend(WithSessionId(response, sessionId).dump());
}

void JsV8InspectorClient::RegisterWorkerTarget(int workerId, WorkerInspectorClient* client) {
  std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
  WorkerTarget target{workerId, client, false};

  if (this->isConnected_ && this->autoAttach_) {
    target.announced = true;
    json attached = {{"method", "Target.attachedToTarget"},
                     {"params",
                      {{"sessionId", client->SessionId()},
                       {"targetInfo",
                        {{"targetId", client->TargetId()},
                         {"type", "worker"},
                         {"title", client->Url()},
                         {"url", client->Url()},
                         {"attached", true},
                         {"canAccessOpener", false}}},
                       {"waitingForDebugger", false}}}};
    this->SendToFrontend(attached.dump());
  }

  this->workerTargets_.emplace(client->SessionId(), target);
}

void JsV8InspectorClient::UnregisterWorkerTarget(int workerId) {
  std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
  for (auto it = this->workerTargets_.begin(); it != this->workerTargets_.end(); ++it) {
    if (it->second.workerId != workerId) {
      continue;
    }

    if (it->second.announced && this->isConnected_) {
      json detached = {{"method", "Target.detachedFromTarget"},
                       {"params",
                        {{"sessionId", it->second.client->SessionId()},
                         {"targetId", it->second.client->TargetId()}}}};
      this->SendToFrontend(detached.dump());
    }

    this->workerTargets_.erase(it);
    return;
  }
}

void JsV8InspectorClient::AnnounceWorkerTargets() {
  std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
  for (auto& entry : this->workerTargets_) {
    WorkerTarget& target = entry.second;
    if (target.announced) {
      continue;
    }
    target.announced = true;

    json attached = {{"method", "Target.attachedToTarget"},
                     {"params",
                      {{"sessionId", target.client->SessionId()},
                       {"targetInfo",
                        {{"targetId", target.client->TargetId()},
                         {"type", "worker"},
                         {"title", target.client->Url()},
                         {"url", target.client->Url()},
                         {"attached", true},
                         {"canAccessOpener", false}}},
                       {"waitingForDebugger", false}}}};
    this->SendToFrontend(attached.dump());
  }
}

void JsV8InspectorClient::SchedulePauseInWorker(int workerId) {
  std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
  for (auto& entry : this->workerTargets_) {
    if (entry.second.workerId == workerId) {
      entry.second.client->SchedulePauseFromInterrupt();
      return;
    }
  }
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

    // Check for ES module (.mjs) first, then fallback to CommonJS (.js)
    NSString* appPath = [NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()];
    NSString* mjsPath =
        [[appPath stringByAppendingPathComponent:@"tns_modules/inspector_modules.mjs"]
            stringByStandardizingPath];
    NSString* jsPath = [[appPath stringByAppendingPathComponent:@"tns_modules/inspector_modules.js"]
        stringByStandardizingPath];

    std::string modulePath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:mjsPath]) {
      modulePath = [mjsPath UTF8String];
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:jsPath]) {
      modulePath = [jsPath UTF8String];
    } else {
      // No inspector modules found, skip loading
      return;
    }

    runtime_->RunModule(modulePath);
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

  StringView messageView = Make8BitStringView(message);
  auto msg = StringBuffer::create(messageView);
  client->sendNotification(std::move(msg));
}

void JsV8InspectorClient::inspectorTimestampCallback(const FunctionCallbackInfo<Value>& args) {
  double timestamp = std::chrono::seconds(std::chrono::seconds(std::time(NULL))).count();
  args.GetReturnValue().Set(timestamp);
}

void JsV8InspectorClient::consoleLog(v8::Isolate* isolate, ConsoleAPIType method,
                                     const std::vector<v8::Local<v8::Value>>& args) {
  // Note, here we access private API
  auto* impl = reinterpret_cast<v8_inspector::V8InspectorImpl*>(inspector_.get());

  if (impl->isolate() != isolate) {
    // Logging from a worker isolate: forward to that worker's own inspector.
    // We're on the worker's thread here (console.* runs where it's called),
    // which is also the only thread that deletes the client — so the pointer
    // obtained under the registry lock stays valid for the call.
    tns::Runtime* runtime = tns::Runtime::GetRuntime(isolate);
    if (runtime == nullptr) {
      return;
    }

    WorkerInspectorClient* client = nullptr;
    {
      std::lock_guard<std::mutex> lock(this->workerTargetsMutex_);
      for (auto& entry : this->workerTargets_) {
        if (entry.second.workerId == runtime->WorkerId()) {
          client = entry.second.client;
          break;
        }
      }
    }

    if (client != nullptr) {
      client->consoleLog(method, args);
    }
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

  // Going through the message storage both reports to enabled sessions and
  // keeps the message for replay on Runtime.enable, so anything logged
  // before the frontend attaches shows up as console history.
  impl->ensureConsoleMessageStorage(contextGroupId)->addMessage(std::move(msg));
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

JsV8InspectorClient* JsV8InspectorClient::instance_ = nullptr;

}  // namespace v8_inspector
