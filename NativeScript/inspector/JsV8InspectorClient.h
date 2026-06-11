#ifndef JsV8InspectorClient_h
#define JsV8InspectorClient_h

#include <dispatch/dispatch.h>

#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "include/v8-inspector.h"
#include "ns-v8-tracing-agent-impl.h"
#include "runtime/Runtime.h"
#include "src/inspector/v8-console-message.h"

namespace v8_inspector {

class WorkerInspectorClient;

class JsV8InspectorClient : V8InspectorClient, V8Inspector::Channel {
 public:
  JsV8InspectorClient(tns::Runtime* runtime);
  void init();
  void connect(int argc, char** argv);
  void disconnect();
  void dispatchMessage(const std::string& message);

  // The single instance debugging the main isolate (created when IsDebug);
  // also acts as the router for worker sessions. Null in release builds.
  static JsV8InspectorClient* GetInstance();

  // Thread-safe write to the connected frontend (no-op when disconnected).
  void SendToFrontend(const std::string& message);

  // Worker targets (Chrome DevTools Target domain, flat-session mode).
  // Register/Unregister are called on the worker's own thread.
  void RegisterWorkerTarget(int workerId, WorkerInspectorClient* client);
  void UnregisterWorkerTarget(int workerId);
  // Called on a worker thread by the Debugger.pause interrupt.
  void SchedulePauseInWorker(int workerId);

  // Overrides of V8Inspector::Channel
  void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override;
  void sendNotification(std::unique_ptr<StringBuffer> message) override;
  void flushProtocolNotifications() override;

  // Overrides of V8InspectorClient
  void runMessageLoopOnPause(int contextGroupId) override;
  void quitMessageLoopOnPause() override;

  void scheduleBreak();
  void registerModules();

  void consoleLog(v8::Isolate* isolate, ConsoleAPIType method,
                  const std::vector<v8::Local<v8::Value>>& args);

  static std::map<std::string, v8::Persistent<v8::Object>*> Domains;

 private:
  static constexpr int contextGroupId = 1;

  bool isConnected_;
  std::unique_ptr<V8Inspector> inspector_;
  v8::Persistent<v8::Context> context_;
  std::unique_ptr<V8InspectorSession> session_;
  tns::Runtime* runtime_;
  v8::Isolate* isolate_;
  bool terminated_;
  std::queue<std::string> messages_;
  bool runningNestedLoops_;
  dispatch_queue_t messagesQueue_;
  dispatch_queue_t messageLoopQueue_;
  dispatch_semaphore_t messageArrived_;
  std::function<void(const std::string&)> sender_;
  bool isWaitingForDebugger_;
  bool hasScheduledDebugBreak_;

  std::unique_ptr<tns::inspector::TracingAgentImpl> tracing_agent_;

  // Streams backing Network.loadNetworkResource responses, read by the
  // frontend through IO.read/IO.close (how Chrome DevTools fetches source
  // maps from the target). Served on the socket thread for any session;
  // guarded by resourceStreamsMutex_.
  struct ResourceStream {
    std::string data;
    size_t offset = 0;
  };
  std::map<std::string, ResourceStream> resourceStreams_;
  int lastStreamId_ = 0;
  std::mutex resourceStreamsMutex_;

  // Worker targets announced to the frontend via Target.attachedToTarget,
  // keyed by their flat-protocol sessionId. Guarded by workerTargetsMutex_;
  // a registered client pointer stays valid until UnregisterWorkerTarget
  // (which runs on the worker's own thread, before the client is deleted).
  struct WorkerTarget {
    int workerId;
    WorkerInspectorClient* client;
    bool announced = false;
  };
  std::map<std::string, WorkerTarget> workerTargets_;
  std::mutex workerTargetsMutex_;
  bool autoAttach_ = false;  // guarded by workerTargetsMutex_

  static JsV8InspectorClient* instance_;

  std::mutex senderMutex_;

  // Routes a frontend message carrying a sessionId to its worker session
  // (socket thread). msgId is -1 when the message has no id.
  void RouteToWorker(const std::string& sessionId, const std::string& method,
                     long long msgId, const std::string& message);
  // Announces all not-yet-announced workers (after Target.setAutoAttach).
  void AnnounceWorkerTargets();

  // Override of V8InspectorClient
  v8::Local<v8::Context> ensureDefaultContextInGroup(
      int contextGroupId) override;

  void enableInspector(int argc, char** argv);
  void createInspectorSession();
  void notify(std::unique_ptr<StringBuffer> message);
  void notify(const std::string& message);
  void onFrontendConnected(std::function<void(const std::string&)> sender);
  void onFrontendMessageReceived(const std::string& message);
  std::string PumpMessage();
  static void registerDomainDispatcherCallback(
      const v8::FunctionCallbackInfo<v8::Value>& args);
  static void inspectorSendEventCallback(
      const v8::FunctionCallbackInfo<v8::Value>& args);
  static void inspectorTimestampCallback(
      const v8::FunctionCallbackInfo<v8::Value>& args);

  // Source map delivery to Chrome DevTools (Network.loadNetworkResource + IO
  // domain). V8's inspector doesn't implement these embedder domains. The
  // handlers are filesystem-only and thread-safe; they serve any session
  // (sessionId is echoed in the reply when non-empty).
  void HandleLoadNetworkResource(int msgId, const std::string& url,
                                 const std::string& sessionId);
  void HandleIORead(int msgId, const std::string& handle, int size,
                    const std::string& sessionId);
  void HandleIOClose(int msgId, const std::string& handle,
                     const std::string& sessionId);

  // {N} specific helpers
  bool CallDomainHandlerFunction(v8::Local<v8::Context> context,
                                 v8::Local<v8::Function> domainMethodFunc,
                                 const v8::Local<v8::Object>& arg,
                                 v8::Local<v8::Object>& domainDebugger,
                                 v8::Local<v8::Value>& result);
  std::string GetReturnMessageFromDomainHandlerResult(
      const v8::Local<v8::Value>& result,
      const v8::Local<v8::Value>& requestId);
};

}  // namespace v8_inspector

#endif /* JsV8InspectorClient_h */
