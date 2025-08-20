//
//  Timers.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 7/23/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "Timers.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <vector>

#include "Caches.h"
#include "Helpers.h"
#include "ModuleBinding.hpp"
#include "Runtime.h"

using namespace v8;

// Takes a value and transform into a positive number
// returns a negative number if the number is negative or invalid
inline static double ToMaybePositiveValue(const v8::Local<v8::Value>& v,
                                          const v8::Local<v8::Context>& ctx) {
  double value = -1;
  if (v->IsNullOrUndefined()) {
    return -1;
  }
  Local<Number> numberValue;
  auto success = v->ToNumber(ctx).ToLocal(&numberValue);
  if (success) {
    value = numberValue->Value();
    if (isnan(value)) {
      value = -1;
    }
  }
  return value;
}

static double now_ms() {
  struct timespec res;
  clock_gettime(CLOCK_MONOTONIC, &res);
  return 1000.0 * res.tv_sec + (double)res.tv_nsec / 1e6;
}

namespace tns {

class TimerState {
 public:
  std::mutex timerMutex_;
  std::atomic<int> currentTimerId = 0;
  robin_hood::unordered_map<int, std::shared_ptr<TimerTask>> timerMap_;
  CFRunLoopRef runloop;

  void removeTask(const std::shared_ptr<TimerTask>& task) {
    removeTask(task->id_);
  }

  void removeTask(const int& taskId) {
    auto it = timerMap_.find(taskId);
    if (it != timerMap_.end()) {
      // auto wasScheduled = it->second->queued_;
      auto timer = it->second->timer;
      it->second->Unschedule();
      timerMap_.erase(it);
      CFRunLoopTimerInvalidate(timer);
      // timer and context will be released by the retain function
      // CFRunLoopTimerContext context;
      // CFRunLoopTimerGetContext(timer, &context);
      // delete static_cast<std::shared_ptr<TimerTask>*>(context.info);
      // CFRelease(timer);
    }
  }

  // this all comes from the android runtime implementation
  void addTask(std::shared_ptr<TimerTask> task) {
    if (task->queued_) {
      return;
    }
    //        auto now = now_ms();
    // task->nestingLevel_ = nesting + 1;
    task->queued_ = true;
    // theoretically this should be >5 on the spec, but we're following chromium
    // behavior here again
    //        if (task->nestingLevel_ >= 5 && task->frequency_ < 4) {
    //            task->frequency_ = 4;
    //            task->startTime_ = now;
    //        }
    timerMap_.emplace(task->id_, task);
    // not needed on the iOS runtime for now
    //        auto newTime = task->NextTime(now);
    //        task->dueTime_ = newTime;
  }
};

// this class is attached to the timer object itself
// we use a retain/release flow because we want to bind this to the Timer itself
// additionally it helps if we deal with timers on different threads
// The current implementation puts the timers on the runtime's runloop, so it
// shouldn't be necessary.
class TimerContext {
 public:
  std::atomic<int> retainCount{0};
  std::shared_ptr<TimerTask> task;
  TimerState* state;
  ~TimerContext() {
    task->Unschedule();
    CFRelease(task->timer);
  }

  static const void* TimerRetain(const void* ret) {
    auto v = (TimerContext*)(ret);
    v->retainCount++;
    return ret;
  }

  static void TimerRelease(const void* ret) {
    auto v = (TimerContext*)(ret);
    if (--v->retainCount <= 0) {
      delete v;
    };
  }
};

void Timers::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  auto timerState = new TimerState();
  timerState->runloop = Runtime::GetRuntime(isolate)->RuntimeLoop();
  Caches::Get(isolate)->registerCacheBoundObject(timerState);
  tns::NewFunctionTemplate(isolate, Timers::SetTimeoutCallback,
                           v8::External::New(isolate, timerState));
  tns::SetMethod(isolate, globalTemplate, "__ns__setTimeout",
                 Timers::SetTimeoutCallback,
                 v8::External::New(isolate, timerState));
  tns::SetMethod(isolate, globalTemplate, "__ns__setInterval",
                 Timers::SetIntervalCallback,
                 v8::External::New(isolate, timerState));
  tns::SetMethod(isolate, globalTemplate, "__ns__clearTimeout",
                 Timers::ClearTimeoutCallback,
                 v8::External::New(isolate, timerState));
  tns::SetMethod(isolate, globalTemplate, "__ns__clearInterval",
                 Timers::ClearTimeoutCallback,
                 v8::External::New(isolate, timerState));
  Caches::Get(isolate)->registerCacheBoundObject(new TimerState());
}

