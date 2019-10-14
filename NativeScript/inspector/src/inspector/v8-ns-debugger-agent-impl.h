#ifndef NSV8DebuggerAgentImpl_h
#define NSV8DebuggerAgentImpl_h

#include "src/inspector/v8-debugger-agent-impl.h"

namespace v8_inspector {

class NSV8DebuggerAgentImpl : public V8DebuggerAgentImpl {
public:
    NSV8DebuggerAgentImpl(V8InspectorSessionImpl*, protocol::FrontendChannel*, protocol::DictionaryValue *state);

    Response getPossibleBreakpoints(
            std::unique_ptr<protocol::Debugger::Location> start,
            Maybe<protocol::Debugger::Location> end,
            Maybe<bool> restrictToFunction,
            std::unique_ptr<protocol::Array<protocol::Debugger::BreakLocation>>* locations) override;
    DISALLOW_COPY_AND_ASSIGN(NSV8DebuggerAgentImpl);
};

}

#endif /* NSV8DebuggerAgentImpl_h */
