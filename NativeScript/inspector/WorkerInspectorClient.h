#ifndef WorkerInspectorClient_h
#define WorkerInspectorClient_h

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

#include "InspectorSessions.h"
#include "include/v8-inspector.h"
#include "src/inspector/v8-console-message.h"

namespace v8_inspector {

// V8 inspector for a single worker isolate, exposed to Chrome DevTools as a
// child target ("Target.attachedToTarget") and addressed with flat-session
// CDP messages (a top-level "sessionId" field). One instance per worker, with
// one V8 session per frontend that talks to it.
//
// Threading: constructed, dispatched into, and destroyed on the worker's own
// thread (V8's inspector is not thread-safe). Other threads interact only
// through PushMessage/PushDisconnect/NotifyTerminating/RequestPauseInterrupt.
// Incoming messages are queued and drained via a CFRunLoopSource on the
// worker's runloop; while paused, a nested loop on the worker thread pumps the
// same queue (the runloop is NOT re-entered, so postMessage deliveries stay
// queued during a pause, matching Chrome's semantics).
class WorkerInspectorClient final : public V8InspectorClient {
 public:
  // Worker thread, with the worker isolate locked and its context created.
  WorkerInspectorClient(int workerId, v8::Isolate* isolate,
                        CFRunLoopRef workerLoop, const std::string& url);
  ~WorkerInspectorClient() override;

  int WorkerId() const { return workerId_; }
  const std::string& SessionId() const { return sessionId_; }
  const std::string& TargetId() const { return targetId_; }
  const std::string& Url() const { return url_; }

  // Any thread. Queues a CDP message from a frontend and wakes the worker
  // runloop / a nested pause loop. The frontend's first message creates its
  // session, so callers must stop pushing once they pushed its disconnect.
  void PushMessage(uint64_t connectionId, const std::string& message);

  // Any thread. Drops the frontend's session.
  void PushDisconnect(uint64_t connectionId);

  // Any thread. Unblocks a paused worker and makes it drop all inspector
  // work; used by WorkerWrapper::Terminate together with TerminateExecution.
  void NotifyTerminating();

  // Any thread (with the worker isolate guaranteed alive). Schedules a pause
  // at the next statement even if the worker is busy executing JS.
  void RequestPauseInterrupt(uint64_t connectionId);

  // Worker thread (from the interrupt requested above).
  void SchedulePauseFromInterrupt();

  // Worker thread. Mirrors JsV8InspectorClient::consoleLog for this isolate.
  void consoleLog(ConsoleAPIType method,
                  const std::vector<v8::Local<v8::Value>>& args);

  // Overrides of V8InspectorClient
  void runMessageLoopOnPause(int contextGroupId) override;
  void quitMessageLoopOnPause() override;

 private:
  static constexpr int contextGroupId = 1;

  struct Incoming {
    uint64_t connectionId;
    bool disconnect;
    std::string message;
  };

  void DrainIncoming();
  bool PopIncoming(Incoming& incoming);
  void PushIncoming(Incoming incoming);
  void HandleIncoming(const Incoming& incoming);
  void SendWrapped(uint64_t connectionId, const std::string& message);

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
  std::unique_ptr<InspectorSessions> sessions_;
  v8::Persistent<v8::Context> context_;

  std::queue<Incoming> incoming_;
  std::mutex incomingMutex_;
  dispatch_semaphore_t messageArrived_;

  std::atomic<bool> dying_{false};
  std::atomic<bool> pauseTerminated_{false};
  bool runningPauseLoop_ = false;  // worker thread only
};

}  // namespace v8_inspector

#endif /* WorkerInspectorClient_h */
