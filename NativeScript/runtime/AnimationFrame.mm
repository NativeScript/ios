//
//  AnimationFrame.mm
//  NativeScript
//

#include "AnimationFrame.hpp"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <memory>
#include <vector>

#include "Caches.h"
#include "Helpers.h"
#include "IsolateWrapper.h"
#include "ModuleBinding.hpp"
#include "Runtime.h"
#include "robin_hood.h"

/*
 * Frame callbacks ride one CADisplayLink per isolate, created paused during
 * isolate initialization on the isolate's home thread and attached to that
 * thread's runloop in the common modes (so ticks keep arriving during
 * scroll/tracking, matching the EventLoop's timers). Posting unpauses the
 * link; an empty registry pauses it again so an idle isolate never wakes per
 * frame. All access — post, remove, dispatch, teardown — happens on the home
 * thread, so the registry needs no locking.
 *
 * Two front-ends share the registry, matching the Android runtime's contract:
 * - requestAnimationFrame(fn) / cancelAnimationFrame(handle): the standard
 *   surface. Every request posts its own anonymous one-shot entry addressed
 *   only by the returned handle (no dedup by function), and fn receives a
 *   single DOMHighResTimeStamp on the isolate's performance timeline.
 *   cancelAnimationFrame may only touch entries carrying the raf flag.
 * - __postFrameCallback(fn[, delayMillis]) / __removeFrameCallback(fn): the
 *   compatibility surface predating requestAnimationFrame. One-shot, deduped
 *   by function identity (the entry id is stamped on the function as a
 *   private value): re-posting a pending callback is a no-op, delay included.
 *   fn(frameTimeNanos, performanceMillis) gets the raw frame time as well. A
 *   delayed entry fires on the first frame after its delay elapses.
 *
 * Each tick dispatches only the entries scheduled before it (the order list
 * is swapped out first), so a callback that re-posts runs again next frame,
 * never in the same batch. Every callback in a batch observes the same
 * timestamps. CADisplayLink.timestamp shares mach_absolute_time as its base
 * with the V8 platform clock (and CACurrentMediaTime), so it maps onto the
 * performance timeline via Runtime::TimeOriginMonotonicSeconds() — never
 * re-sample the clock at dispatch, the vsync instant is the contract.
 */

using namespace v8;

namespace tns {
class AnimationFrameState;
}

@interface TNSAnimationFrameTarget : NSObject {
 @public
  tns::AnimationFrameState* state_;
}
- (void)onFrame:(CADisplayLink*)link;
@end

