#include "v8-log-agent-impl.h"
#include "JsV8InspectorClient.h"
#include "utils.h"
#include "Helpers.h"

namespace v8_inspector {

namespace LogAgentState {
    static const char logEnabled[] = "logEnabled";
}

V8LogAgentImpl::V8LogAgentImpl(V8InspectorSessionImpl* session, protocol::FrontendChannel* frontendChannel, protocol::DictionaryValue* state)
    : m_frontend(frontendChannel),
      m_state(state),
      m_enabled(false) {
    V8LogAgentImpl::instance_ = this;
}

V8LogAgentImpl::~V8LogAgentImpl() {
}

DispatchResponse V8LogAgentImpl::enable() {
    if (m_enabled) {
        return DispatchResponse::ServerError("Log Agent already enabled!");
    }

    m_state->setBoolean(LogAgentState::logEnabled, true);
    m_enabled = true;

    return DispatchResponse::Success();
}

DispatchResponse V8LogAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::Success();
    }

    m_state->setBoolean(LogAgentState::logEnabled, false);

    m_enabled = false;

    return DispatchResponse::Success();
}

void V8LogAgentImpl::EntryAdded(const std::string& text, std::string verbosityLevel, std::string url, int lineNumber) {
    V8LogAgentImpl* logAgentInstance = V8LogAgentImpl::instance_;

    if (!logAgentInstance) {
        return;
    }

    auto nano = std::chrono::time_point_cast<std::chrono::milliseconds>(std::chrono::system_clock::now());
    double timestamp = nano.time_since_epoch().count();

    std::vector<uint16_t> vector = tns::ToVector(text);
    String16 textString16 = String16(vector.data(), vector.size());

    auto logEntry = protocol::Log::LogEntry::create()
        .setSource(protocol::Log::LogEntry::SourceEnum::Javascript)
        .setText(textString16)
        .setLevel(verbosityLevel.c_str())
        .setTimestamp(timestamp)
        .setUrl(url.c_str())
        .setLineNumber(lineNumber - 1)
        .build();

    logAgentInstance->m_frontend.entryAdded(std::move(logEntry));
}

DispatchResponse V8LogAgentImpl::startViolationsReport(std::unique_ptr<protocol::Array<protocol::Log::ViolationSetting>> in_config) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8LogAgentImpl::stopViolationsReport() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8LogAgentImpl::clear() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

V8LogAgentImpl* V8LogAgentImpl::instance_ = nullptr;

}
