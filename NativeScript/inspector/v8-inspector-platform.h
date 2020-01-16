#ifndef v8_inspector_platform_h
#define v8_inspector_platform_h

using namespace std;
using namespace v8;
using namespace platform;

#include "include/v8-platform.h"
#include "src/base/platform/mutex.h"

#ifdef DEBUG
[[noreturn]]
void V8_Fatal(const char* file, int line, const char* format, ...) {
    printf("FATAL ERROR");
    throw;
}
#endif

namespace v8 {
namespace platform {

class DefaultForegroundTaskRunner;
class DefaultWorkerThreadsTaskRunner;

class V8_PLATFORM_EXPORT DefaultPlatform : public NON_EXPORTED_BASE(Platform) {
public:
    explicit DefaultPlatform(
                             IdleTaskSupport idle_task_support = IdleTaskSupport::kDisabled,
                             std::unique_ptr<v8::TracingController> tracing_controller = {});

    ~DefaultPlatform() override;

    void SetThreadPoolSize(int thread_pool_size);

    void EnsureBackgroundTaskRunnerInitialized();

    bool PumpMessageLoop(
                         v8::Isolate* isolate,
                         MessageLoopBehavior behavior = MessageLoopBehavior::kDoNotWait);

    void RunIdleTasks(v8::Isolate* isolate, double idle_time_in_seconds);

    void SetTracingController(
                              std::unique_ptr<v8::TracingController> tracing_controller);

    using TimeFunction = double (*)();

    void SetTimeFunctionForTesting(TimeFunction time_function);

    // v8::Platform implementation.
    int NumberOfWorkerThreads() override;
    std::shared_ptr<TaskRunner> GetForegroundTaskRunner(
                                                        v8::Isolate* isolate) override;
    void CallOnWorkerThread(std::unique_ptr<Task> task) override;
    void CallDelayedOnWorkerThread(std::unique_ptr<Task> task,
                                   double delay_in_seconds) override;
    bool IdleTasksEnabled(Isolate* isolate) override;
    double MonotonicallyIncreasingTime() override;
    double CurrentClockTimeMillis() override;
    v8::TracingController* GetTracingController() override;
    StackTracePrinter GetStackTracePrinter() override;
    v8::PageAllocator* GetPageAllocator() override;
private:
    static const int kMaxThreadPoolSize;

    base::Mutex lock_;
    int thread_pool_size_;
    IdleTaskSupport idle_task_support_;
    std::shared_ptr<DefaultWorkerThreadsTaskRunner> worker_threads_task_runner_;
    std::map<v8::Isolate*, std::shared_ptr<DefaultForegroundTaskRunner>> foreground_task_runner_map_;

    std::unique_ptr<TracingController> tracing_controller_;
    std::unique_ptr<PageAllocator> page_allocator_;

    TimeFunction time_function_for_testing_;
    DISALLOW_COPY_AND_ASSIGN(DefaultPlatform);
};

}  // namespace platform
}  // namespace v8

namespace v8_inspector {

class V8InspectorPlatform: public DefaultPlatform {
public:
    explicit V8InspectorPlatform(v8::platform::IdleTaskSupport idle_task_support = IdleTaskSupport::kDisabled, unique_ptr<TracingController> tracing_controller = {}) {
    }

    void CallDelayedOnWorkerThread(unique_ptr<Task> task, double delay_in_seconds) override {
        DefaultPlatform::CallDelayedOnWorkerThread(move(task), 0);
    }

    static std::unique_ptr<Platform> CreateDefaultPlatform() {
        return NewDefaultPlatform();
    }
private:
    static unique_ptr<Platform> NewDefaultPlatform() {
        unique_ptr<DefaultPlatform> platform(new V8InspectorPlatform());
        platform->SetThreadPoolSize(0);
        platform->EnsureBackgroundTaskRunnerInitialized();
        return move(platform);
    }
};

}

#endif /* v8_inspector_platform_h */
