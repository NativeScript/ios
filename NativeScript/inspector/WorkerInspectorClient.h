#ifndef WorkerInspectorClient_h
#define WorkerInspectorClient_h

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

#include "include/v8-inspector.h"
#include "src/inspector/v8-console-message.h"

namespace v8_inspector {

// V8 inspector for a single worker isolate, exposed to Chrome DevTools as a
// child target ("Target.attachedToTarget") and addressed with flat-session
// CDP messages (a top-level "sessionId" field). One instance per worker.
//
// Threading: constructed, dispatched into, and destroyed on the worker's own
// thread (V8's inspector is not thread-safe). Other threads interact only
// through PushMessage/NotifyTerminating/RequestPauseInterrupt. Incoming
// messages are queued and drained via a CFRunLoopSource on the worker's
// runloop; while paused, a nested loop on the worker thread pumps the same
// queue (the runloop is NOT re-entered, so postMessage deliveries stay queued
// during a pause, matching Chrome's semantics).
class WorkerInspectorClient final : public V8InspectorClient,
                                    public V8Inspector::Channel {
 public:
  // Worker thread, with the worker isolate locked and its context created.
  WorkerInspectorClient(int workerId, v8::Isolate* isolate,
                        CFRunLoopRef workerLoop, const std::string& url);
  ~WorkerInspectorClient() override;

  int WorkerId() const { return workerId_; }
  const std::string& SessionId() const { return sessionId_; }
  const std::string& TargetId() const { return targetId_; }
  const std::string& Url() const { return url_; }

  // Any thread. Queues a CDP message (already stripped of routing concerns)
  // and wakes the worker runloop / a nested pause loop.
  void PushMessage(const std::string& message);

  // Any thread. Unblocks a paused worker and makes it drop all inspector
  // work; used by WorkerWrapper::Terminate together with TerminateExecution.
  void NotifyTerminating();

  // Any thread (with the worker isolate guaranteed alive). Schedules a pause
  // at the next statement even if the worker is busy executing JS.
  void RequestPauseInterrupt();

  // Worker thread (from the interrupt requested above).
  void SchedulePauseFromInterrupt();

  // Worker thread. Mirrors JsV8InspectorClient::consoleLog for this isolate.
  void consoleLog(ConsoleAPIType method,
                  const std::vector<v8::Local<v8::Value>>& args);

  // Internal control message pushed by the root client on frontend
  // reconnect; resumes the worker if paused and recreates its session.
  static constexpr const char* kResetSessionMessage =
      "{\"__nsInternal\":\"resetSession\"}";

  // Overrides of V8Inspector::Channel
  void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override;
  void sendNotification(std::unique_ptr<StringBuffer> message) override;
  void flushProtocolNotifications() override;

  // Overrides of V8InspectorClient
  void runMessageLoopOnPause(int contextGroupId) override;
  void quitMessageLoopOnPause() override;

 private:
  static constexpr int contextGroupId = 1;

  void DrainIncoming();
  std::string PopMessage();
  void DispatchOne(const std::string& message);
  void HandleResetRequest();
  void DoResetSession();
  void MaybeResetSession();
  void SendWrapped(const std::string& message);

  v8::Local<v8::Context> ensureDefaultContextInGroup(
      int contextGroupId) override;

  int workerId_;
  std::string sessionId_;
  std::string targetId_;
  std::string url_;
  v8::Isolate* isolate_;
  CFRunLoopRef workerLoop_;
  CFRunLoopSourceRef source_ = nullptr;

  std::unique_ptr<V8Inspector> inspector_;
  std::unique_ptr<V8InspectorSession> session_;
  v8::Persistent<v8::Context> context_;

  std::queue<std::string> incoming_;
  std::mutex incomingMutex_;
  dispatch_semaphore_t messageArrived_;

  std::atomic<bool> dying_{false};
  std::atomic<bool> pauseTerminated_{false};
  bool runningPauseLoop_ = false;  // worker thread only
  bool pendingReset_ = false;      // worker thread only
};

}  // namespace v8_inspector

#endif /* WorkerInspectorClient_h */
