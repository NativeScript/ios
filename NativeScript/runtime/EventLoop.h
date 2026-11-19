#ifndef EventLoop_h
#define EventLoop_h

#include <CoreFoundation/CoreFoundation.h>

#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
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
 * runloop work (spec'd macrotasks, JS timers). Every post is an anonymous
 * "task due" token with its own CFRunLoopTimer at the token's due time,
 * never re-armed once that time has passed: CF clamps a past fire date to
 * now, so such a timer would fall behind every overdue foreign NSTimer.
 * Tokens therefore keep fire-date order with foreign timers even when
 * several are overdue at once. Ordered tasks never nest: a token that fires
 * in a runloop spun from inside one waits for it to return (losing its
 * fire-date position only then). A due-now token still waits for the
 * timer phase rather than riding a performed block: a self-rescheduling
 * chain of blocks starves the before-waiting phase (CA rendering, autorelease
 * pool, the rejection drain), while a timer created during a timer pass only
 * fires on the next one. Each token runs the earliest due item across the
 * ordered entries and the OrderedTaskSource (Timers) - one due-ordered
 * domain, and a leftover token is a cheap no-op.
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
 *
 * No entry is ever destroyed while mutex_ is held: an entry's destructor may
 * post (a dropped message carrying a transferred port sentinels the port's
 * sibling, possibly on this loop), so Shutdown moves the lanes out and lets
 * them die after the unlock.
 */
class EventLoop {
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

  // ordered lane: one due-ordered domain with JS timers, in fire-date order
  // with foreign runloop timers. Returns false if the post was dropped (loop
  // already shut down).
  bool PostOrdered(std::function<void()> fn);
  bool PostOrderedDelayed(std::function<void()> fn, double delayMs);

  /**
   * Posts a bare ordered token due at an absolute NowMs() time
   * (CLOCK_UPTIME_RAW milliseconds) for an item the OrderedTaskSource keeps in its own
   * bookkeeping (Timers). One token per item; the drain picks the earliest
   * due item across the source and the ordered entries, so the token needn't
   * name what it will run. Returns the key actually recorded (an overdue due
   * time is clamped to now) - the value TryCancelOrderedToken must be given
   * to recall this token.
   */
  double PostOrderedToken(double dueTimeMs);

  /**
   * Removes one not-yet-matured ordered token at this due time, invalidating
   * its timer. Returns false when no such token is pending - it already
   * matured, so its slot cannot be recalled; the caller must leave a
   * tombstone for it instead. Tokens are anonymous and counted, so
   * cancelling one token plus one item keeps slots 1:1 no matter which
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

  // CLOCK_UPTIME_RAW milliseconds - the clock every due time and token is on;
  // it pauses during system sleep, like the CFRunLoopTimers tokens ride
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
  double PostOrderedTokenLocked(double dueTimeMs, double now);
  static std::unique_ptr<Entry> TakeDueLocked(Lane& lane, bool nestableOnly,
                                              bool v8Only, double now);
  // earliest due entry time in the lane, or a negative value if none is due
  static double PeekDueLocked(Lane& lane, double now);
  static bool HasDueLocked(Lane& lane, double now);
  void SignalInternalLocked();
  void ArmInternalTimerLocked(double now);
  void AddOrderedTokenLocked(double key, double now);
  void RunEntry(Entry& entry);
  void RunOneInternal();

  static void InternalSourcePerform(void* info);
  static void InternalTimerFired(CFRunLoopTimerRef timer, void* info);
  static void OrderedTokenFired(CFRunLoopTimerRef timer, void* info);

  v8::Isolate* isolate_;
  std::mutex mutex_;
  Lane internal_;
  Lane ordered_;
  // ordered-lane source with its own bookkeeping (Timers); home-thread only
  OrderedTaskSource* timerSource_ = nullptr;
  // pending ordered tokens by key, each owning its CFRunLoopTimer (+1)
  std::multimap<double, CFRunLoopTimerRef> pendingTokens_;
  // set while an ordered task runs; tokens that fire meanwhile (from a
  // runloop the task spins) are parked, still in pendingTokens_, and
  // re-armed when it returns
  bool runningOrderedTask_ = false;
  std::vector<std::pair<double, CFRunLoopTimerRef>> parkedTokens_;
  // tokens posted before the bind; flushed by BindToCurrentThread
  std::vector<double> bufferedTokens_;
  CFRunLoopRef loop_ = nullptr;
  CFRunLoopSourceRef internalSource_ = nullptr;
  CFRunLoopTimerRef internalTimer_ = nullptr;
  bool stopped_ = false;
};

}  // namespace tns

#endif /* EventLoop_h */