namespace tns {

static constexpr const char* kFrameCallbackIdKey = "_postFrameCallbackId";

struct FrameEntry {
  v8::Persistent<v8::Function> callback;
  // scheduled == false only while the entry's callback is being invoked; a
  // re-post inside the callback flips it back and the entry survives the
  // post-call retirement check
  bool scheduled = false;
  bool raf = false;
  // earliest frame timestamp (CADisplayLink.timestamp base) this entry may
  // fire at; 0 means the next frame
  double notBeforeSeconds = 0;
};

class AnimationFrameState {
 public:
  explicit AnimationFrameState(v8::Isolate* isolate) : isolate_(isolate), wrapper_(isolate) {
    @autoreleasepool {
      target_ = [[TNSAnimationFrameTarget alloc] init];
      target_->state_ = this;
      displayLink_ = [[CADisplayLink displayLinkWithTarget:target_
                                                  selector:@selector(onFrame:)] retain];
      displayLink_.paused = YES;
      [displayLink_ addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
  }

  ~AnimationFrameState() {
    if (displayLink_ != nil) {
      [displayLink_ invalidate];
      [displayLink_ release];
      displayLink_ = nil;
    }
    if (target_ != nil) {
      target_->state_ = nullptr;
      [target_ release];
      target_ = nil;
    }
    // Caches teardown runs before Isolate::Dispose, which is what makes
    // resetting the persistents here legal; guard anyway like TimerTask does
    if (wrapper_.IsValid()) {
      for (auto& entry : entries_) {
        entry.second->callback.Reset();
      }
    }
    entries_.clear();
    order_.clear();
  }

  void Post(Isolate* isolate, const Local<v8::Function>& func, double delayMillis) {
    double notBefore = delayMillis > 0 ? CACurrentMediaTime() + delayMillis / 1000.0 : 0;
    Local<Value> existingId =
        tns::GetPrivateValue(func, tns::ToV8String(isolate, kFrameCallbackIdKey));
    if (!existingId.IsEmpty() && existingId->IsNumber()) {
      // ids are never reused, so a hit is always this function's own entry;
      // a miss means the entry already fired or was removed
      auto it = entries_.find((uint64_t)existingId.As<Number>()->Value());
      if (it != entries_.end()) {
        // an already-pending entry keeps its slot and its delay
        if (!it->second->scheduled) {
          it->second->scheduled = true;
          it->second->notBeforeSeconds = notBefore;
          order_.push_back(it->first);
        }
        EnsureRunning();
        return;
      }
    }
    uint64_t id = ++nextId_;
    auto entry = std::make_unique<FrameEntry>();
    entry->callback.Reset(isolate, func);
#ifdef DEBUG
    entry->callback.AnnotateStrongRetainer("frame_callback");
#endif
    entry->scheduled = true;
    entry->notBeforeSeconds = notBefore;
    entries_.emplace(id, std::move(entry));
    order_.push_back(id);
    tns::SetPrivateValue(func, tns::ToV8String(isolate, kFrameCallbackIdKey),
                         v8::Number::New(isolate, (double)id));
    EnsureRunning();
  }

  void Remove(Isolate* isolate, const Local<v8::Function>& func) {
    Local<Value> existingId =
        tns::GetPrivateValue(func, tns::ToV8String(isolate, kFrameCallbackIdKey));
    if (existingId.IsEmpty() || !existingId->IsNumber()) {
      return;
    }
    Erase((uint64_t)existingId.As<Number>()->Value());
  }

  uint64_t Request(Isolate* isolate, const Local<v8::Function>& func) {
    uint64_t id = ++nextId_;
    auto entry = std::make_unique<FrameEntry>();
    entry->callback.Reset(isolate, func);
#ifdef DEBUG
    entry->callback.AnnotateStrongRetainer("animation_frame");
#endif
    entry->scheduled = true;
    entry->raf = true;
    entries_.emplace(id, std::move(entry));
    order_.push_back(id);
    EnsureRunning();
    return id;
  }

  void Cancel(uint64_t id) {
    auto it = entries_.find(id);
    // handles only name requestAnimationFrame entries; a __postFrameCallback
    // entry that happens to share the counter must stay untouchable from here
    if (it == entries_.end() || !it->second->raf) {
      return;
    }
    it->second->callback.Reset();
    entries_.erase(it);
    PauseIfIdle();
  }

  void Erase(uint64_t id) {
    auto it = entries_.find(id);
    if (it == entries_.end()) {
      return;
    }
    // the id may still sit in a pending batch; dispatch tolerates the miss
    it->second->callback.Reset();
    entries_.erase(it);
    PauseIfIdle();
  }

  void FireFrame(double timestampSeconds) {
    Isolate* isolate = isolate_;
    if (isolate == nullptr || !wrapper_.IsValid() || isolate->IsDead()) {
      return;
    }
    Runtime* runtime = Runtime::GetRuntime(isolate);
    if (runtime == nullptr) {
      return;
    }
    double frameTimeNanos = timestampSeconds * 1e9;
    double performanceMillis = (timestampSeconds - runtime->TimeOriginMonotonicSeconds()) * 1000.0;

    v8::Locker locker(isolate);
    v8::Isolate::Scope isolateScope(isolate);
    v8::HandleScope handleScope(isolate);

    std::vector<uint64_t> batch = std::move(order_);
    order_.clear();
    for (uint64_t id : batch) {
      auto it = entries_.find(id);
      if (it == entries_.end() || !it->second->scheduled) {
        continue;
      }
      FrameEntry* entry = it->second.get();
      if (entry->notBeforeSeconds > timestampSeconds) {
        // delay not yet elapsed: stays scheduled, moves to the next batch
        order_.push_back(id);
        continue;
      }
      entry->scheduled = false;
      Local<v8::Function> cb = entry->callback.Get(isolate);
      Local<Context> context = cb->GetCreationContextChecked(v8::Isolate::GetCurrent());
      Context::Scope contextScope(context);
      if (entry->raf) {
        Local<Value> argv[] = {v8::Number::New(isolate, performanceMillis)};
        (void)cb->Call(context, context->Global(), 1, argv);
      } else {
        Local<Value> argv[] = {v8::Number::New(isolate, frameTimeNanos),
                               v8::Number::New(isolate, performanceMillis)};
        (void)cb->Call(context, context->Global(), 2, argv);
      }
      // re-resolve: the callback may have removed entries (this one included)
      // or re-posted itself
      auto post = entries_.find(id);
      if (post != entries_.end() && !post->second->scheduled) {
        post->second->callback.Reset();
        entries_.erase(post);
      }
    }
    PauseIfIdle();
  }

 private:
  void EnsureRunning() {
    if (displayLink_ != nil && displayLink_.paused) {
      displayLink_.paused = NO;
    }
  }

  void PauseIfIdle() {
    if (displayLink_ != nil && entries_.empty()) {
      displayLink_.paused = YES;
    }
  }

  v8::Isolate* isolate_;
  IsolateWrapper wrapper_;
  uint64_t nextId_ = 0;
  robin_hood::unordered_map<uint64_t, std::unique_ptr<FrameEntry>> entries_;
  // entry ids in post order; the upcoming tick's batch. An id appears at most
  // once: it is pushed only on the not-scheduled -> scheduled transition (or
  // carried over while its delay runs down)
  std::vector<uint64_t> order_;
  CADisplayLink* displayLink_ = nil;
  TNSAnimationFrameTarget* target_ = nil;
};

static AnimationFrameState* StateFromInfo(const FunctionCallbackInfo<Value>& info) {
  auto extData = info.Data().As<External>();
  return reinterpret_cast<AnimationFrameState*>(extData->Value(v8::kExternalPointerTypeTagDefault));
}

static bool GetFunctionArg(const FunctionCallbackInfo<Value>& info, const char* message,
                           Local<v8::Function>& func) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1 || !info[0]->IsFunction()) {
    isolate->ThrowException(Exception::TypeError(tns::ToV8String(isolate, message)));
    return false;
  }
  func = info[0].As<v8::Function>();
  return true;
}

void AnimationFrame::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  auto state = new AnimationFrameState(isolate);
  Caches::Get(isolate)->registerCacheBoundObject(state);
  Local<v8::External> data = v8::External::New(isolate, state, v8::kExternalPointerTypeTagDefault);
  tns::SetMethod(isolate, globalTemplate, "requestAnimationFrame",
                 AnimationFrame::RequestAnimationFrame, data);
  tns::SetMethod(isolate, globalTemplate, "cancelAnimationFrame",
                 AnimationFrame::CancelAnimationFrame, data);
  tns::SetMethod(isolate, globalTemplate, "__postFrameCallback", AnimationFrame::PostFrameCallback,
                 data);
  tns::SetMethod(isolate, globalTemplate, "__removeFrameCallback",
                 AnimationFrame::RemoveFrameCallback, data);
}

