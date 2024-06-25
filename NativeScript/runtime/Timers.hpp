//
//  Timers.hpp
//  NativeScript
//
//  Created by Eduardo Speroni on 7/23/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#ifndef Timers_hpp
#define Timers_hpp

#include "Common.h"
#include "robin_hood.h"
#include <CoreFoundation/CoreFoundation.h>
#include "IsolateWrapper.h"

namespace tns {

class TimerTask {
public:
    TimerTask(v8::Isolate *isolate,
              const v8::Local<v8::Function> &callback, double frequency,
              bool repeats,
              const std::shared_ptr<std::vector<std::shared_ptr<v8::Persistent<v8::Value>>>> &args,
              int id, double startTime) : isolate_(isolate), callback_(isolate, callback),args_(args),
    frequency_(frequency), repeats_(repeats), startTime_(startTime),  id_(id), wrapper(isolate)
    { }
    
    inline double NextTime(double targetTime) {
        if (frequency_ <= 0) {
            return targetTime;
        }
        auto timeDiff = targetTime - startTime_;
        auto div = std::div((long) timeDiff, (long) frequency_);
        return startTime_ + frequency_ * (div.quot + 1);
    }
    
    inline void Unschedule() {
        if (wrapper.IsValid()) {
            callback_.Reset();
        }
        args_.reset();
        isolate_ = nullptr;
        queued_ = false;
    }
    
    // unused for now as we're using CFRunLoopTimers
    //
    int nestingLevel_ = 0;
    v8::Isolate *isolate_;
    v8::Persistent<v8::Function> callback_;
    std::shared_ptr<std::vector<std::shared_ptr<v8::Persistent<v8::Value>>>> args_;
    double frequency_ = 0;
    bool repeats_ = false;
    bool queued_ = false;
    
    double dueTime_ = -1;
    double startTime_ = -1;
    int id_;
    IsolateWrapper wrapper;
    CFRunLoopTimerRef timer = nullptr;
};
class Timers {
public:
    static void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    
private:
    static void SetTimeoutCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SetIntervalCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void ClearTimeoutCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SetTimer(const v8::FunctionCallbackInfo<v8::Value>& info, bool repeatable);
};
}

#include <stdio.h>

#endif /* Timers_hpp */
