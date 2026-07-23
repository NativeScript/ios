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
  // Carries a pre-built JS error object (e.g. one wrapping a native NSException
  // via `nativeException`) so ReThrowToV8 surfaces exactly that object to the
  // JS catch handler. `message` is used only for logging.
  NativeScriptException(v8::Isolate* isolate, v8::Local<v8::Value> jsError,
                        const std::string& message);
  ~NativeScriptException();
  void ReThrowToV8(v8::Isolate* isolate);
  const std::string& getMessage() const { return message_; }
  const std::string& getStackTrace() const { return stackTrace_; }
  static void OnUncaughtError(v8::Local<v8::Message> message,
                              v8::Local<v8::Value> error);
  // Isolate-level promise rejection callback (SetPromiseRejectCallback). Feeds
  // the per-isolate PromiseRejectionTracker owned by Caches.
  static void OnPromiseRejected(v8::PromiseRejectMessage message);
  // Entry point for reporting an uncaught sync exception (message listener) and
  // reportError. First dispatches an `error` ErrorEvent through the JS listener
  // store; if a listener calls preventDefault() the report is fully handled and
  // nothing else runs. Otherwise falls through to ReportFatalTail. `message`
  // may be empty (rejections/reportError carry no v8::Message); `stackOverride`
  // short-circuits stack derivation when non-empty; `logPrefix` distinguishes
  // the log line while preserving the fatal-exception framing.
  static void ReportToJsHandlersAndLog(v8::Isolate* isolate,
                                       v8::Local<v8::Value> error,
                                       v8::Local<v8::Message> message,
                                       const std::string& stackOverride = "",
                                       const std::string& logPrefix = "");
  // Reports an unhandled promise rejection: dispatches a PromiseRejectionEvent
  // (not an ErrorEvent) and, when unprevented, falls through to ReportFatalTail
  // with the "Unhandled promise rejection:" prefix. Used by
  // PromiseRejectionTracker::Drain on the main isolate.
  static void ReportUnhandledRejection(v8::Isolate* isolate,
                                       v8::Local<v8::Promise> promise,
                                       v8::Local<v8::Value> reason,
                                       const std::string& stackOverride = "");
  // The terminal tail shared by the uncaught-error path, the rejection path and
  // the JS `nativeReportFatal` handshake: calls the __on* shim and emits the
  // fatal-exception log. Does NOT dispatch any event (the caller has already
  // done so, or is reportError dispatching from JS), preventing recursion.
  static void ReportFatalTail(v8::Isolate* isolate, v8::Local<v8::Value> error,
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
  // The observer polls this atomic to decide whether a drain is needed. Both
  // the still-to-report rejections and the queued rejectionhandled events count
  // as work; reportedOutstanding_ does not (it only waits for a late handler).
  void SyncPendingCount() {
    pendingCount_.store(pending_.size() + pendingRejectionHandled_.size(),
                        std::memory_order_release);
  }
  // Drop weak handles the GC has already cleared.
  void PruneReportedOutstanding();

  // A rejection that was already reported (unhandledrejection fired, prevented
  // or not). The original reason is retained so a late rejectionhandled event
  // carries it per spec; it is released when the entry is pruned or fired.
  struct ReportedRejection {
    v8::Global<v8::Promise> promise;
    v8::Global<v8::Value> reason;
  };

  v8::Isolate* isolate_;
  std::vector<PendingRejection> pending_;
  // Reported rejections still outstanding. The promise handle is phantom-weak
  // (SetWeak) so a GC'd promise drops the whole entry (reason included); a
  // handler added later moves the entry into pendingRejectionHandled_.
  std::vector<ReportedRejection> reportedOutstanding_;
  // rejectionhandled events queued by OnHandlerAdded (which runs during a
  // microtask checkpoint) to fire as a task on the next drain, per spec. Held
  // strong so the promise survives until the event fires.
  std::vector<ReportedRejection> pendingRejectionHandled_;
  std::atomic<size_t> pendingCount_{0};
  // Rejections that arrive while a drain is in progress are deferred to the
  // next turn: Drain snapshots and clears `pending_` before iterating, so any
  // OnReject during reporting accumulates into a fresh vector.
  bool draining_ = false;
};

}  // namespace tns

#endif /* NativeScriptException_h */
