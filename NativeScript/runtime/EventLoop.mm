#include "EventLoop.h"

#include <algorithm>
#include <atomic>
#include <ctime>
#include <limits>

#include "Caches.h"
#include "Helpers.h"
#include "NativeScriptException.h"

using namespace v8;

namespace {

// far enough that an "unarmed" repeating timer never fires; re-armed with
// CFRunLoopTimerSetNextFireDate when a real deadline exists
const CFTimeInterval kNeverFireInterval = 1.0e10;

// runs one unit of non-bare work without letting a C++ exception escape into
// a CFRunLoop callback frame. Deliberately no catch(...): on Darwin it would
// also swallow NSExceptions, and bare entries (which may @throw on purpose)
// never come through here anyway.
template <typename F>
void RunGuarded(F&& body) {
  try {
    body();
  } catch (tns::NativeScriptException& ex) {
    Log(@"NativeScript: uncaught NativeScriptException in event loop task: %s",
        ex.getMessage().c_str());
  } catch (std::exception& ex) {
    Log(@"NativeScript: c++ exception in event loop task: %s", ex.what());
  }
}

// Context of one ordered token's CFRunLoopTimer. Refcounted through the
// context's retain/release so CF holds a reference across each callout:
// CFRunLoopTimerInvalidate releases the context immediately, and a token may
// be cancelled from another thread while its callout is being dispatched.
struct OrderedTokenInfo {
  OrderedTokenInfo(tns::EventLoop* loop, double key) : loop(loop), key(key) {}
  tns::EventLoop* const loop;
  const double key;
  std::atomic<int> refs{0};
};

const void* RetainOrderedTokenInfo(const void* info) {
  auto token = const_cast<OrderedTokenInfo*>(static_cast<const OrderedTokenInfo*>(info));
  token->refs.fetch_add(1, std::memory_order_relaxed);
  return info;
}

void ReleaseOrderedTokenInfo(const void* info) {
  auto token = const_cast<OrderedTokenInfo*>(static_cast<const OrderedTokenInfo*>(info));
  if (token->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    delete token;
  }
}

void DisposeTimer(CFRunLoopTimerRef timer) {
  CFRunLoopTimerInvalidate(timer);
  CFRelease(timer);
}

}  // namespace

namespace tns {

double EventLoop::NowMs() {
  struct timespec res;
  clock_gettime(CLOCK_MONOTONIC, &res);
  return 1000.0 * res.tv_sec + (double)res.tv_nsec / 1e6;
}

// converts a CLOCK_MONOTONIC due time to a CFRunLoopTimer fire date. The two
// clocks can drift (CFAbsoluteTime is wall-based), so consumers must treat a
// fire as "check what is due now", never as proof a specific item is due.
static CFAbsoluteTime FireDateFor(double dueMs, double nowMs) {
  return CFAbsoluteTimeGetCurrent() + std::max(0.0, dueMs - nowMs) / 1000.0;
}

void EventLoop::BindToCurrentThread() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (loop_ != nullptr || stopped_) {
    return;
  }

  loop_ = CFRunLoopGetCurrent();

  CFRunLoopSourceContext sourceContext = {
      0,       this,    nullptr, nullptr, nullptr,
      nullptr, nullptr, nullptr, nullptr, &EventLoop::InternalSourcePerform};
  internalSource_ = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext);
  CFRunLoopAddSource(loop_, internalSource_, kCFRunLoopCommonModes);

  CFRunLoopTimerContext timerContext = {0, this, nullptr, nullptr, nullptr};
  internalTimer_ =
      CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kNeverFireInterval,
                           kNeverFireInterval, 0, 0, &EventLoop::InternalTimerFired, &timerContext);
  CFRunLoopAddTimer(loop_, internalTimer_, kCFRunLoopCommonModes);

  // flush work buffered before the home thread was known
  auto now = NowMs();
  if (HasDueLocked(internal_, now)) {
    SignalInternalLocked();
  }
  ArmInternalTimerLocked(now);
  // replay buffered tokens under their original keys - PostOrderedToken
  // already returned those to producers as the recall handle, so the flush
  // must not re-clamp them (a past key simply fires on the next pass)
  auto tokens = std::move(bufferedTokens_);
  bufferedTokens_.clear();
  for (double due : tokens) {
    AddOrderedTokenLocked(due, now);
  }
}

