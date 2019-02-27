//
//  stack_trace_posix.cpp
//  v8ios
//
//  Created by Darin Dimitrov on 2/23/19.
//  Copyright © 2019 Progress. All rights reserved.
//

#include <signal.h>
#include <memory>
#include "stack_trace.h"

bool v8::base::debug::EnableInProcessStackDumping() {
    // When running in an application, our code typically expects SIGPIPE
    // to be ignored.  Therefore, when testing that same code, it should run
    // with SIGPIPE ignored as well.
    struct sigaction sigpipe_action;
    memset(&sigpipe_action, 0, sizeof(sigpipe_action));
    sigpipe_action.sa_handler = SIG_IGN;
    sigemptyset(&sigpipe_action.sa_mask);
    bool success = (sigaction(SIGPIPE, &sigpipe_action, nullptr) == 0);
    
    // Avoid hangs during backtrace initialization, see above.
    // WarmUpBacktrace();
    
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_flags = SA_RESETHAND | SA_SIGINFO;
    //action.sa_sigaction = &StackDumpSignalHandler;
    sigemptyset(&action.sa_mask);
    
    success &= (sigaction(SIGILL, &action, nullptr) == 0);
    success &= (sigaction(SIGABRT, &action, nullptr) == 0);
    success &= (sigaction(SIGFPE, &action, nullptr) == 0);
    success &= (sigaction(SIGBUS, &action, nullptr) == 0);
    success &= (sigaction(SIGSEGV, &action, nullptr) == 0);
    success &= (sigaction(SIGSYS, &action, nullptr) == 0);
    
    //dump_stack_in_signal_handler = true;
    
    return success;
}

void v8::base::debug::DisableSignalStackDump() {
    
}

v8::base::debug::StackTrace::StackTrace() {
    
}

void v8::base::debug::StackTrace::Print() const {
    
}