void AnimationFrame::RequestAnimationFrame(const FunctionCallbackInfo<Value>& info) {
  Local<v8::Function> func;
  if (!GetFunctionArg(info, "Animation frame callback argument is not a function", func)) {
    return;
  }
  uint64_t id = StateFromInfo(info)->Request(info.GetIsolate(), func);
  info.GetReturnValue().Set((double)id);
}

void AnimationFrame::CancelAnimationFrame(const FunctionCallbackInfo<Value>& info) {
  // per spec an unknown or malformed handle is a silent no-op
  if (info.Length() < 1 || !info[0]->IsNumber()) {
    return;
  }
  double id = info[0].As<Number>()->Value();
  if (id <= 0 || !std::isfinite(id)) {
    return;
  }
  StateFromInfo(info)->Cancel((uint64_t)id);
}

void AnimationFrame::PostFrameCallback(const FunctionCallbackInfo<Value>& info) {
  Local<v8::Function> func;
  if (!GetFunctionArg(info, "Frame callback argument is not a function", func)) {
    return;
  }
  double delayMillis = 0;
  if (info.Length() >= 2 && info[1]->IsNumber()) {
    delayMillis = info[1].As<Number>()->Value();
    if (!std::isfinite(delayMillis)) {
      delayMillis = 0;
    }
  }
  StateFromInfo(info)->Post(info.GetIsolate(), func, delayMillis);
}

void AnimationFrame::RemoveFrameCallback(const FunctionCallbackInfo<Value>& info) {
  Local<v8::Function> func;
  if (!GetFunctionArg(info, "Frame callback argument is not a function", func)) {
    return;
  }
  StateFromInfo(info)->Remove(info.GetIsolate(), func);
}

}  // namespace tns

@implementation TNSAnimationFrameTarget

- (void)onFrame:(CADisplayLink*)link {
  if (state_ != nullptr) {
    state_->FireFrame(link.timestamp);
  }
}

@end

NODE_BINDING_PER_ISOLATE_INIT_OBJ(animationframe, tns::AnimationFrame::Init)
