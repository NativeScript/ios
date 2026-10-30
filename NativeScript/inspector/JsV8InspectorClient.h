#ifndef JsV8InspectorClient_h
#define JsV8InspectorClient_h

#include <dispatch/dispatch.h>
#include <netinet/in.h>

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <string>
#include <vector>

#include "InspectorSessions.h"
#include "include/v8-inspector.h"
#include "ns-v8-tracing-agent-impl.h"
#include "runtime/Runtime.h"
#include "src/inspector/v8-console-message.h"

namespace v8_inspector {

class WorkerInspectorClient;

// Debugs the main isolate and routes worker sessions. Any number of frontends
// may be connected; each gets its own V8 session on the main isolate and on
// every worker, and only sees replies to its own commands. Pauses are shared,
// as in Chrome: every frontend with the debugger enabled sees them, and any
// of them can resume. Isolate-wide V8 state is shared too: heap object
// tracking and sampling (any frontend's HeapProfiler.disable, or its
// disconnect, stops them for all) and the pause-on-exceptions setting (last
// writer wins).
class JsV8InspectorClient : V8InspectorClient {
 public:
  JsV8InspectorClient(tns::Runtime* runtime);
  void init();
  void connect(int argc, char** argv);

  // The single instance debugging the main isolate (created when IsDebug);
  // also acts as the router for worker sessions. Null in release builds.
  static JsV8InspectorClient* GetInstance();

  // Thread-safe write to one frontend; dropped once it has disconnected.
  void SendToConnection(uint64_t connectionId, const std::string& message);

  // As SendToConnection, but skips the source map rewrite (and the
  // full-message scan and copy it costs) for payloads that cannot contain a
  // sourceMapURL.
  void SendRawToConnection(uint64_t connectionId, const std::string& message);

  // Worker targets (Chrome DevTools Target domain, flat-session mode).
  // Register/Unregister are called on the worker's own thread.
  void RegisterWorkerTarget(int workerId, WorkerInspectorClient* client);
  void UnregisterWorkerTarget(int workerId);
  // Called on a worker thread by the Debugger.pause interrupt.
  void SchedulePauseInWorker(int workerId);

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

  // Work for the main isolate, in arrival order. Connect and disconnect go
  // through the same queue as messages so a frontend's session exists before
  // its first message and outlives its last.
  struct QueuedMessage {
    enum class Kind { kConnect, kDisconnect, kMessage };
    uint64_t connectionId;
    Kind kind;
    std::string message;
  };

  in_port_t listenPort_ = 0;  // main queue only
  std::unique_ptr<V8Inspector> inspector_;
  v8::Persistent<v8::Context> context_;
  // Main isolate sessions, one per frontend. Touched by whichever thread is
  // draining messages_ (the main thread, or the pause loop's thread); see
  // InspectorSessions for the exceptions.
  std::unique_ptr<InspectorSessions> sessions_;
  tns::Runtime* runtime_;
  v8::Isolate* isolate_;
  bool terminated_ = false;
  std::queue<QueuedMessage> messages_;
  bool runningNestedLoops_;
  dispatch_queue_t messagesQueue_;
  dispatch_queue_t messageLoopQueue_;
  dispatch_semaphore_t messageArrived_;
  bool isWaitingForDebugger_ = false;
  bool hasScheduledDebugBreak_ = false;

  // Connected frontends' senders; guarded by frontendsMutex_, which is never
  // held while taking another lock or calling a sender.
  std::map<uint64_t, std::function<void(const std::string&)>> frontends_;
  std::mutex frontendsMutex_;

  // Frontends that sent <Domain>.enable to a JS domain handler (DOM, CSS,
  // Network, ... from @nativescript/core). Those handlers are global, so a
  // <Domain>.disable only reaches them once no other frontend wants the
  // domain. Only touched by whichever thread is draining messages_.
  std::map<std::string, std::set<uint64_t>> jsDomainEnablers_;

  // The process-global trace controller serves one frontend at a time.
  std::unique_ptr<tns::inspector::TracingAgentImpl> tracing_agent_;
  uint64_t tracingOwner_ = 0;  // guarded by tracingMutex_
  std::mutex tracingMutex_;

  // Streams backing Network.loadNetworkResource responses, read by the
  // frontend that opened them through IO.read/IO.close (how Chrome DevTools
  // fetches source maps from the target). Served on the socket thread for
  // any session; guarded by resourceStreamsMutex_.
  struct ResourceStream {
    uint64_t connectionId;
    std::string data;
    size_t offset = 0;
  };
  std::map<std::string, ResourceStream> resourceStreams_;
  int lastStreamId_ = 0;
  std::mutex resourceStreamsMutex_;

  // Worker targets, keyed by their flat-protocol sessionId. A registered
  // client pointer stays valid until UnregisterWorkerTarget (which runs on
  // the worker's own thread, before the client is deleted).
  struct WorkerTarget {
    int workerId;
    WorkerInspectorClient* client;
  };
  // Target domain state of one connected frontend.
  struct TargetState {
    bool autoAttach = false;
    // sessionIds of the workers announced to this frontend.
    std::set<std::string> announced;
  };
  // Both guarded by workerTargetsMutex_, which is taken before
  // frontendsMutex_. A frontend has a TargetState exactly while it is
  // connected, so nothing reaches a worker on its behalf after the worker
  // was told it disconnected.
  std::map<std::string, WorkerTarget> workerTargets_;
  std::map<uint64_t, TargetState> targetStates_;
  std::mutex workerTargetsMutex_;

  static JsV8InspectorClient* instance_;

  // Routes a frontend message carrying a sessionId to its worker session
  // (socket thread). msgId is -1 when the message has no id.
  void RouteToWorker(uint64_t connectionId, const std::string& sessionId,
                     const std::string& method, long long msgId,
                     const std::string& message);
  // Announces every worker not yet announced to the frontend. Requires
  // workerTargetsMutex_.
  void AnnounceWorkerTargetsLocked(uint64_t connectionId, TargetState& state);
  void SendAttachedToTarget(uint64_t connectionId,
                            WorkerInspectorClient* client);

  // Override of V8InspectorClient
  v8::Local<v8::Context> ensureDefaultContextInGroup(
      int contextGroupId) override;

  void enableInspector(int argc, char** argv);
  void SendToAll(const std::string& message);
  void onFrontendConnected(uint64_t connectionId,
                           std::function<void(const std::string&)> sender);
  void onFrontendDisconnected(uint64_t connectionId);
  void onFrontendMessageReceived(uint64_t connectionId,
                                 const std::string& message);
  void EnqueueMessage(QueuedMessage message);
  void ScheduleMessageDrain();
  bool PumpMessage(QueuedMessage& message);
  void HandleQueued(const QueuedMessage& message);
  void DispatchFrontendMessage(uint64_t connectionId,
                               const std::string& message);
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
  void HandleLoadNetworkResource(uint64_t connectionId, int msgId,
                                 const std::string& url,
                                 const std::string& sessionId);
  void HandleIORead(uint64_t connectionId, int msgId, const std::string& handle,
                    int size, const std::string& sessionId);
  void HandleIOClose(uint64_t connectionId, int msgId,
                     const std::string& handle, const std::string& sessionId);

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
