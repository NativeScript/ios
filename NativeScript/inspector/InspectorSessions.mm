#include "InspectorSessions.h"

#include "include/v8-locker.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

namespace {
StringView Make8BitStringView(const std::string& value) {
  return StringView(reinterpret_cast<const uint8_t*>(value.data()), value.size());
}

constexpr const char* kDisableDebugger = "{\"id\":0,\"method\":\"Debugger.disable\"}";
}  // namespace

class InspectorSessions::Channel final : public V8Inspector::Channel {
 public:
  Channel(const Output& output, uint64_t connectionId)
      : output_(output), connectionId_(connectionId) {}

  void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override {
    output_(connectionId_, ToStdString(message->string()));
  }

  void sendNotification(std::unique_ptr<StringBuffer> message) override {
    output_(connectionId_, ToStdString(message->string()));
  }

  void flushProtocolNotifications() override {}

 private:
  const Output& output_;
  uint64_t connectionId_;
};

InspectorSessions::InspectorSessions(Isolate* isolate, int contextGroupId, Output output)
    : isolate_(isolate), contextGroupId_(contextGroupId), output_(std::move(output)) {}

InspectorSessions::~InspectorSessions() { this->DisconnectAll(); }

void InspectorSessions::Connect(V8Inspector* inspector, uint64_t connectionId) {
  if (sessions_.count(connectionId) != 0) {
    return;
  }

  Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);

  auto entry = std::make_unique<Session>();
  entry->channel = std::make_unique<Channel>(output_, connectionId);
  entry->session =
      inspector->connect(contextGroupId_, entry->channel.get(), {}, V8Inspector::kFullyTrusted);
  sessions_.emplace(connectionId, std::move(entry));
}

void InspectorSessions::Dispatch(uint64_t connectionId, const std::string& message) {
  auto it = sessions_.find(connectionId);
  if (it == sessions_.end() || it->second->closing) {
    return;
  }

  Session* session = it->second.get();
  this->DispatchTo(session, message);
  if (session->closing && session->dispatchDepth == 0) {
    this->Destroy(connectionId);
  }
}

void InspectorSessions::DispatchTo(Session* session, const std::string& message) {
  Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);

  // Destroy never runs while this is above zero, so `session` stays valid
  // across the call even if the frontend disconnects inside it.
  session->dispatchDepth++;
  session->session->dispatchProtocolMessage(Make8BitStringView(message));
  session->dispatchDepth--;
}

void InspectorSessions::Disconnect(uint64_t connectionId) {
  auto it = sessions_.find(connectionId);
  if (it == sessions_.end()) {
    return;
  }

  Session* session = it->second.get();
  if (session->dispatchDepth == 0) {
    this->Destroy(connectionId);
    return;
  }

  if (!session->closing) {
    session->closing = true;
    this->DispatchTo(session, kDisableDebugger);
  }
}

void InspectorSessions::DisconnectAll() {
  while (!sessions_.empty()) {
    this->Destroy(sessions_.begin()->first);
  }
}

bool InspectorSessions::Has(uint64_t connectionId) const {
  auto it = sessions_.find(connectionId);
  return it != sessions_.end() && !it->second->closing;
}

void InspectorSessions::Destroy(uint64_t connectionId) {
  auto node = sessions_.extract(connectionId);
  if (node.empty()) {
    return;
  }

  Locker locker(isolate_);
  Isolate::Scope isolate_scope(isolate_);
  HandleScope handle_scope(isolate_);
  // The session uses its channel until its destructor returns.
  node.mapped()->session.reset();
  node.mapped()->channel.reset();
}

void InspectorSessions::RequestPause(uint64_t connectionId) {
  std::lock_guard<std::mutex> lock(pauseRequestsMutex_);
  pauseRequests_.push_back(connectionId);
}

void InspectorSessions::TakePauseRequests() {
  std::vector<uint64_t> requests;
  {
    std::lock_guard<std::mutex> lock(pauseRequestsMutex_);
    requests.swap(pauseRequests_);
  }

  for (uint64_t connectionId : requests) {
    auto it = sessions_.find(connectionId);
    if (it != sessions_.end() && !it->second->closing) {
      it->second->session->schedulePauseOnNextStatement({}, {});
    }
  }
}

void InspectorSessions::ClearPauseRequests() {
  std::lock_guard<std::mutex> lock(pauseRequestsMutex_);
  pauseRequests_.clear();
}

void InspectorSessions::SchedulePauseInAll() {
  for (auto& entry : sessions_) {
    if (!entry.second->closing) {
      entry.second->session->schedulePauseOnNextStatement({}, {});
    }
  }
}

}  // namespace v8_inspector
