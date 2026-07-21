#ifndef NativeScriptException_h
#define NativeScriptException_h

#include <atomic>
#include <string>
#include <vector>

#include "Common.h"

namespace tns {

class NativeScriptException {
 public:
  NativeScriptException(const std::string& message);
  NativeScriptException(v8::Isolate* isolate, v8::TryCatch& tc,
                        const std::string& message);
  NativeScriptException(v8::Isolate* isolate, const std::string& message,
                        const std::string& name = "NativeScriptException");
  ~NativeScriptException();
  void ReThrowToV8(v8::Isolate* isolate);
  const std::string& getMessage() const { return message_; }
  const std::string& getStackTrace() const { return stackTrace_; }
  static void OnUncaughtError(v8::Local<v8::Message> message,
                              v8::Local<v8::Value> error);
  // Isolate-level promise rejection callback (SetPromiseRejectCallback). Feeds
  // the per-isolate PromiseRejectionTracker owned by Caches.
  static void OnPromiseRejected(v8::PromiseRejectMessage message);
  // Shared reporting tail used by both the uncaught-error message listener and
  // the promise-rejection drain. `message` may be empty (rejections carry no
  // v8::Message); `stackOverride` short-circuits stack derivation when
  // non-empty; `logPrefix` distinguishes the log line (e.g. rejections) while
  // preserving the fatal-exception framing.
  static void ReportToJsHandlersAndLog(v8::Isolate* isolate,
                                       v8::Local<v8::Value> error,
                                       v8::Local<v8::Message> message,
                                       const std::string& stackOverride = "",
                                       const std::string& logPrefix = "");
  static std::string GetErrorStackTrace(
      v8::Isolate* isolate, const v8::Local<v8::StackTrace>& stackTrace);
  static void ShowErrorModal(v8::Isolate* isolate, const std::string& title,
                             const std::string& message,
                             const std::string& stackTrace);
  static void SubmitConsoleErrorPayload(v8::Isolate* isolate,
                                        const std::string& payload);

 private:
  v8::Persistent<v8::Value>* javascriptException_;
  std::string name_;
  std::string message_;
  std::string stackTrace_;
  std::string fullMessage_;
  static std::string GetErrorMessage(v8::Isolate* isolate,
                                     v8::Local<v8::Value>& error,
                                     const std::string& prependMessage = "");
  static std::string GetFullMessage(v8::Isolate* isolate,
                                    const v8::TryCatch& tc,
                                    const std::string& jsExceptionMessage);
  static std::string GetFullMessage(v8::Isolate* isolate,
                                    v8::Local<v8::Message> message,
                                    const std::string& jsExceptionMessage);
};

// A promise that was rejected without a handler at a microtask checkpoint.
// `reported` records that the rejection already reached the reporting tail;
// Phase 1 discards reported entries, but the flag is retained so Phase 2 can
// fire `rejectionhandled` for a handler added after reporting.
struct PendingRejection {
  v8::Global<v8::Promise> promise;
  v8::Global<v8::Value> reason;
  bool reported = false;
};

// Per-isolate tracker for unhandled promise rejections, owned by Caches.
// Accessed only from the isolate's own thread (the reject callback runs during
// the microtask checkpoint, the drain runs on the same runtime loop), so no
// locking is required.
class PromiseRejectionTracker {
 public:
  explicit PromiseRejectionTracker(v8::Isolate* isolate) : isolate_(isolate) {}

  void OnReject(v8::Local<v8::Promise> promise, v8::Local<v8::Value> reason);
  void OnHandlerAdded(v8::Local<v8::Promise> promise);
  void Drain(v8::Local<v8::Context> context);
  // Safe to call without holding the isolate lock: OnReject can run on any
  // thread that holds the v8::Locker (e.g. a background-thread rejection), so
  // the runloop observer polls this atomic instead of touching pending_.
  bool HasPending() const {
    return pendingCount_.load(std::memory_order_acquire) != 0;
  }

 private:
  void SyncPendingCount() {
    pendingCount_.store(pending_.size(), std::memory_order_release);
  }

  v8::Isolate* isolate_;
  std::vector<PendingRejection> pending_;
  std::atomic<size_t> pendingCount_{0};
  // Rejections that arrive while a drain is in progress are deferred to the
  // next turn: Drain snapshots and clears `pending_` before iterating, so any
  // OnReject during reporting accumulates into a fresh vector.
  bool draining_ = false;
};

}  // namespace tns

#endif /* NativeScriptException_h */
