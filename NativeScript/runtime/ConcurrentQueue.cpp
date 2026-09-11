#include "ConcurrentQueue.h"
#include "Helpers.h"

namespace tns {

void ConcurrentQueue::Initialize(CFRunLoopRef runLoop, void (*performWork)(void*), void* info) {
    std::unique_lock<std::mutex> lock(initializationMutex_);
    if (terminated) {
        return;
    }
    this->runLoop_ = runLoop;
    CFRunLoopSourceContext sourceContext = { 0, info, 0, 0, 0, 0, 0, 0, 0, performWork };
    this->runLoopTasksSource_ = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext);
    CFRunLoopAddSource(this->runLoop_, this->runLoopTasksSource_, kCFRunLoopCommonModes);
}

void ConcurrentQueue::Push(std::shared_ptr<worker::Message> message) {
    if (this->runLoopTasksSource_ != nullptr && !CFRunLoopSourceIsValid(this->runLoopTasksSource_)) {
        return;
    }

    {
      // Checked under the queue mutex, where Terminate() also flips it while
      // emptying the queue: a push that loses the race is dropped rather than
      // landing in a queue nothing will ever pop again.
      std::unique_lock<std::mutex> mlock(this->mutex_);
      if (this->terminated) {
        return;
      }
        this->messagesQueue_.push(message);
    }

    this->SignalAndWakeUp();
}

std::vector<std::shared_ptr<worker::Message>> ConcurrentQueue::PopAll() {
    std::unique_lock<std::mutex> mlock(this->mutex_);
    std::vector<std::shared_ptr<worker::Message>> messages;

    while (!this->messagesQueue_.empty()) {
        std::shared_ptr<worker::Message> message = this->messagesQueue_.front();
        this->messagesQueue_.pop();
        messages.push_back(message);
    }

    return messages;
}

bool ConcurrentQueue::IsEmpty() {
  std::unique_lock<std::mutex> mlock(this->mutex_);
  return this->messagesQueue_.empty();
}

void ConcurrentQueue::Signal() {
  // Mirrors Push()'s validity handling instead of SignalAndWakeUp()'s
  // assert: a retry racing Terminate() must be a silent no-op.
  if (this->runLoopTasksSource_ == nullptr ||
      !CFRunLoopSourceIsValid(this->runLoopTasksSource_)) {
    return;
  }
  this->SignalAndWakeUp();
}

void ConcurrentQueue::SignalAndWakeUp() {
    if (this->runLoopTasksSource_ != nullptr) {
        tns::Assert(CFRunLoopSourceIsValid(this->runLoopTasksSource_));
        CFRunLoopSourceSignal(this->runLoopTasksSource_);
    }

    if (this->runLoop_ != nullptr) {
        CFRunLoopWakeUp(this->runLoop_);
    }
}

void ConcurrentQueue::Terminate() {
  // Whatever is still queued is destroyed after both locks are released: a
  // message owns transferred buffers and ports, and destroying a port takes
  // its sibling group's lock and posts to the sibling's loop.
  std::queue<std::shared_ptr<worker::Message>> dropped;
  {
    std::unique_lock<std::mutex> lock(initializationMutex_);
    terminated = true;
    CFRunLoopRef runLoop = this->runLoop_;
    CFRunLoopSourceRef source = this->runLoopTasksSource_;
    this->runLoopTasksSource_ = nullptr;
    this->runLoop_ = nullptr;

    if (runLoop) {
      CFRunLoopStop(runLoop);
    }

    if (source) {
      CFRunLoopRemoveSource(runLoop, source, kCFRunLoopCommonModes);
      CFRunLoopSourceInvalidate(source);
      CFRelease(source);
    }
  }
  {
    std::unique_lock<std::mutex> mlock(this->mutex_);
    dropped.swap(this->messagesQueue_);
  }
}

}