void EventLoop::Shutdown() {
  // The dropped entries are moved out and destroyed only after the lock is
  // released: an entry's destructor may post back into this very loop (a
  // dropped message carrying a transferred port sentinels the port's sibling,
  // and that sibling may live here), and mutex_ is not recursive.
  std::deque<Entry> droppedInternal;
  std::multimap<double, Entry> droppedInternalDelayed;
  std::deque<Entry> droppedOrdered;
  std::multimap<double, Entry> droppedOrderedDelayed;
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return;
  }
  stopped_ = true;
  droppedInternal.swap(internal_.immediate);
  droppedInternalDelayed.swap(internal_.delayed);
  droppedOrdered.swap(ordered_.immediate);
  droppedOrderedDelayed.swap(ordered_.delayed);
  for (auto& token : pendingTokens_) {
    DisposeTimer(token.second);
  }
  pendingTokens_.clear();
  parkedTokens_.clear();
  bufferedTokens_.clear();
  if (internalSource_ != nullptr) {
    CFRunLoopSourceInvalidate(internalSource_);
    CFRelease(internalSource_);
    internalSource_ = nullptr;
  }
  if (internalTimer_ != nullptr) {
    CFRunLoopTimerInvalidate(internalTimer_);
    CFRelease(internalTimer_);
    internalTimer_ = nullptr;
  }
  loop_ = nullptr;
}

EventLoop::~EventLoop() {
  // Normally a no-op: ~Runtime already shut the loop down on the home thread.
  // A transient shared_ptr taken on a foreign posting thread can be the last
  // reference only after that shutdown, when this is just member cleanup.
  Shutdown();
}

void EventLoop::PostInternalLocked(Entry entry, double delayMs) {
  auto now = NowMs();
  if (delayMs <= 0) {
    entry.time = now;
    internal_.immediate.push_back(std::move(entry));
    SignalInternalLocked();
  } else {
    auto due = now + delayMs;
    entry.time = due;
    internal_.delayed.emplace(due, std::move(entry));
    ArmInternalTimerLocked(now);
  }
}

void EventLoop::PostOrderedLocked(Entry entry, double delayMs) {
  auto now = NowMs();
  if (delayMs <= 0) {
    entry.time = now;
    ordered_.immediate.push_back(std::move(entry));
    PostOrderedTokenLocked(now, now);
  } else {
    auto due = now + delayMs;
    entry.time = due;
    ordered_.delayed.emplace(due, std::move(entry));
    PostOrderedTokenLocked(due, now);
  }
}

double EventLoop::PostOrderedTokenLocked(double dueTimeMs, double now) {
  if (loop_ == nullptr) {
    bufferedTokens_.push_back(dueTimeMs);
    return dueTimeMs;
  }
  // every token rides the timer phase, even due-now ones (a past fire date
  // fires on the next timer pass). Performed blocks would deliver sooner,
  // but a self-rescheduling chain of them never lets the loop reach its
  // before-waiting phase - starving CA rendering commits, the autorelease
  // pool and the rejection drain.
  double key = std::max(dueTimeMs, now);
  AddOrderedTokenLocked(key, now);
  CFRunLoopWakeUp(loop_);
  return key;
}

void EventLoop::AddOrderedTokenLocked(double key, double now) {
  CFRunLoopTimerContext context = {0, new OrderedTokenInfo(this, key), &RetainOrderedTokenInfo,
                                   &ReleaseOrderedTokenInfo, nullptr};
  // Not re-armed once it is due, except when parked by a nested runloop (see
  // OrderedTokenFired): CF clamps a past fire date to now, which would move
  // the token behind overdue foreign timers. Repeating with an unreachable
  // interval only so its own callout can re-arm it - CF invalidates a
  // one-shot timer after its callout.
  CFRunLoopTimerRef timer =
      CFRunLoopTimerCreate(kCFAllocatorDefault, FireDateFor(key, now), kNeverFireInterval, 0, 0,
                           &EventLoop::OrderedTokenFired, &context);
  CFRunLoopAddTimer(loop_, timer, kCFRunLoopCommonModes);
  pendingTokens_.emplace(key, timer);
}

bool EventLoop::PostInternal(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  PostInternalLocked(Entry{nullptr, std::move(fn), true, false, 0}, 0);
  return true;
}

bool EventLoop::PostInternalDelayed(std::function<void()> fn, double delayMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  PostInternalLocked(Entry{nullptr, std::move(fn), true, false, 0}, delayMs);
  return true;
}

bool EventLoop::PostInternalBare(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  PostInternalLocked(Entry{nullptr, std::move(fn), true, true, 0}, 0);
  return true;
}

bool EventLoop::PostOrdered(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  PostOrderedLocked(Entry{nullptr, std::move(fn), true, false, 0}, 0);
  return true;
}

bool EventLoop::PostOrderedDelayed(std::function<void()> fn, double delayMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  PostOrderedLocked(Entry{nullptr, std::move(fn), true, false, 0}, delayMs);
  return true;
}

double EventLoop::PostOrderedToken(double dueTimeMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return dueTimeMs;
  }
  return PostOrderedTokenLocked(dueTimeMs, NowMs());
}

