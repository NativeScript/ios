//
//  Timers.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 7/23/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "Timers.hpp"

#include <algorithm>
#include <vector>

#include "Caches.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "ModuleBinding.hpp"
#include "Runtime.h"

/*
 * Overall rules when modifying this file:
 * Everything runs on the isolate's home thread under its v8::Locker.
 * `sortedTimers_` must always be sorted by dueTime (stable for equal
 * dueTimes) and in sync with `timerMap_` (except tombstones, which only live
 * in `sortedTimers_`).
 *
 * Scheduling model: every scheduled timer posts one anonymous "due token"
 * through the runtime EventLoop's ordered lane, at a due time >= the timer's.
 * Timers therefore share one due-ordered domain with ordered macrotasks and
 * stay FIFO with CFRunLoopPerformBlock work on the same runloop. The token
 * does not name a timer: the EventLoop drain consumes the earliest due item
 * across this list and its own ordered entries. Cancelled timers leave a
 * tombstone so their token consumes a slot as a no-op instead of lending its
 * position to a later item.
 */

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

struct TimerReference {
  int id;
  double dueTime;
  // clearTimeout/clearInterval tombstones the entry instead of erasing it:
  // its already-posted token then consumes this slot as a no-op, so no token
  // gains surplus capacity to run a LATER-scheduled item ahead of foreign
  // runloop work queued between the two token positions
  bool cancelled = false;
};

class TimerState : public OrderedTaskSource {
 public:
  std::atomic<int> currentTimerId = 0;
  robin_hood::unordered_map<int, std::shared_ptr<TimerTask>> timerMap_;
  // scheduled timers (and tombstones) sorted by exact (sub-millisecond)
  // dueTime, stable for equal dueTimes; touched only on the home thread
  std::vector<TimerReference> sortedTimers_;
  v8::Isolate* isolate_ = nullptr;
  std::shared_ptr<EventLoop> eventLoop_;
  bool stopped_ = false;

  ~TimerState() override {
    stopped_ = true;
    if (eventLoop_ != nullptr) {
      // the loop is already shut down by ~Runtime at this point (every
      // pending token dropped), but the source pointer must not outlive us
      eventLoop_->SetTimerSource(nullptr);
      eventLoop_.reset();
    }
    for (auto& entry : timerMap_) {
      entry.second->Unschedule();
    }
    timerMap_.clear();
    sortedTimers_.clear();
  }

  void insertSorted(int id, double dueTime) {
    auto it =
        std::upper_bound(sortedTimers_.begin(), sortedTimers_.end(), dueTime,
                         [](double due, const TimerReference& ref) {
                           return due < ref.dueTime;
                         });
    sortedTimers_.insert(it, TimerReference{id, dueTime});
  }

  void postToken(const std::shared_ptr<TimerTask>& task) {
    if (eventLoop_ == nullptr) {
      return;
    }
    // the loop clamps an overdue due time to its own `now`; remember the key
    // it actually recorded so cancellation can recall this exact token
    task->postedTokenTime_ = eventLoop_->PostOrderedToken(task->dueTime_);
  }

  void addTask(const std::shared_ptr<TimerTask>& task) {
    if (task->queued_) {
      return;
    }
    task->queued_ = true;
    timerMap_.emplace(task->id_, task);
    insertSorted(task->id_, task->dueTime_);
  }

  void removeTask(const int& taskId) {
    auto it = timerMap_.find(taskId);
    if (it == timerMap_.end()) {
      return;
    }
    if (it->second->queued_) {
      auto dueTime = it->second->dueTime_;
      auto sit =
          std::lower_bound(sortedTimers_.begin(), sortedTimers_.end(), dueTime,
                           [](const TimerReference& ref, double due) {
                             return ref.dueTime < due;
                           });
      while (sit != sortedTimers_.end() && sit->dueTime == dueTime) {
        if (sit->id == taskId) {
          // a future-due token is still in the loop's own bookkeeping and can
          // be recalled outright, un-arming its wakeup (the pre-event-loop
          // behavior of CFRunLoopTimerInvalidate). One already sent out as a
          // performed block cannot - its slot gets the tombstone instead.
          if (eventLoop_ != nullptr &&
              eventLoop_->TryCancelOrderedToken(it->second->postedTokenTime_)) {
            sortedTimers_.erase(sit);
          } else {
            sit->cancelled = true;
          }
          break;
        }
        ++sit;
      }
    }
    it->second->Unschedule();
    timerMap_.erase(it);
  }

