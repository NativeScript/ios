#ifndef stack_trace_h
#define stack_trace_h

namespace v8 {
namespace base {
namespace debug {

bool EnableInProcessStackDumping();
void DisableSignalStackDump();

class StackTrace {
public:
    StackTrace();
    void Print() const;
};
    
}
}
}

#endif /* stack_trace_h */