bool EventLoop::TryCancelOrderedToken(double dueTimeMs) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return false;
  }
  auto bufferedIt = std::find(bufferedTokens_.begin(), bufferedTokens_.end(), dueTimeMs);
  if (bufferedIt != bufferedTokens_.end()) {
    bufferedTokens_.erase(bufferedIt);
    return true;
  }
  auto pendingIt = pendingTokens_.find(dueTimeMs);
  if (pendingIt == pendingTokens_.end()) {
    return false;
  }
  DisposeTimer(pendingIt->second);
  pendingTokens_.erase(pendingIt);
  return true;
}

void EventLoop::SetTimerSource(OrderedTaskSource* source) {
  // home thread only, like every consumer of timerSource_
  timerSource_ = source;
}

void EventLoop::PostV8Task(std::unique_ptr<Task> task, bool nestable, double delaySeconds) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_) {
    return;
  }
  PostInternalLocked(Entry{std::move(task), nullptr, nestable, false, 0}, delaySeconds * 1000.0);
}

bool EventLoop::IsStopped() {
  std::lock_guard<std::mutex> lock(mutex_);
  return stopped_;
}

std::unique_ptr<EventLoop::Entry> EventLoop::TakeDueLocked(Lane& lane, bool nestableOnly,
                                                           bool v8Only, double now) {
  auto matches = [&](const Entry& e) {
    return (!nestableOnly || e.nestable) && (!v8Only || e.task != nullptr);
  };
  auto imIt = lane.immediate.begin();
  while (imIt != lane.immediate.end() && !matches(*imIt)) {
    ++imIt;
  }
  auto delIt = lane.delayed.begin();
  while (delIt != lane.delayed.end() && !matches(delIt->second)) {
    ++delIt;
  }
  bool hasImmediate = imIt != lane.immediate.end();
  bool hasDelayed = delIt != lane.delayed.end() && delIt->first <= now;
  if (hasImmediate && (!hasDelayed || imIt->time <= delIt->first)) {
    auto entry = std::make_unique<Entry>(std::move(*imIt));
    lane.immediate.erase(imIt);
    return entry;
  }
  if (hasDelayed) {
    auto entry = std::make_unique<Entry>(std::move(delIt->second));
    lane.delayed.erase(delIt);
    return entry;
  }
  return nullptr;
}

double EventLoop::PeekDueLocked(Lane& lane, double now) {
  // immediate entries are enqueued with monotonically increasing times, so
  // the front is the earliest
  double due = lane.immediate.empty() ? -1 : lane.immediate.front().time;
  if (!lane.delayed.empty() && lane.delayed.begin()->first <= now &&
      (due < 0 || lane.delayed.begin()->first < due)) {
    due = lane.delayed.begin()->first;
  }
  return due;
}

bool EventLoop::HasDueLocked(Lane& lane, double now) {
  return !lane.immediate.empty() || (!lane.delayed.empty() && lane.delayed.begin()->first <= now);
}

void EventLoop::SignalInternalLocked() {
  if (internalSource_ != nullptr) {
    CFRunLoopSourceSignal(internalSource_);
    CFRunLoopWakeUp(loop_);
  }
}

void EventLoop::ArmInternalTimerLocked(double now) {
  if (internalTimer_ == nullptr) {
    return;
  }
  // earliest not-yet-due delayed entry; already-due ones are the signal's job
  double due = -1;
  for (auto& pair : internal_.delayed) {
    if (pair.first > now) {
      due = pair.first;
      break;
    }
  }
  CFRunLoopTimerSetNextFireDate(
      internalTimer_,
      due >= 0 ? FireDateFor(due, now) : CFAbsoluteTimeGetCurrent() + kNeverFireInterval);
}

void EventLoop::RunEntry(Entry& entry) {
  if (entry.bare) {
    // the fn does its own ceremony - it may lock a different isolate, or
    // deliberately @throw with no V8 scopes on the stack
    entry.fn();
    return;
  }
  v8::Locker locker(isolate_);
  v8::Isolate::Scope isolate_scope(isolate_);
  v8::HandleScope handle_scope(isolate_);
  auto run = [&]() {
    if (entry.task != nullptr) {
      entry.task->Run();
    } else {
      entry.fn();
    }
    // work may enqueue microtasks without entering JS (e.g. resolving the
    // Atomics.waitAsync promise), which never reaches kAuto's depth-0 drain
    isolate_->PerformMicrotaskCheckpoint();
  };
  auto cache = Caches::Get(isolate_);
  if (cache != nullptr && cache->IsValid() && cache->HasContext()) {
    Context::Scope context_scope(cache->GetContext());
    run();
  } else {
    // v8 can post tasks before Runtime::Init creates the context
    run();
  }
}

