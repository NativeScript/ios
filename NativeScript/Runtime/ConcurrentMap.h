#ifndef ConcurrentMap_h
#define ConcurrentMap_h

#include <shared_mutex>
#include <map>

namespace tns {

template<class TKey, class TValue>
class ConcurrentMap {
public:
    void Insert(TKey& key, TValue value) {
        std::lock_guard<std::shared_timed_mutex> writerLock(this->containerMutex_);
        this->container_[key] = value;
    }

    TValue Get(TKey& key) {
        std::shared_lock<std::shared_timed_mutex> readerLock(this->containerMutex_);
        return this->container_[key];
    }

    bool ContainsKey(TKey& key) {
        std::shared_lock<std::shared_timed_mutex> readerLock(this->containerMutex_);
        auto it = this->container_.find(key);
        return it != this->container_.end();
    }

    void Remove(TKey& key) {
        std::lock_guard<std::shared_timed_mutex> writerLock(this->containerMutex_);
        this->container_.erase(key);
    }

    ConcurrentMap() = default;
    ConcurrentMap(const ConcurrentMap&) = delete;
    ConcurrentMap& operator=(const ConcurrentMap&) = delete;
private:
    std::shared_timed_mutex containerMutex_;
    std::map<TKey, TValue> container_;
};

}

#endif /* ConcurrentMap_h */
