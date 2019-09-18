#ifndef ConcurrentMap_h
#define ConcurrentMap_h

#include <shared_mutex>
#include <unordered_map>

namespace tns {

template<class TKey, class TValue>
class ConcurrentMap {
public:
    void Insert(TKey& key, TValue value) {
        std::lock_guard<std::mutex> writerLock(this->containerMutex_);
        this->container_[key] = value;
    }

    TValue Get(TKey& key) {
//      std::shared_lock<std::shared_timed_mutex> readerLock(this->containerMutex_);
      std::lock_guard<std::mutex> writerLock(this->containerMutex_);
      return this->container_[key];
    }

    bool ContainsKey(TKey& key) {
//        std::shared_lock<std::shared_timed_mutex> readerLock(this->containerMutex_);
        std::lock_guard<std::mutex> writerLock(this->containerMutex_);
        auto it = this->container_.find(key);
        return it != this->container_.end();
    }

    void Remove(TKey& key, TValue& removedElement) {
        std::lock_guard<std::mutex> writerLock(this->containerMutex_);
        auto it = this->container_.find(key);
        if (it != this->container_.end()) {
            removedElement = it->second;
            this->container_.erase(it);
        }
    }

    ConcurrentMap() = default;
    ConcurrentMap(const ConcurrentMap&) = delete;
    ConcurrentMap& operator=(const ConcurrentMap&) = delete;
private:
    std::mutex containerMutex_;
    std::unordered_map<TKey, TValue> container_;
};

}

#endif /* ConcurrentMap_h */
