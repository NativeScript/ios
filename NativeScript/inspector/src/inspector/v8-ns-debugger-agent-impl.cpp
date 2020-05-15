#include "v8-ns-debugger-agent-impl.h"

namespace v8_inspector {

NSV8DebuggerAgentImpl::NSV8DebuggerAgentImpl(
    V8InspectorSessionImpl* session, protocol::FrontendChannel* frontendChannel, protocol::DictionaryValue* state)
    : V8DebuggerAgentImpl(session, frontendChannel, state) {
}

Response NSV8DebuggerAgentImpl::getPossibleBreakpoints(
    std::unique_ptr<protocol::Debugger::Location> start,
    Maybe<protocol::Debugger::Location> end,
    Maybe<bool> restrictToFunction,
    std::unique_ptr<protocol::Array<protocol::Debugger::BreakLocation>>* locations) {
//    return V8DebuggerAgentImpl::getPossibleBreakpoints(std::move(start), std::move(end), std::move(restrictToFunction), locations);
    *locations = std::make_unique<protocol::Array<protocol::Debugger::BreakLocation>>();
    return Response::Success();
}

}  // namespace v8_inspector
