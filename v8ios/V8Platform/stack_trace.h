//
//  stack_trace.h
//  v8ios
//
//  Created by Darin Dimitrov on 2/23/19.
//  Copyright © 2019 Progress. All rights reserved.
//

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
