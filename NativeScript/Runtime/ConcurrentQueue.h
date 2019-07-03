#ifndef ConcurrentQueue_h
#define ConcurrentQueue_h

#include <condition_variable>
#include <queue>
#include <mutex>

namespace tns {

template <typename T>
class ConcurrentQueue {
public:
    T Pop() {
        std::unique_lock<std::mutex> mlock(this->mutex_);
        while (this->queue_.empty()) {
            this->conditionVar_.wait(mlock);
            if (this->isTerminating_) {
                return "";
            }
        }
        auto val = this->queue_.front();
        this->queue_.pop();
        return val;
    }

    void Push(const T& item) {
        std::unique_lock<std::mutex> mlock(this->mutex_);
        this->queue_.push(item);
        mlock.unlock();
        this->conditionVar_.notify_one();
    }

    void Notify() {
        this->isTerminating_ = true;
        this->conditionVar_.notify_one();
    }

    ConcurrentQueue() = default;
    ConcurrentQueue(const ConcurrentQueue&) = delete;
    ConcurrentQueue& operator=(const ConcurrentQueue&) = delete;
private:
    bool isTerminating_ = false;
    std::queue<T> queue_;
    std::mutex mutex_;
    std::condition_variable conditionVar_;
};

}

#endif /* ConcurrentQueue_h */
