#ifndef ConcurrentQueue_h
#define ConcurrentQueue_h

#include <condition_variable>
#include <queue>
#include <mutex>

namespace tns {

class ConcurrentQueue {
public:
    std::string Pop();

    void Push(const std::string& item);

    void Notify();

    ConcurrentQueue() = default;
    ConcurrentQueue(const ConcurrentQueue&) = delete;
    ConcurrentQueue& operator=(const ConcurrentQueue&) = delete;
private:
    bool isTerminating_ = false;
    std::queue<std::string> queue_;
    std::mutex mutex_;
    std::condition_variable conditionVar_;
};

}

#endif /* ConcurrentQueue_h */