void TimerCallback(CFRunLoopTimerRef timer, void* info) {
  TimerContext* data = (TimerContext*)info;
  auto task = data->task;
  // we check for this first so we can be 100% sure that this task is still
  // alive since we're always dealing with the runtime's runloop, it should
  // always work if we even support firing the timers in a another runloop, then
  // this is useful as it'll avoid use-after-free issues
  if (!task->queued_ || !task->wrapper.IsValid()) {
    return;
  }
  auto isolate = task->isolate_;

  v8::Locker locker(isolate);
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handleScope(isolate);
  // ensure we're still queued after locking
  if (!task->queued_) {
    return;
  }

  v8::Local<v8::Function> cb = task->callback_.Get(isolate);
  v8::Local<v8::Context> context = cb->GetCreationContextChecked();
  Context::Scope context_scope(context);
  int argc = task->args_ ? static_cast<int>(task->args_->size()) : 0;
  if (argc > 0) {
    // allocate an array of the right size
    std::vector<Local<Value>> argv(argc);

    for (int i = 0; i < argc; ++i) {
      argv[i] = task->args_->at(i)->Get(isolate);
    }

    // pass pointer to the first element
    (void)cb->Call(context, context->Global(), argc, argv.data());
  } else {
    (void)cb->Call(context, context->Global(), 0, nullptr);
  }

  if (!task->repeats_) {
    data->state->removeTask(task);
  }
}

void Timers::SetTimer(const v8::FunctionCallbackInfo<v8::Value>& args,
                      bool repeatable) {
  auto argLength = args.Length();
  auto extData = args.Data().As<External>();
  TimerState* state = reinterpret_cast<TimerState*>(extData->Value());
  int id = ++state->currentTimerId;
  if (argLength >= 1) {
    if (!args[0]->IsFunction()) {
      args.GetReturnValue().Set(-1);
      return;
    }
    auto handler = args[0].As<v8::Function>();
    auto isolate = args.GetIsolate();
    auto ctx = isolate->GetCurrentContext();
    long timeout = 0;
    if (argLength >= 2) {
      timeout = (long)ToMaybePositiveValue(args[1], ctx);
      if (timeout < 0) {
        timeout = 0;
      }
    }
    std::shared_ptr<std::vector<std::shared_ptr<Persistent<Value>>>> argArray;
    if (argLength >= 3) {
      auto otherArgLength = argLength - 2;
      argArray =
          std::make_shared<std::vector<std::shared_ptr<Persistent<Value>>>>(
              otherArgLength);
      for (int i = 0; i < otherArgLength; i++) {
        (*argArray)[i] =
            std::make_shared<Persistent<Value>>(isolate, args[i + 2]);
#ifdef DEBUG
        (*argArray)[i]->AnnotateStrongRetainer("timer_argument");
#endif
      }
    }

    auto task = std::make_shared<TimerTask>(isolate, handler, timeout,
                                            repeatable, argArray, id, now_ms());
#ifdef DEBUG
    task->callback_.AnnotateStrongRetainer("timer");
#endif
    task->repeats_ = repeatable;

    CFRunLoopTimerContext timerContext = {0, NULL, NULL, NULL, NULL};
    auto timerData = new TimerContext();
    timerData->task = task;
    timerData->state = state;
    timerContext.info = timerData;
    timerContext.retain = TimerContext::TimerRetain;
    timerContext.release = TimerContext::TimerRelease;

    // we do this because the timer should take hold of exactly 1 retaincount
    // after scheduling so if by our manual release the retain is 0 then we need
    // to cleanup the TimerContext
    TimerContext::TimerRetain(timerData);

    // timeout should be bigger than 0 if it's repeatable and 0
    auto timeoutInSeconds =
        repeatable && timeout == 0 ? 0.0000001f : timeout / 1000.f;
    auto timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + timeoutInSeconds,
        repeatable ? timeoutInSeconds : 0, 0, 0, TimerCallback, &timerContext);
    state->addTask(task);
    // set the actual timer we created
    task->timer = timer;
    CFRunLoopAddTimer(state->runloop, timer, kCFRunLoopCommonModes);
    TimerContext::TimerRelease(timerData);
    //        auto task = std::make_shared<TimerTask>(isolate, handler, timeout,
    //        repeatable,
    //                                                argArray, id, now_ms());
    // thiz->addTask(task);
  }
  args.GetReturnValue().Set(id);
}

void Timers::SetTimeoutCallback(
    const v8::FunctionCallbackInfo<v8::Value>& args) {
  Timers::SetTimer(args, false);
}

void Timers::SetIntervalCallback(
    const v8::FunctionCallbackInfo<v8::Value>& args) {
  Timers::SetTimer(args, true);
}

void Timers::ClearTimeoutCallback(
    const v8::FunctionCallbackInfo<v8::Value>& args) {
  auto argLength = args.Length();
  auto extData = args.Data().As<External>();
  auto thiz = reinterpret_cast<TimerState*>(extData->Value());
  int id = -1;
  if (argLength > 0) {
    auto isolate = args.GetIsolate();
    auto ctx = isolate->GetCurrentContext();
    id = (int)ToMaybePositiveValue(args[0], ctx);
  }
  // ids start at 1
  if (id > 0) {
    thiz->removeTask(id);
  }
}

}  // namespace tns

NODE_BINDING_PER_ISOLATE_INIT_OBJ(timers, tns::Timers::Init)
