#ifndef EventLoop_h
#define EventLoop_h

#include <CoreFoundation/CoreFoundation.h>

#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <vector>

#include "Common.h"
#include "v8-platform.h"

namespace tns {

/**
 * A producer of ordered-lane work that keeps its own bookkeeping (Timers).
 * The EventLoop's token drain consults it so timers and ordered entries form
 * ONE due-ordered domain: each anonymous token runs the earliest due item
 * across both. Home-thread only.
 */
class OrderedTaskSource {
 public:
  /**
   * If the source's earliest item is due at `now` and is earlier-or-equal to
   * `otherDue` (a negative otherDue means no competitor), consumes that slot -
   * running the item, or nothing if the slot is a tombstone (cancelled item) -
   * and returns true. Consumes exactly one slot per call so tokens and slots
   * stay 1:1. Check and run form a single call so the source can do both under
   * one acquisition of whatever guards its state (Timers' bookkeeping is
   * guarded by the isolate Locker).
   */
  virtual bool RunIfEarliest(double now, double otherDue) = 0;

  virtual ~OrderedTaskSource() = default;
};

/**
 * Per-runtime scheduler for work that must run on the runtime's home thread.
 * Two lanes, split by ordering contract (the iOS port of the Android
 * runtime's EventLoop; both descend from ExecuteOnRunLoop):
 *
 * Ordered lane - work whose ordering is observable against other app-level
 * runloop work (spec'd macrotasks, JS timers). Due-now posts ride
 * CFRunLoopPerformBlock as anonymous "task due" tokens, so they are strictly
 * FIFO with foreign performed blocks on the same runloop; future-due tokens
 * (delayed posts and Timers' tokens) arrive through one CFRunLoopTimer armed
 * at the earliest pending due time. Each token runs the earliest due item
 * across the ordered entries and the OrderedTaskSource (Timers) - one
 * due-ordered domain, and a leftover token is a cheap no-op.
 *
 * Internal lane - work in its own ordering domain: v8 platform foreground
 * tasks (Atomics.waitAsync wakeups, GC tasks, streaming-compilation
 * merge-backs), worker->parent messages and drains. Rides a version-0
 * CFRunLoopSource plus one CFRunLoopTimer for delayed work. The source's
 * perform callback runs exactly one due entry and re-signals itself while
 * more are due, so bursts interleave with other runloop work instead of
 * draining in one go.
 *
 * Posts are accepted from any thread. The loop starts unbound and buffers
 * (v8 requests its task runner during Isolate::New, before the home thread is
 * committed); BindToCurrentThread attaches both lanes and flushes. Posts
 * after Shutdown are dropped (Post* returns false), preserving the
 * "message to a terminated runtime" semantics of the mechanisms this
 * replaces. Producers only post; entries run exclusively on the home thread,
 * which is the only place the isolate's Locker is taken.
 */
class EventLoop : public std::enable_shared_from_this<EventLoop> {
 public:
  explicit EventLoop(v8::Isolate* isolate) : isolate_(isolate) {}

  ~EventLoop();

  /**
   * Attaches both lanes to the calling thread's CFRunLoop and flushes work
   * buffered before the bind. Must run on the runtime's home thread, before
   * its runloop starts dispatching.
   */
  void BindToCurrentThread();

  /**
   * Drops all queued work and detaches both lanes; posts after this are
   * dropped. Must run on the home thread (invalidating runloop sources
   * concurrently with a callback dispatch is racy), before the isolate is
   * disposed.
   */
  void Shutdown();

  // ordered lane: strictly FIFO with CFRunLoopPerformBlock work on the home
  // runloop. Returns false if the post was dropped (loop already shut down).
  bool PostOrdered(std::function<void()> fn);
  bool PostOrderedDelayed(std::function<void()> fn, double delayMs);

  /**
   * Posts a bare ordered token due at an absolute CLOCK_MONOTONIC time
   * (NowMs() units) for an item the OrderedTaskSource keeps in its own
   * bookkeeping (Timers). One token per item; the drain picks the earliest
   * due item across the source and the ordered entries, so the token needn't
   * name what it will run.
   */
  void PostOrderedToken(double dueTimeMs);

  /**
   * Removes one not-yet-matured ordered token at this due time, un-arming its
   * wakeup. Returns false when no such token is pending - it already went out
   * as a performed block (or matured), which cannot be recalled; the caller
   * must leave a tombstone for it instead. Tokens are anonymous and counted,
   * so cancelling one token plus one item keeps slots 1:1 no matter which
   * producer's token is physically removed.
   */
  bool TryCancelOrderedToken(double dueTimeMs);