void EventLoop::RunOneInternal() {
  std::unique_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return;
    }
    auto now = NowMs();
    entry = TakeDueLocked(internal_, false, false, now);
    // re-signal BEFORE running: one entry per runloop pass keeps the lane
    // fair with other runloop work, and a bare entry may @throw and never
    // return control here
    if (entry != nullptr && HasDueLocked(internal_, now)) {
      SignalInternalLocked();
    }
  }
  if (entry == nullptr) {
    // leftover signal: the work it announced ran early from a nested drain
    return;
  }
  if (entry->bare) {
    RunEntry(*entry);
    return;
  }
  RunGuarded([&] { RunEntry(*entry); });
}

void EventLoop::RunNestableV8Tasks() {
  // bounded to the entries present at call time so a task that reposts can't
  // wedge the inspector pause loop that called us
  size_t budget;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    budget = internal_.immediate.size() + internal_.delayed.size();
  }
  while (budget-- > 0) {
    std::unique_ptr<Entry> entry;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        return;
      }
      entry = TakeDueLocked(internal_, true, true, NowMs());
    }
    if (entry == nullptr) {
      return;
    }
    // the pause loops call this from inside v8 inspector frames - a C++
    // exception must not unwind through them
    RunGuarded([&] { RunEntry(*entry); });
  }
}

void EventLoop::RunOrderedTask() {
  // one anonymous token = one due slot across the whole ordered domain: pick
  // the earliest due item among the ordered entries and the timer source,
  // whichever it is. Timers and entries only ever run on this thread, so the
  // peeked winner can't be taken by anyone else before we re-lock (a
  // concurrent post can only add later work).
  auto now = NowMs();
  double entryDue;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return;
    }
    entryDue = PeekDueLocked(ordered_, now);
  }
  if (timerSource_ != nullptr && timerSource_->RunIfEarliest(now, entryDue)) {
    return;
  }
  if (entryDue < 0) {
    // leftover token: nothing in the domain is due yet
    return;
  }
  std::unique_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return;
    }
    entry = TakeDueLocked(ordered_, false, false, NowMs());
  }
  if (entry != nullptr) {
    RunGuarded([&] { RunEntry(*entry); });
  }
}

void EventLoop::InternalSourcePerform(void* info) {
  static_cast<EventLoop*>(info)->RunOneInternal();
}

void EventLoop::InternalTimerFired(CFRunLoopTimerRef timer, void* info) {
  auto self = static_cast<EventLoop*>(info);
  std::lock_guard<std::mutex> lock(self->mutex_);
  if (self->stopped_) {
    return;
  }
  auto now = NowMs();
  if (HasDueLocked(self->internal_, now)) {
    self->SignalInternalLocked();
  }
  self->ArmInternalTimerLocked(now);
}

void EventLoop::OrderedTokenFired(CFRunLoopTimerRef timer, void* info) {
  auto token = static_cast<OrderedTokenInfo*>(info);
  auto self = token->loop;
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    if (self->stopped_) {
      return;
    }
    auto now = NowMs();
    if (token->key > now) {
      // fired ahead of its CLOCK_MONOTONIC due time; still in the future, so
      // CF honors the new date
      CFRunLoopTimerSetNextFireDate(timer, FireDateFor(token->key, now));
      return;
    }
    auto range = self->pendingTokens_.equal_range(token->key);
    auto it = std::find_if(range.first, range.second,
                           [timer](const auto& entry) { return entry.second == timer; });
    if (it == range.second) {
      // recalled by TryCancelOrderedToken while this fire was being dispatched
      return;
    }
    if (self->runningOrderedTask_) {
      // a runloop spun from inside an ordered task (a pumped require, app
      // code): ordered tasks never nest, so the token waits for that task
      CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + kNeverFireInterval);
      self->parkedTokens_.emplace_back(token->key, timer);
      return;
    }
    self->pendingTokens_.erase(it);
    DisposeTimer(timer);
    self->runningOrderedTask_ = true;
  }

  struct UnparkOnExit {
    EventLoop* self;
    ~UnparkOnExit() {
      std::lock_guard<std::mutex> lock(self->mutex_);
      self->runningOrderedTask_ = false;
      auto parked = std::move(self->parkedTokens_);
      self->parkedTokens_.clear();
      if (self->stopped_) {
        return;
      }
      auto now = NowMs();
      for (auto& [key, timer] : parked) {
        // only timers still owned by pendingTokens_; a parked token may have
        // been cancelled (and its timer freed) meanwhile
        auto range = self->pendingTokens_.equal_range(key);
        for (auto it = range.first; it != range.second; ++it) {
          if (it->second == timer) {
            CFRunLoopTimerSetNextFireDate(timer, FireDateFor(key, now));
            break;
          }
        }
      }
    }
  } unpark{self};
  self->RunOrderedTask();
}

}  // namespace tns
