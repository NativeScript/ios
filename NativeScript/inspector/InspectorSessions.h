#ifndef InspectorSessions_h
#define InspectorSessions_h

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "include/v8-inspector.h"

namespace v8_inspector {

// One V8InspectorSession per connected frontend, all on one isolate and
// context group. Each session's output goes only to its own frontend.
//
// Except for RequestPause and ClearPauseRequests, call only from the one
// thread at a time that feeds the isolate's inspector messages (its message
// drain or pause loop), or from an interrupt on the thread running its JS.
// The methods take the isolate's Locker themselves (v8::Locker is reentrant).
class InspectorSessions {
 public:
  using Output =
      std::function<void(uint64_t connectionId, const std::string& message)>;

  InspectorSessions(v8::Isolate* isolate, int contextGroupId, Output output);
  ~InspectorSessions();

  // Creates the frontend's session unless it already has one.
  void Connect(V8Inspector* inspector, uint64_t connectionId);

  // Ignored for a frontend without a session or one being closed.
  void Dispatch(uint64_t connectionId, const std::string& message);

  // Destroys the frontend's session. Its destructor disables its agents, so
  // a pause ends only if no other frontend still has the debugger enabled.
  // A session cannot be destroyed while it is dispatching (a pause loop can
  // sit under its dispatchProtocolMessage); it then gets Debugger.disable
  // right away and is destroyed once that dispatch returns.
  void Disconnect(uint64_t connectionId);

  // Destroys every session. Never while any of them is dispatching.
  void DisconnectAll();

  bool Has(uint64_t connectionId) const;

  // Any thread. Records that the frontend asked to pause; TakePauseRequests,
  // called from an isolate interrupt, schedules the pause in its session.
  void RequestPause(uint64_t connectionId);
  void TakePauseRequests();
  // Any thread. Called when a pause starts, so a request whose interrupt is
  // still pending cannot pause again after the resume.
  void ClearPauseRequests();

  void SchedulePauseInAll();

 private:
  class Channel;
  struct Session {
    std::unique_ptr<Channel> channel;
    std::unique_ptr<V8InspectorSession> session;
    int dispatchDepth = 0;
    bool closing = false;
  };

  void DispatchTo(Session* session, const std::string& message);
  void Destroy(uint64_t connectionId);

  v8::Isolate* isolate_;
  int contextGroupId_;
  Output output_;
  std::map<uint64_t, std::unique_ptr<Session>> sessions_;

  std::mutex pauseRequestsMutex_;
  std::vector<uint64_t> pauseRequests_;  // guarded by pauseRequestsMutex_
};

}  // namespace v8_inspector

#endif /* InspectorSessions_h */