  /**
   * Invoked by the EventLoop's ordered-lane token drain on the isolate's
   * thread: if the front slot is due and earlier-or-equal to the loop's own
   * earliest entry, consume it - firing the earliest due timer (exact
   * sub-millisecond order, not necessarily the timer that enqueued the token)
   * or swallowing a tombstone left by clearTimeout/clearInterval.
   */
  bool RunIfEarliest(double now, double otherDue) override {
    auto isolate = isolate_;
    if (stopped_ || isolate == nullptr || isolate->IsDead()) {
      return false;
    }
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handleScope(isolate);
    if (sortedTimers_.empty()) {
      return false;
    }
    auto ref = sortedTimers_.front();
    if (ref.dueTime > now_ms() || (otherDue >= 0 && ref.dueTime > otherDue)) {
      // not due, or the loop's own entry is earlier - not this source's slot
      return false;
    }
    sortedTimers_.erase(sortedTimers_.begin());
    if (ref.cancelled) {
      // tombstone: this slot's token is spent doing nothing, keeping tokens
      // and slots 1:1
      return true;
    }
    auto it = timerMap_.find(ref.id);
    if (it == timerMap_.end()) {
      return true;
    }
    auto task = it->second;
    if (!task->queued_ || !task->wrapper.IsValid()) {
      return true;
    }

    // reschedule before invoking, so a throwing callback can't kill the
    // interval - matching the repeating CFRunLoopTimer behavior this replaces
    if (task->repeats_) {
      task->dueTime_ = task->NextTime(now_ms());
      insertSorted(task->id_, task->dueTime_);
      postToken(task);
    }

    v8::Local<v8::Function> cb = task->callback_.Get(isolate);
    v8::Local<v8::Context> context =
        cb->GetCreationContextChecked(v8::Isolate::GetCurrent());
    Context::Scope context_scope(context);
    int argc = task->args_ ? static_cast<int>(task->args_->size()) : 0;
    if (argc > 0) {
      std::vector<Local<Value>> argv(argc);
      for (int i = 0; i < argc; ++i) {
        argv[i] = task->args_->at(i)->Get(isolate);
      }
      (void)cb->Call(context, context->Global(), argc, argv.data());
    } else {
      (void)cb->Call(context, context->Global(), 0, nullptr);
    }

    if (!task->repeats_) {
      // re-resolve: the callback may have cleared this id itself
      auto post = timerMap_.find(ref.id);
      if (post != timerMap_.end() && post->second == task) {
        post->second->Unschedule();
        timerMap_.erase(post);
      }
    }
    return true;
  }
};

void Timers::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  auto timerState = new TimerState();
  timerState->isolate_ = isolate;
  // Runtime::CreateIsolate bound the loop to this thread's runloop before
  // any builtin initialization runs; guard anyway so an embedding path with
  // no runtime degrades to inert timers instead of crashing
  Runtime* runtime = Runtime::GetRuntime(isolate);
  timerState->eventLoop_ =
      runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  if (timerState->eventLoop_ != nullptr) {
    timerState->eventLoop_->SetTimerSource(timerState);
  }
  Caches::Get(isolate)->registerCacheBoundObject(timerState);
  tns::SetMethod(isolate, globalTemplate, "__ns__setTimeout",
                 Timers::SetTimeoutCallback,
                 v8::External::New(isolate, timerState,
                                   v8::kExternalPointerTypeTagDefault));
  tns::SetMethod(isolate, globalTemplate, "__ns__setInterval",
                 Timers::SetIntervalCallback,
                 v8::External::New(isolate, timerState,
                                   v8::kExternalPointerTypeTagDefault));
  tns::SetMethod(isolate, globalTemplate, "__ns__clearTimeout",
                 Timers::ClearTimeoutCallback,
                 v8::External::New(isolate, timerState,
                                   v8::kExternalPointerTypeTagDefault));
  tns::SetMethod(isolate, globalTemplate, "__ns__clearInterval",
                 Timers::ClearTimeoutCallback,
                 v8::External::New(isolate, timerState,
                                   v8::kExternalPointerTypeTagDefault));
}

void Timers::SetTimer(const v8::FunctionCallbackInfo<v8::Value>& args,
                      bool repeatable) {
  auto argLength = args.Length();
  auto extData = args.Data().As<External>();
  TimerState* state = reinterpret_cast<TimerState*>(
      extData->Value(v8::kExternalPointerTypeTagDefault));
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

    auto now = now_ms();
    auto task = std::make_shared<TimerTask>(isolate, handler, timeout,
                                            repeatable, argArray, id, now);
#ifdef DEBUG
    task->callback_.AnnotateStrongRetainer("timer");
#endif
    task->repeats_ = repeatable;
    task->dueTime_ = now + (double)timeout;
    state->addTask(task);
    state->postToken(task);
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
  auto thiz = reinterpret_cast<TimerState*>(
      extData->Value(v8::kExternalPointerTypeTagDefault));
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