  /**
   * Registers the ordered lane's external source. Home thread only; pass
   * nullptr to unregister (the source is being destroyed).
   */
  void SetTimerSource(OrderedTaskSource* source);

  // internal lane: runs on the home thread as soon as the runloop polls.
  // Returns false if the post was dropped (loop already shut down).
  bool PostInternal(std::function<void()> fn);
  bool PostInternalDelayed(std::function<void()> fn, double delayMs);

  /**
   * Internal-lane post whose fn does its OWN isolate ceremony: RunEntry skips
   * the loop's Locker/scopes/microtask checkpoint. Required when the fn locks
   * a different isolate than this loop's, or must run with no V8 scopes on
   * the stack at all (NativeScriptException's deferred @throw) - bare entries
   * also run outside the loop's exception guard so an NSException unwinds
   * into the runloop frame exactly like a CFRunLoopPerformBlock did.
   */
  bool PostInternalBare(std::function<void()> fn);

  /**
   * Posts a v8 foreground task into the internal lane. Called by the
   * platform's per-isolate v8::TaskRunner adapter, from any thread.
   */
  void PostV8Task(std::unique_ptr<v8::Task> task, bool nestable,
                  double delaySeconds);

  /**
   * True once Shutdown ran. A stopped loop found in the platform registry for
   * a (reused) isolate pointer is stale and must be replaced.
   */
  bool IsStopped();

  /**
   * Runs the internal-lane v8 tasks that are due and nestable, bounded to the
   * entries present at call time. For nested message loops (inspector pause)
   * where the runloop isn't polling: JS is on the stack, so non-nestable
   * tasks and plain function posts stay queued and run from their own wakeups
   * after the loop unwinds.
   */
  void RunNestableV8Tasks();

  /**
   * Runs at most one due ordered-lane item (an entry, a timer, or a
   * tombstone), then performs a microtask checkpoint for entries. Invoked
   * once per token, on the home thread.
   */
  void RunOrderedTask();

  // CLOCK_MONOTONIC milliseconds - the clock every due time and token is on
  static double NowMs();

 private:
  struct Entry {
    // exactly one of task/fn is set; fn entries are never drained by
    // RunNestableV8Tasks
    std::unique_ptr<v8::Task> task;
    std::function<void()> fn;
    bool nestable;
    // bare entries run without the loop's Locker/scopes/checkpoint/guard
    bool bare = false;
    // enqueue time for immediate entries, due time for delayed ones, so one
    // comparison orders both queues
    double time = 0;
  };
  struct Lane {
    std::deque<Entry> immediate;
    std::multimap<double, Entry> delayed;
  };

  // all *Locked members require mutex_ to be held
  void PostInternalLocked(Entry entry, double delayMs);
  void PostOrderedLocked(Entry entry, double delayMs);
  void PostOrderedTokenLocked(double dueTimeMs, double now);
  void PostTokenBlockLocked();
  static std::unique_ptr<Entry> TakeDueLocked(Lane& lane, bool nestableOnly,
                                              bool v8Only, double now);
  // earliest due entry time in the lane, or a negative value if none is due
  static double PeekDueLocked(Lane& lane, double now);
  static bool HasDueLocked(Lane& lane, double now);
  void SignalInternalLocked();
  void ArmInternalTimerLocked(double now);
  void ArmOrderedTimerLocked(double now);
  void RunEntry(Entry& entry);
  void RunOneInternal();

  static void InternalSourcePerform(void* info);
  static void InternalTimerFired(CFRunLoopTimerRef timer, void* info);
  static void OrderedTimerFired(CFRunLoopTimerRef timer, void* info);

  v8::Isolate* isolate_;
  std::mutex mutex_;
  Lane internal_;
  Lane ordered_;
  // ordered-lane source with its own bookkeeping (Timers); home-thread only
  OrderedTaskSource* timerSource_ = nullptr;
  // future-due ordered tokens awaiting orderedTimer_
  std::multiset<double> pendingTokens_;
  // tokens posted before the bind; flushed by BindToCurrentThread
  std::vector<double> bufferedTokens_;
  CFRunLoopRef loop_ = nullptr;
  CFRunLoopSourceRef internalSource_ = nullptr;
  CFRunLoopTimerRef internalTimer_ = nullptr;
  CFRunLoopTimerRef orderedTimer_ = nullptr;
  bool stopped_ = false;
};

}  // namespace tns

#endif /* EventLoop_h */
