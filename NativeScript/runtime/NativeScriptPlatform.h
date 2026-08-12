#ifndef NativeScriptPlatform_h
#define NativeScriptPlatform_h

#include <memory>
#include <mutex>
#include <unordered_map>

#include "Common.h"
#include "EventLoop.h"
#include "v8-platform.h"

namespace tns {

/**
 * v8::Platform that delegates worker-thread scheduling, time and tracing to
 * the default libplatform implementation but serves per-isolate foreground
 * task runners backed by each runtime's EventLoop. This is what makes v8's
 * own foreground tasks (Atomics.waitAsync wakeups, GC finalization,
 * streaming-compilation merge-backs) actually run - nothing pumps the default
 * platform's internal queues outside the debugger pause loops.
 */
class NativeScriptPlatform : public v8::Platform {
 public:
  explicit NativeScriptPlatform(std::unique_ptr<v8::Platform> defaultPlatform);

  static NativeScriptPlatform* Instance() { return instance_; }

  /**
   * Returns the isolate's event loop, creating an unbound one if v8 asks
   * before Runtime::CreateIsolate binds it to the isolate's home thread.
   */
  std::shared_ptr<EventLoop> GetEventLoop(v8::Isolate* isolate);

  /**
   * GetEventLoop, but replaces a stopped loop with a fresh one first. Used by
   * Runtime::CreateIsolate: a stopped loop under this key is a leftover from
   * a disposed isolate that had the same address (worker churn reuses them).
   * The registry's v8 runner resolves the loop per post, so replacement also
   * redirects tasks posted through an already-handed-out runner.
   */
  std::shared_ptr<EventLoop> RefreshEventLoop(v8::Isolate* isolate);

  /**
   * The loop for the isolate, or null - never creates. The post path uses
   * this so a disposed isolate's late posts drop instead of minting a fresh
   * registry entry under a dead (or recycled) pointer.
   */
  std::shared_ptr<EventLoop> LookupEventLoop(v8::Isolate* isolate);

  /**
   * Drops the registry entry, but only while it still maps to `loop`: isolate
   * pointers are reused, and an unconditional erase from a late destructor
   * could evict the pointer's new tenant. ~Runtime calls this after handing
   * the isolate to DisposeIsolateWhenPossible.
   */
  void IsolateDisposed(v8::Isolate* isolate,
                       const std::shared_ptr<EventLoop>& loop);

  // v8::Platform
  v8::PageAllocator* GetPageAllocator() override;
  v8::ThreadIsolatedAllocator* GetThreadIsolatedAllocator() override;
  size_t GetZeroSegmentSize() override;
  void OnCriticalMemoryPressure() override;
  int NumberOfWorkerThreads() override;
  std::shared_ptr<v8::TaskRunner> GetForegroundTaskRunner(
      v8::Isolate* isolate, v8::TaskPriority priority) override;
  bool IdleTasksEnabled(v8::Isolate* isolate) override;
  std::unique_ptr<v8::ScopedBoostablePriority> CreateBoostablePriorityScope()
      override;
  std::unique_ptr<v8::ScopedBlockingCall> CreateBlockingScope(
      v8::BlockingType blocking_type) override;
  double MonotonicallyIncreasingTime() override;
  int64_t CurrentClockTimeMilliseconds() override;
  double CurrentClockTimeMillis() override;
  double CurrentClockTimeMillisecondsHighResolution() override;
  StackTracePrinter GetStackTracePrinter() override;
  v8::TracingController* GetTracingController() override;
  void DumpWithoutCrashing() override;
  v8::HighAllocationThroughputObserver* GetHighAllocationThroughputObserver()
      override;

 protected:
  std::unique_ptr<v8::JobHandle> CreateJobImpl(
      v8::TaskPriority priority, std::unique_ptr<v8::JobTask> job_task,
      const v8::SourceLocation& location) override;
  void PostTaskOnWorkerThreadImpl(v8::TaskPriority priority,
                                  std::unique_ptr<v8::Task> task,
                                  const v8::SourceLocation& location) override;
  void PostDelayedTaskOnWorkerThreadImpl(
      v8::TaskPriority priority, std::unique_ptr<v8::Task> task,
      double delay_in_seconds, const v8::SourceLocation& location) override;

 private:
  struct IsolateEntry {
    std::shared_ptr<EventLoop> loop;
    // handed to v8 once per isolate; resolves the loop through the registry
    // on every post so RefreshEventLoop redirects it
    std::shared_ptr<v8::TaskRunner> runner;
  };

  IsolateEntry& GetEntryLocked(v8::Isolate* isolate);

  std::unique_ptr<v8::Platform> default_;
  std::mutex loopsMutex_;
  std::unordered_map<v8::Isolate*, IsolateEntry> loops_;

  static NativeScriptPlatform* instance_;
};

}  // namespace tns

#endif /* NativeScriptPlatform_h */
