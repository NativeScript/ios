#include "NativeScriptException.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#include <TargetConditionals.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <algorithm>
#include <limits>
#include <mutex>
#include <sstream>
#include "Caches.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace {
static UITextView* gErrorStackTextView = nil;
static NSString* gLatestStackText = nil;

struct PendingErrorDisplay {
  uint64_t ticket = 0;
  bool contextCaptured = false;
  bool modalPresented = false;
  bool fallbackScheduled = false;
  v8::Isolate* isolate = nullptr;
  std::string title;
  std::string message;
  std::string rawStack;
  std::string canonicalStack;
  std::string consolePayload;
};

static std::mutex gErrorDisplayMutex;
static PendingErrorDisplay gPendingErrorDisplay;
static uint64_t gNextErrorTicket = 1;

}  // namespace

namespace tns {

extern bool isErrorDisplayShowing;

static void UpdateDisplayedStackText(const std::string& stackText);
static void RenderErrorModalUI(v8::Isolate* isolate, const std::string& title,
                               const std::string& message, const std::string& stackText);
static void ShowErrorModalSynchronously(const std::string& title, const std::string& message,
                                        const std::string& stackTrace);
static void ScheduleFallbackPresentation(uint64_t ticket);
static void PresentFallbackIfNeeded(uint64_t ticket);
static std::string ResolveDisplayStack(const PendingErrorDisplay& state);
static void ConsiderStackCandidate(PendingErrorDisplay& state, v8::Isolate* isolate,
                                   const std::string& candidateStack);

NativeScriptException::NativeScriptException(const std::string& message) {
  this->javascriptException_ = nullptr;
  this->message_ = message;
  this->name_ = "NativeScriptException";
}

NativeScriptException::NativeScriptException(Isolate* isolate, TryCatch& tc,
                                             const std::string& message) {
  Local<Value> error = tc.Exception();
  this->javascriptException_ = new Persistent<Value>(isolate, tc.Exception());
  this->message_ = GetErrorMessage(isolate, error, message);
  this->stackTrace_ = tns::GetSmartStackTrace(isolate, &tc, error);
  this->fullMessage_ = GetFullMessage(isolate, tc, this->message_);
  this->name_ = "NativeScriptException";
  tc.Reset();
}

NativeScriptException::NativeScriptException(Isolate* isolate, const std::string& message,
                                             const std::string& name) {
  this->name_ = name;
  Local<Value> error = Exception::Error(tns::ToV8String(isolate, message));
  auto context = Caches::Get(isolate)->GetContext();
  error.As<Object>()
      ->Set(context, ToV8String(isolate, "name"), ToV8String(isolate, this->name_))
      .FromMaybe(false);
  this->javascriptException_ = new Persistent<Value>(isolate, error);
  this->message_ = GetErrorMessage(isolate, error, message);
  this->stackTrace_ = GetErrorStackTrace(isolate, Exception::GetStackTrace(error));
  this->fullMessage_ =
      GetFullMessage(isolate, Exception::CreateMessage(isolate, error), this->message_);
}
NativeScriptException::~NativeScriptException() { delete this->javascriptException_; }

void NativeScriptException::OnUncaughtError(Local<v8::Message> message, Local<Value> error) {
  @try {
    Isolate* isolate = message->GetIsolate();
    ReportToJsHandlersAndLog(isolate, error, message);
  } @catch (NSException* exception) {
    Log(@"OnUncaughtError: Caught exception during error handling: %@", exception);
    @throw exception;
  }
}

// Native function handed to the bootstrap IIFE as `nativeReportFatal(error,
// stackString)`. It runs the terminal tail (shim + fatal log) WITHOUT
// re-dispatching an event: reportError and listener-thrown errors have already
// gone through JS dispatch, so dispatching again here would recurse.
static void NativeReportFatalCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> error = info.Length() > 0 ? info[0] : v8::Undefined(isolate).As<Value>();
  std::string stack = info.Length() > 1 ? tns::ToString(isolate, info[1]) : "";
  NativeScriptException::ReportFatalTail(isolate, error, Local<v8::Message>(), stack, "");
}

// Dispatches the cancelable `error` ErrorEvent through the JS listener store.
// Returns true when a listener called preventDefault(). A dispatch that itself
// throws is logged and treated as unprevented so an error is never lost.
static bool DispatchErrorEvent(Isolate* isolate, Local<Value> error,
                               const std::string& messageString, const std::string& stack) {
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->DispatchErrorEventFunc == nullptr) {
    return false;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> dispatch = cache->DispatchErrorEventFunc->Get(isolate);
  Local<Value> args[] = {error, tns::ToV8String(isolate, messageString),
                         tns::ToV8String(isolate, stack)};
  Local<Value> result;
  TryCatch tc(isolate);
  bool success = dispatch->Call(context, context->Global(), 3, args).ToLocal(&result);
  if (tc.HasCaught()) {
    tns::LogError(isolate, tc);
    return false;
  }
  return success && !result.IsEmpty() && result->BooleanValue(isolate);
}

void NativeScriptException::ReportToJsHandlersAndLog(Isolate* isolate, Local<Value> error,
                                                     Local<v8::Message> message,
                                                     const std::string& stackOverride,
                                                     const std::string& logPrefix) {
  // First: give `error` event listeners a chance. If one prevents the default,
  // the report is fully handled — no shim, no fatal log.
  std::string messageString;
  if (!message.IsEmpty()) {
    messageString = tns::ToString(isolate, message->Get());
  } else {
    messageString = tns::ToString(isolate, error);
  }
  std::string stackForEvent = stackOverride;
  if (stackForEvent.empty()) {
    stackForEvent = tns::GetSmartStackTrace(isolate, nullptr, error);
  }
  if (DispatchErrorEvent(isolate, error, messageString, stackForEvent)) {
    return;
  }

  ReportFatalTail(isolate, error, message, stackOverride, logPrefix);
}

bool NativeScriptException::DispatchUnhandledRejectionEvent(Isolate* isolate,
                                                            Local<Promise> promise,
                                                            Local<Value> reason) {
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->DispatchUnhandledRejectionFunc == nullptr) {
    return false;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> dispatch = cache->DispatchUnhandledRejectionFunc->Get(isolate);
  Local<Value> args[] = {promise, reason};
  Local<Value> result;
  TryCatch tc(isolate);
  bool success = dispatch->Call(context, context->Global(), 2, args).ToLocal(&result);
  if (tc.HasCaught()) {
    tns::LogError(isolate, tc);
    return false;
  }
  return success && !result.IsEmpty() && result->BooleanValue(isolate);
}

void NativeScriptException::DispatchRejectionHandledEvent(Isolate* isolate, Local<Promise> promise,
                                                          Local<Value> reason) {
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->DispatchRejectionHandledFunc == nullptr) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> dispatch = cache->DispatchRejectionHandledFunc->Get(isolate);
  Local<Value> args[] = {promise, reason};
  Local<Value> result;
  TryCatch tc(isolate);
  if (!dispatch->Call(context, context->Global(), 2, args).ToLocal(&result) && tc.HasCaught()) {
    tns::LogError(isolate, tc);
  }
}

void NativeScriptException::ReportUnhandledRejection(Isolate* isolate, Local<Promise> promise,
                                                     Local<Value> reason,
                                                     const std::string& stackOverride) {
  if (DispatchUnhandledRejectionEvent(isolate, promise, reason)) {
    return;
  }
  ReportFatalTail(isolate, reason, Local<v8::Message>(), stackOverride,
                  "Unhandled promise rejection:");
}

void NativeScriptException::ReportFatalTail(Isolate* isolate, Local<Value> error,
                                            Local<v8::Message> message,
                                            const std::string& stackOverride,
                                            const std::string& logPrefix) {
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> global = context->Global();
  Local<Value> handler;
  id value = Runtime::GetAppConfigValue("discardUncaughtJsExceptions");
  bool isDiscarded = value ? [value boolValue] : false;

  std::string cbName = isDiscarded ? "__onDiscardedError" : "__onUncaughtError";
  bool success = global->Get(context, tns::ToV8String(isolate, cbName)).ToLocal(&handler);

  std::string stackTrace = stackOverride;
  if (stackTrace.empty()) {
    stackTrace = tns::GetSmartStackTrace(isolate, nullptr, error);
  }
  if (stackTrace.empty()) {
    if (!message.IsEmpty()) {
      stackTrace = GetErrorStackTrace(isolate, message->GetStackTrace());
    } else {
      // Rejections carry no v8::Message; fall back to the reason's own stack.
      stackTrace = GetErrorStackTrace(isolate, Exception::GetStackTrace(error));
    }
  }

  // Derive the human-readable message string, either from the v8::Message (sync
  // exceptions) or from the reason value itself (rejections, no v8::Message).
  auto messageOrReasonString = [&]() -> std::string {
    if (!message.IsEmpty()) {
      Local<v8::String> messageV8String = message->Get();
      return tns::ToString(isolate, messageV8String);
    }
    return tns::ToString(isolate, error);
  };

  std::string fullMessage;
  if (error->IsObject()) {
    auto errObject = error.As<Object>();
    auto fullMessageString = tns::ToV8String(isolate, "fullMessage");
    if (errObject->HasOwnProperty(context, fullMessageString).ToChecked()) {
      // check if we have a "fullMessage" on the error, and log that instead - since it includes
      // more info about the exception.
      v8::Local<v8::Value> fullMessage_;
      if (errObject->Get(context, fullMessageString).ToLocal(&fullMessage_)) {
        fullMessage = tns::ToString(isolate, fullMessage_);
      } else {
        // Fallback to regular message if fullMessage access fails
        fullMessage = messageOrReasonString();
      }
    } else {
      fullMessage = messageOrReasonString() + "\n at \n" + stackTrace;
    }
  } else {
    fullMessage = messageOrReasonString() + "\n at \n" + stackTrace;
  }

  if (success && handler->IsFunction()) {
    if (error->IsObject()) {
      // Try to set stackTrace property, but don't crash if it fails
      bool stackTraceSet = error.As<Object>()
                               ->Set(context, tns::ToV8String(isolate, "stackTrace"),
                                     tns::ToV8String(isolate, stackTrace))
                               .FromMaybe(false);
      if (!stackTraceSet) {
        Log(@"Warning: Failed to set stackTrace property on error object");
      }
    }

    Local<v8::Function> errorHandlerFunc = handler.As<v8::Function>();
    Local<Object> thiz = Object::New(isolate);
    Local<Value> args[] = {error};
    Local<Value> result;
    TryCatch tc(isolate);
    success = errorHandlerFunc->Call(context, thiz, 1, args).ToLocal(&result);
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }

    // Don't crash if error handler call failed - just log it
    if (!success) {
      Log(@"Warning: Error handler function call failed");
    }
  }

  if (!isDiscarded) {
    Log(@"***** Fatal JavaScript exception *****\n");
    if (!logPrefix.empty()) {
      Log(@"%s", logPrefix.c_str());
    }
    Log(@"%s", fullMessage.c_str());
    if (!stackTrace.empty()) {
      Log(@"%s", stackTrace.c_str());
    }
  } else {
    if (!logPrefix.empty()) {
      Log(@"%s", logPrefix.c_str());
    }
    Log(@"NativeScript discarding uncaught JS exception!");
  }
}

void NativeScriptException::InitErrorEvents(Local<Context> context) {
  // WHATWG error-events layer. Plain (module-free) script, strict inside the
  // IIFE, ES5-ish so it never depends on other runtime extensions. The IIFE is
  // invoked with one argument — the native nativeReportFatal(error, stack)
  // function that runs the terminal tail — and returns three closures bound to
  // the internal listener store so native dispatch survives app code
  // overwriting globalThis.dispatchEvent.
  std::string source = R"(
    (function (nativeReportFatal) {
      "use strict";
      var g = globalThis;

      function Event(type, opts) {
        opts = opts || {};
        this.type = String(type);
        this.bubbles = !!opts.bubbles;
        this.cancelable = !!opts.cancelable;
        this.composed = !!opts.composed;
        this.defaultPrevented = false;
        this.target = null;
        this.currentTarget = null;
        this._stopPropagation = false;
        this._stopImmediate = false;
      }
      Event.prototype.preventDefault = function () {
        if (this.cancelable) { this.defaultPrevented = true; }
      };
      Event.prototype.stopPropagation = function () { this._stopPropagation = true; };
      Event.prototype.stopImmediatePropagation = function () {
        this._stopPropagation = true;
        this._stopImmediate = true;
      };

      function ErrorEvent(type, opts) {
        opts = opts || {};
        Event.call(this, type, opts);
        this.message = opts.message !== undefined ? String(opts.message) : "";
        this.filename = opts.filename !== undefined ? String(opts.filename) : "";
        this.lineno = opts.lineno !== undefined ? (opts.lineno | 0) : 0;
        this.colno = opts.colno !== undefined ? (opts.colno | 0) : 0;
        this.error = opts.error !== undefined ? opts.error : null;
      }
      ErrorEvent.prototype = Object.create(Event.prototype);
      ErrorEvent.prototype.constructor = ErrorEvent;

      function PromiseRejectionEvent(type, opts) {
        opts = opts || {};
        Event.call(this, type, opts);
        this.promise = opts.promise;
        this.reason = opts.reason;
      }
      PromiseRejectionEvent.prototype = Object.create(Event.prototype);
      PromiseRejectionEvent.prototype.constructor = PromiseRejectionEvent;

      // A listener that throws must not stop other listeners: route the thrown
      // value to the native fatal tail instead of ever recursively dispatching
      // another `error` event from inside dispatch.
      function reportListenerError(e) {
        try { nativeReportFatal(e, (e && e.stack) || ""); } catch (ignored) {}
      }

      function EventTargetImpl() { this._listeners = Object.create(null); }
      EventTargetImpl.prototype.addEventListener = function (type, callback, options) {
        if (callback === null || callback === undefined) { return; }
        type = String(type);
        var capture = false, once = false;
        if (typeof options === "boolean") {
          capture = options;
        } else if (options && typeof options === "object") {
          capture = !!options.capture;
          once = !!options.once;
        }
        var list = this._listeners[type];
        if (!list) { list = this._listeners[type] = []; }
        for (var i = 0; i < list.length; i++) {
          if (list[i].callback === callback && list[i].capture === capture) { return; }
        }
        list.push({ callback: callback, once: once, capture: capture });
      };
      EventTargetImpl.prototype.removeEventListener = function (type, callback, options) {
        type = String(type);
        var capture = false;
        if (typeof options === "boolean") {
          capture = options;
        } else if (options && typeof options === "object") {
          capture = !!options.capture;
        }
        var list = this._listeners[type];
        if (!list) { return; }
        for (var i = 0; i < list.length; i++) {
          if (list[i].callback === callback && list[i].capture === capture) {
            list.splice(i, 1);
            return;
          }
        }
      };
      EventTargetImpl.prototype.dispatchEvent = function (event) {
        event.target = this;
        event.currentTarget = this;
        var list = this._listeners[event.type];
        if (list) {
          // Snapshot so listeners added during dispatch are not invoked and
          // registration order is preserved.
          var snapshot = list.slice();
          for (var i = 0; i < snapshot.length; i++) {
            var entry = snapshot[i];
            var idx = list.indexOf(entry);
            if (idx === -1) { continue; }  // removed since snapshot
            if (entry.once) { list.splice(idx, 1); }
            var cb = entry.callback;
            try {
              if (typeof cb === "function") {
                cb.call(this, event);
              } else if (cb && typeof cb.handleEvent === "function") {
                cb.handleEvent(event);
              }
            } catch (e) {
              reportListenerError(e);
            }
            if (event._stopImmediate) { break; }
          }
        }
        event.currentTarget = null;
        return !event.defaultPrevented;
      };

      // Internal EventTarget instance backing the global. globalThis's prototype
      // is intentionally NOT made an EventTarget; only the three methods are
      // bound onto it.
      var globalTarget = new EventTargetImpl();
      g.addEventListener = function (type, callback, options) {
        return globalTarget.addEventListener(type, callback, options);
      };
      g.removeEventListener = function (type, callback, options) {
        return globalTarget.removeEventListener(type, callback, options);
      };
      g.dispatchEvent = function (event) {
        return globalTarget.dispatchEvent(event);
      };

      function EventTarget() { EventTargetImpl.call(this); }
      EventTarget.prototype.addEventListener = EventTargetImpl.prototype.addEventListener;
      EventTarget.prototype.removeEventListener = EventTargetImpl.prototype.removeEventListener;
      EventTarget.prototype.dispatchEvent = EventTargetImpl.prototype.dispatchEvent;

      g.reportError = function (e) {
        if (arguments.length === 0) {
          throw new TypeError("Failed to execute 'reportError': 1 argument required, but only 0 present.");
        }
        var ev = new ErrorEvent("error", {
          message: (e && e.message !== undefined && e.message !== null) ? String(e.message) : String(e),
          error: e,
          cancelable: true
        });
        if (globalTarget.dispatchEvent(ev)) {
          nativeReportFatal(e, (e && e.stack) || "");
        }
      };

      g.Event = Event;
      g.EventTarget = EventTarget;
      g.ErrorEvent = ErrorEvent;
      g.PromiseRejectionEvent = PromiseRejectionEvent;

      // Closures called by C++. They never look up globalThis.dispatchEvent, so
      // they keep working even if app code overwrites it.
      function dispatchErrorEvent(error, message, stack) {
        var ev = new ErrorEvent("error", {
          message: message !== undefined && message !== null ? String(message) : "",
          error: error,
          cancelable: true
        });
        globalTarget.dispatchEvent(ev);
        return ev.defaultPrevented;
      }
      function dispatchUnhandledRejection(promise, reason) {
        var ev = new PromiseRejectionEvent("unhandledrejection", {
          promise: promise,
          reason: reason,
          cancelable: true
        });
        globalTarget.dispatchEvent(ev);
        return ev.defaultPrevented;
      }
      function dispatchRejectionHandled(promise, reason) {
        var ev = new PromiseRejectionEvent("rejectionhandled", {
          promise: promise,
          reason: reason,
          cancelable: false
        });
        globalTarget.dispatchEvent(ev);
      }

      return [dispatchErrorEvent, dispatchUnhandledRejection, dispatchRejectionHandled];
    })
  )";

  Isolate* isolate = context->GetIsolate();

  Local<Script> script;
  bool success = Script::Compile(context, tns::ToV8String(isolate, source)).ToLocal(&script);
  tns::Assert(success && !script.IsEmpty(), isolate);

  Local<Value> result;
  success = script->Run(context).ToLocal(&result);
  tns::Assert(success && result->IsFunction(), isolate);

  Local<v8::Function> iife = result.As<v8::Function>();

  Local<v8::Function> nativeReportFatal;
  success = v8::Function::New(context, NativeReportFatalCallback).ToLocal(&nativeReportFatal);
  tns::Assert(success, isolate);

  Local<Value> installArgs[] = {nativeReportFatal};
  Local<Value> iifeResult;
  success = iife->Call(context, context->Global(), 1, installArgs).ToLocal(&iifeResult);
  tns::Assert(success && iifeResult->IsArray(), isolate);

  Local<v8::Array> closures = iifeResult.As<v8::Array>();
  Local<Value> errorFn, rejectionFn, handledFn;
  tns::Assert(closures->Get(context, 0).ToLocal(&errorFn) && errorFn->IsFunction(), isolate);
  tns::Assert(closures->Get(context, 1).ToLocal(&rejectionFn) && rejectionFn->IsFunction(),
              isolate);
  tns::Assert(closures->Get(context, 2).ToLocal(&handledFn) && handledFn->IsFunction(), isolate);

  auto cache = Caches::Get(isolate);
  cache->DispatchErrorEventFunc =
      std::make_unique<Persistent<v8::Function>>(isolate, errorFn.As<v8::Function>());
  cache->DispatchUnhandledRejectionFunc =
      std::make_unique<Persistent<v8::Function>>(isolate, rejectionFn.As<v8::Function>());
  cache->DispatchRejectionHandledFunc =
      std::make_unique<Persistent<v8::Function>>(isolate, handledFn.As<v8::Function>());
}

void NativeScriptException::OnPromiseRejected(v8::PromiseRejectMessage message) {
  Local<Promise> promise = message.GetPromise();
  Isolate* isolate = promise->GetIsolate();
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->PromiseRejections == nullptr) {
    return;
  }

  switch (message.GetEvent()) {
    case v8::kPromiseRejectWithNoHandler:
      cache->PromiseRejections->OnReject(promise, message.GetValue());
      break;
    case v8::kPromiseHandlerAddedAfterReject:
      cache->PromiseRejections->OnHandlerAdded(promise);
      break;
    case v8::kPromiseResolveAfterResolved:
    case v8::kPromiseRejectAfterResolved:
      // Not relevant to unhandled-rejection tracking.
      break;
  }
}

void PromiseRejectionTracker::OnReject(Local<Promise> promise, Local<Value> reason) {
  for (auto& entry : pending_) {
    if (entry.promise.Get(isolate_)->SameValue(promise)) {
      // Already tracked; refresh the reason for the latest rejection value.
      entry.reason.Reset(isolate_, reason);
      return;
    }
  }
  PendingRejection entry;
  entry.promise.Reset(isolate_, promise);
  entry.reason.Reset(isolate_, reason);
  entry.reported = false;
  pending_.push_back(std::move(entry));
  SyncPendingCount();
}

void PromiseRejectionTracker::PruneReportedOutstanding() {
  reportedOutstanding_.erase(
      std::remove_if(reportedOutstanding_.begin(), reportedOutstanding_.end(),
                     [](const v8::Global<v8::Promise>& g) { return g.IsEmpty(); }),
      reportedOutstanding_.end());
}

void PromiseRejectionTracker::OnHandlerAdded(Local<Promise> promise) {
  // A handler attached before the rejection was drained cancels the report.
  for (auto it = pending_.begin(); it != pending_.end(); ++it) {
    if (it->promise.Get(isolate_)->SameValue(promise)) {
      pending_.erase(it);
      SyncPendingCount();
      return;
    }
  }
  // Otherwise, if the rejection was already reported and the promise is still
  // outstanding, queue a `rejectionhandled` event. OnHandlerAdded runs during a
  // microtask checkpoint, but spec fires rejectionhandled as a task, so we defer
  // to the next drain turn instead of dispatching synchronously.
  for (auto it = reportedOutstanding_.begin(); it != reportedOutstanding_.end(); ++it) {
    if (it->IsEmpty()) {
      continue;
    }
    if (it->Get(isolate_)->SameValue(promise)) {
      reportedOutstanding_.erase(it);
      v8::Global<v8::Promise> queued;
      queued.Reset(isolate_, promise);
      pendingRejectionHandled_.push_back(std::move(queued));
      SyncPendingCount();
      PruneReportedOutstanding();
      return;
    }
  }
  PruneReportedOutstanding();
}

// Gives a worker's global `onerror` a chance to handle a rejected reason,
// mirroring WorkerWrapper::CallOnErrorHandlers. Returns true when the handler
// signalled it consumed the error (truthy return).
static bool GiveWorkerOnErrorAChance(Isolate* isolate, Local<Context> context,
                                     Local<Value> reason) {
  Local<Object> global = context->Global();
  Local<Value> onErrorVal;
  if (!global->Get(context, tns::ToV8String(isolate, "onerror")).ToLocal(&onErrorVal)) {
    return false;
  }
  if (onErrorVal.IsEmpty() || !onErrorVal->IsFunction()) {
    return false;
  }

  Local<v8::Function> onErrorFunc = onErrorVal.As<v8::Function>();
  Local<Value> args[1] = {reason};
  Local<Value> result;
  TryCatch tc(isolate);
  bool success = onErrorFunc->Call(context, v8::Undefined(isolate), 1, args).ToLocal(&result);
  return success && !result.IsEmpty() && result->BooleanValue(isolate);
}

void PromiseRejectionTracker::Drain(Local<Context> context) {
  if (draining_) {
    return;
  }
  draining_ = true;

  // Fire queued rejectionhandled events first (they were deferred from a
  // microtask checkpoint to run as a task on this drain turn). Reason is passed
  // as undefined: Phase 2 does not retain the reason past reporting.
  std::vector<v8::Global<v8::Promise>> handledSnapshot;
  handledSnapshot.swap(pendingRejectionHandled_);

  std::vector<PendingRejection> snapshot;
  snapshot.swap(pending_);
  SyncPendingCount();

  auto cache = Caches::Get(isolate_);
  bool isWorker = cache->isWorker;

  for (auto& queued : handledSnapshot) {
    if (queued.IsEmpty()) {
      continue;
    }
    @try {
      Local<Promise> promise = queued.Get(isolate_);
      NativeScriptException::DispatchRejectionHandledEvent(isolate_, promise,
                                                           v8::Undefined(isolate_));
    } @catch (NSException* exception) {
      Log(@"PromiseRejectionTracker: exception while firing rejectionhandled: %@", exception);
    }
  }

  for (auto& entry : snapshot) {
    if (entry.reported) {
      continue;
    }
    entry.reported = true;

    // The observer calling us holds live V8 scopes, so an NSException from the
    // reporting path must not unwind past this frame — catch and log instead.
    @try {
      Local<Promise> promise = entry.promise.Get(isolate_);
      Local<Value> reason = entry.reason.Get(isolate_);

      std::string stack = tns::GetSmartStackTrace(isolate_, nullptr, reason);
      if (stack.empty()) {
        stack =
            NativeScriptException::GetErrorStackTrace(isolate_, Exception::GetStackTrace(reason));
      }

      if (isWorker) {
        // Dispatch the rejection event on the worker's own global first;
        // preventDefault() there fully handles it. Only when unprevented fall
        // through to the existing worker channel (worker-global onerror →
        // forward to the main isolate's worker.onerror).
        if (!NativeScriptException::DispatchUnhandledRejectionEvent(isolate_, promise, reason)) {
          if (!GiveWorkerOnErrorAChance(isolate_, context, reason)) {
            Runtime* runtime = Runtime::GetRuntime(isolate_);
            if (runtime != nullptr) {
              int workerId = runtime->WorkerId();
              bool found = false;
              auto state = Caches::Workers->Get(workerId, found);
              if (found && state != nullptr) {
                auto* worker = static_cast<WorkerWrapper*>(state->UserData());
                if (worker != nullptr) {
                  std::string reasonMessage = tns::ToString(isolate_, reason);
                  worker->PassUncaughtRejectionToMain(reasonMessage, "Worker script", stack, 1);
                }
              }
            }
          }
        }
      } else {
        NativeScriptException::ReportUnhandledRejection(isolate_, promise, reason, stack);
      }

      // The rejection has now been reported (unhandledrejection fired, prevented
      // or not). Keep the promise as a phantom-weak outstanding entry so a
      // handler attached later fires rejectionhandled; a GC'd promise drops out
      // on its own.
      reportedOutstanding_.push_back(std::move(entry.promise));
      reportedOutstanding_.back().SetWeak();
    } @catch (NSException* exception) {
      Log(@"PromiseRejectionTracker: exception while reporting rejection: %@", exception);
    }
  }

  PruneReportedOutstanding();

  draining_ = false;
}

void NativeScriptException::ReThrowToV8(Isolate* isolate) {
  @try {
    // The Isolate::Scope here is necessary because the Exception::Error method internally relies on
    // the Isolate::GetCurrent method which might return null if we do not use the proper scope
    Isolate::Scope scope(isolate);

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> errObj;

    if (this->javascriptException_ != nullptr) {
      errObj = this->javascriptException_->Get(isolate);
      if (errObj->IsObject()) {
        if (!this->fullMessage_.empty()) {
          bool success = errObj.As<Object>()
                             ->Set(context, tns::ToV8String(isolate, "fullMessage"),
                                   tns::ToV8String(isolate, this->fullMessage_))
                             .FromMaybe(false);
          if (!success) {
            Log(@"Warning: Failed to set fullMessage property on error object");
          }
        } else if (!this->message_.empty()) {
          bool success = errObj.As<Object>()
                             ->Set(context, tns::ToV8String(isolate, "fullMessage"),
                                   tns::ToV8String(isolate, this->message_))
                             .FromMaybe(false);
          if (!success) {
            Log(@"Warning: Failed to set fullMessage property on error object");
          }
        }
      }
    } else if (!this->fullMessage_.empty()) {
      errObj = Exception::Error(tns::ToV8String(isolate, this->fullMessage_));
    } else if (!this->message_.empty()) {
      errObj = Exception::Error(tns::ToV8String(isolate, this->message_));
    } else {
      errObj = Exception::Error(
          tns::ToV8String(isolate, "No javascript exception or message provided."));
    }

    isolate->ThrowException(errObj);
  } @catch (NSException* exception) {
    Log(@"ReThrowToV8: Caught exception during error handling: %@", exception);
    @throw exception;
  }
}

std::string NativeScriptException::GetErrorMessage(Isolate* isolate, Local<Value>& error,
                                                   const std::string& prependMessage) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();

  // get whole error message from previous stack
  std::stringstream ss;

  if (prependMessage != "") {
    ss << prependMessage << std::endl;
  }

  std::string errMessage;
  bool hasFullErrorMessage = false;
  auto v8FullMessage = tns::ToV8String(isolate, "fullMessage");
  if (error->IsObject() && error.As<Object>()->Has(context, v8FullMessage).ToChecked()) {
    hasFullErrorMessage = true;
    Local<Value> errMsgVal;
    bool success = error.As<Object>()->Get(context, v8FullMessage).ToLocal(&errMsgVal);
    if (success && !errMsgVal.IsEmpty()) {
      errMessage = tns::ToString(isolate, errMsgVal.As<v8::String>());
    } else {
      errMessage = "";
      if (!success) {
        Log(@"Warning: Failed to get fullMessage property from error object");
      }
    }
    ss << errMessage;
  }

  MaybeLocal<v8::String> str = error->ToDetailString(context);
  if (!str.IsEmpty()) {
    v8::String::Utf8Value utfError(isolate, str.FromMaybe(Local<v8::String>()));
    if (hasFullErrorMessage) {
      ss << std::endl;
    }
    ss << *utfError;
  }

  return ss.str();
}

std::string NativeScriptException::GetErrorStackTrace(Isolate* isolate,
                                                      const Local<StackTrace>& stackTrace) {
  if (stackTrace.IsEmpty()) {
    return "";
  }

  std::stringstream ss;

  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);

  int frameCount = stackTrace->GetFrameCount();

  for (int i = 0; i < frameCount; i++) {
    Local<StackFrame> frame = stackTrace->GetFrame(isolate, i);
    std::string funcName = tns::ToString(isolate, frame->GetFunctionName());
    std::string srcName = tns::ToString(isolate, frame->GetScriptName());
    int lineNumber = frame->GetLineNumber();
    int column = frame->GetColumn();

    ss << "\t" << (i > 0 ? "at " : "") << funcName.c_str() << "(" << srcName.c_str() << ":"
       << lineNumber << ":" << column << ")" << std::endl;
  }

  return ss.str();
}
std::string NativeScriptException::GetFullMessage(Isolate* isolate, const TryCatch& tc,
                                                  const std::string& jsExceptionMessage) {
  std::string loggedMessage = GetFullMessage(isolate, tc.Message(), jsExceptionMessage);
  if (!tc.CanContinue()) {
    std::stringstream errM;
    errM << std::endl
         << "An uncaught error has occurred and V8's TryCatch block CAN'T be continued. ";
    loggedMessage = errM.str() + loggedMessage;
  }
  return loggedMessage;
}

std::string NativeScriptException::GetFullMessage(Isolate* isolate, Local<v8::Message> message,
                                                  const std::string& jsExceptionMessage) {
  Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

  std::stringstream ss;
  ss << jsExceptionMessage;

  // get script name
  Local<Value> scriptResName = message->GetScriptResourceName();

  // get stack trace
  std::string stackTraceMessage = GetErrorStackTrace(isolate, message->GetStackTrace());

  if (!scriptResName.IsEmpty() && scriptResName->IsString()) {
    ss << std::endl << "File: (" << tns::ToString(isolate, scriptResName.As<v8::String>());
  } else {
    ss << std::endl << "File: (<unknown>";
  }
  ss << ":" << message->GetLineNumber(context).ToChecked() << ":" << message->GetStartColumn()
     << ")" << std::endl
     << std::endl;
  ss << "StackTrace: " << std::endl << stackTraceMessage << std::endl;

  std::string loggedMessage = ss.str();

  // TODO: Log the error
  // tns::LogError(isolate, tc);

  return loggedMessage;
}

void NativeScriptException::ShowErrorModal(Isolate* isolate, const std::string& title,
                                           const std::string& message,
                                           const std::string& stackTrace) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

  if (!Runtime::showErrorDisplay()) {
    return;
  }

  uint64_t ticketToSchedule = 0;

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);

    // If the console already presented this error (console-first scenario), just enrich the
    // context.
    if (gPendingErrorDisplay.ticket != 0 && !gPendingErrorDisplay.contextCaptured &&
        gPendingErrorDisplay.modalPresented) {
      gPendingErrorDisplay.contextCaptured = true;
      gPendingErrorDisplay.isolate = isolate;
      gPendingErrorDisplay.title = title;
      gPendingErrorDisplay.message = message;
      gPendingErrorDisplay.rawStack = stackTrace;
      ConsiderStackCandidate(gPendingErrorDisplay, isolate, stackTrace);
      return;
    }

    gPendingErrorDisplay.ticket = gNextErrorTicket++;
    gPendingErrorDisplay.contextCaptured = true;
    gPendingErrorDisplay.modalPresented = false;
    gPendingErrorDisplay.fallbackScheduled = true;
    gPendingErrorDisplay.isolate = isolate;
    gPendingErrorDisplay.title = title;
    gPendingErrorDisplay.message = message;
    gPendingErrorDisplay.rawStack = stackTrace;
    gPendingErrorDisplay.consolePayload.clear();
    gPendingErrorDisplay.canonicalStack.clear();
    ConsiderStackCandidate(gPendingErrorDisplay, isolate, stackTrace);
    ticketToSchedule = gPendingErrorDisplay.ticket;
  }

  if (ticketToSchedule != 0) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      ScheduleFallbackPresentation(ticketToSchedule);
    });
  }
}

void NativeScriptException::SubmitConsoleErrorPayload(Isolate* isolate,
                                                      const std::string& payload) {
  if (!RuntimeConfig.IsDebug) {
    return;
  }

  if (!Runtime::showErrorDisplay()) {
    return;
  }

  PendingErrorDisplay stateSnapshot;
  bool presentNow = false;
  bool updateExisting = false;

  auto promoteConsolePayload = [&](const std::string& text, v8::Isolate* payloadIsolate) {
    gPendingErrorDisplay.consolePayload = text;
    if (payloadIsolate != nullptr) {
      gPendingErrorDisplay.isolate = payloadIsolate;
    }
    gPendingErrorDisplay.canonicalStack = text;
  };

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);

    auto buildDefaultContext = [&](void) {
      gPendingErrorDisplay.title = "JavaScript Error";
      std::string firstLine = payload;
      size_t newlinePos = payload.find('\n');
      if (newlinePos != std::string::npos) {
        firstLine = payload.substr(0, newlinePos);
      }
      gPendingErrorDisplay.message = firstLine;
      gPendingErrorDisplay.rawStack = payload;
      promoteConsolePayload(payload, isolate);
    };

    if (gPendingErrorDisplay.ticket == 0) {
      gPendingErrorDisplay.ticket = gNextErrorTicket++;
      gPendingErrorDisplay.canonicalStack.clear();
    }

    if (!gPendingErrorDisplay.contextCaptured && !gPendingErrorDisplay.modalPresented) {
      // Console-first scenario for a brand new error
      gPendingErrorDisplay.modalPresented = true;
      gPendingErrorDisplay.isolate = isolate;
      buildDefaultContext();
      stateSnapshot = gPendingErrorDisplay;
      presentNow = true;
    } else if (!gPendingErrorDisplay.modalPresented) {
      // Context captured (or pending) but UI not yet shown – prefer the console payload
      if (!gPendingErrorDisplay.contextCaptured) {
        buildDefaultContext();
      }
      if (isolate != nullptr) {
        gPendingErrorDisplay.isolate = isolate;
      }
      promoteConsolePayload(payload, isolate);
      gPendingErrorDisplay.modalPresented = true;
      stateSnapshot = gPendingErrorDisplay;
      presentNow = true;
    } else {
      // Modal already visible (fallback or previous payload) – just update the text content
      promoteConsolePayload(payload, isolate);
      updateExisting = true;
    }
  }

  if (presentNow) {
    std::string displayStack =
        stateSnapshot.canonicalStack.empty()
            ? (stateSnapshot.consolePayload.empty() ? ResolveDisplayStack(stateSnapshot)
                                                    : stateSnapshot.consolePayload)
            : stateSnapshot.canonicalStack;
    RenderErrorModalUI(stateSnapshot.isolate, stateSnapshot.title, stateSnapshot.message,
                       displayStack);
  } else if (updateExisting) {
    std::string displayStack = gPendingErrorDisplay.canonicalStack.empty()
                                   ? (gPendingErrorDisplay.consolePayload.empty()
                                          ? ResolveDisplayStack(gPendingErrorDisplay)
                                          : gPendingErrorDisplay.consolePayload)
                                   : gPendingErrorDisplay.canonicalStack;
    UpdateDisplayedStackText(displayStack);
  }
}

static void ScheduleFallbackPresentation(uint64_t ticket) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                   PresentFallbackIfNeeded(ticket);
                 });
}

static void PresentFallbackIfNeeded(uint64_t ticket) {
  PendingErrorDisplay snapshot;
  bool shouldPresent = false;

  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);
    if (gPendingErrorDisplay.ticket == ticket && !gPendingErrorDisplay.modalPresented) {
      gPendingErrorDisplay.modalPresented = true;
      snapshot = gPendingErrorDisplay;
      shouldPresent = true;
    }
  }

  if (!shouldPresent) {
    return;
  }

  std::string finalStack = ResolveDisplayStack(snapshot);

  RenderErrorModalUI(snapshot.isolate, snapshot.title, snapshot.message, finalStack);
}

static std::string ResolveDisplayStack(const PendingErrorDisplay& state) {
  // Deterministic preference: canonicalStack > consolePayload > rawStack > message
  // Remap when possible so the UI matches terminal output.
  if (!state.canonicalStack.empty()) {
    return state.canonicalStack;
  }

  auto remapIfPossible = [&](const std::string& text) -> std::string {
    if (text.empty()) return std::string();
    if (state.isolate != nullptr) {
      std::string remapped = tns::RemapStackTraceIfAvailable(state.isolate, text);
      if (!remapped.empty()) {
        return remapped;
      }
    }
    return text;
  };

  if (!state.consolePayload.empty()) {
    return remapIfPossible(state.consolePayload);
  }
  if (!state.rawStack.empty()) {
    return remapIfPossible(state.rawStack);
  }
  return state.message;
}

static void ConsiderStackCandidate(PendingErrorDisplay& state, v8::Isolate* isolate,
                                   const std::string& candidateStack) {
  if (candidateStack.empty()) {
    return;
  }

  v8::Isolate* effectiveIsolate = isolate != nullptr ? isolate : state.isolate;
  std::string normalized = candidateStack;
  if (effectiveIsolate != nullptr) {
    std::string remapped = tns::RemapStackTraceIfAvailable(effectiveIsolate, candidateStack);
    if (!remapped.empty()) {
      normalized = remapped;
    }
  }
  // Deterministic behavior: if no canonical stack yet, set it to the first available candidate.
  // Console payloads will explicitly override canonicalStack elsewhere.
  if (state.canonicalStack.empty()) {
    state.canonicalStack = normalized;
  }
}

static void UpdateDisplayedStackText(const std::string& stackText) {
  NSString* stackNSString = [NSString stringWithUTF8String:stackText.c_str()];
  if (stackNSString == nil) {
    stackNSString = @"(invalid UTF-8 stack trace)";
  }
  gLatestStackText = stackNSString;

  auto applyUpdate = ^{
    if (gErrorStackTextView != nil) {
      gErrorStackTextView.text = gLatestStackText;
      gErrorStackTextView.contentOffset = CGPointMake(0, 0);
    }
  };

  if ([NSThread isMainThread]) {
    applyUpdate();
  } else {
    dispatch_async(dispatch_get_main_queue(), applyUpdate);
  }
}

static void RenderErrorModalUI(v8::Isolate* isolate, const std::string& title,
                               const std::string& message, const std::string& stackText) {
  if (!RuntimeConfig.IsDebug || !Runtime::showErrorDisplay()) {
    return;
  }

  // Always prefer the shared pending state's canonical/console text so callers cannot
  // accidentally overwrite with a worse stack.
  std::string stackForModal = stackText;
  {
    std::lock_guard<std::mutex> lock(gErrorDisplayMutex);
    if (!gPendingErrorDisplay.canonicalStack.empty()) {
      stackForModal = gPendingErrorDisplay.canonicalStack;
    } else if (!gPendingErrorDisplay.consolePayload.empty()) {
      stackForModal = gPendingErrorDisplay.consolePayload;
    }
  }
  if (stackForModal.empty()) {
    stackForModal = message;
  }

  // Final guard: remap here as well so the UI always matches the terminal output,
  // even if earlier stages missed remapping due to timing.
  if (isolate != nullptr) {
    std::string maybeRemapped = tns::RemapStackTraceIfAvailable(isolate, stackForModal);
    if (!maybeRemapped.empty()) {
      stackForModal = maybeRemapped;
    }
  }

  UpdateDisplayedStackText(stackForModal);

  bool alreadyShowing = isErrorDisplayShowing;

  UIApplication* app = [UIApplication sharedApplication];
  BOOL hasAnyWindows = NO;
#if TARGET_OS_VISION
  if (@available(iOS 13.0, *)) {
    for (UIScene* scene in app.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene* ws = (UIWindowScene*)scene;
        if (ws.windows.count > 0) {
          hasAnyWindows = YES;
          break;
        }
      }
    }
  }
#else
  hasAnyWindows = app.windows.count > 0;
#endif
  if (!alreadyShowing && !hasAnyWindows && app.connectedScenes.count == 0) {
    Log(@"Note: JavaScript error during boot.");
    Log(@"================================");
    Log(@"%s", stackForModal.c_str());
    Log(@"================================");
    Log(@"Please fix the error and save the file to auto reload the app.");
    Log(@"================================");
    return;
  }

  if (alreadyShowing) {
    return;
  }

  isErrorDisplayShowing = true;

  auto showSynchronously = ^{
    @try {
      // Log(@"[ShowErrorModal] On main thread - showing modal synchronously %s", message.c_str());
      ShowErrorModalSynchronously(title, message, stackForModal);
    } @catch (NSException* exception) {
      Log(@"Error details - Title: %s, Message: %s", title.c_str(), message.c_str());
    }
  };

  if ([NSThread isMainThread]) {
    showSynchronously();
  } else {
    dispatch_sync(dispatch_get_main_queue(), showSynchronously);
  }
}

static void ShowErrorModalSynchronously(const std::string& title, const std::string& message,
                                        const std::string& stackTrace) {
  // Use static variables to keep strong references and prevent deallocation
  static UIWindow* __attribute__((unused)) foundationWindowRef =
      nil;  // Keep foundation window alive
  static UIWindow* errorWindow = nil;

  // BOOTSTRAP iOS APP LIFECYCLE: Ensure basic app infrastructure exists
  // This is crucial when JavaScript fails before UIApplicationMain completes normal setup
  UIApplication* sharedApp = [UIApplication sharedApplication];

  // If no windows exist, create a foundational window to establish the hierarchy
  BOOL appHasWindows = NO;
#if TARGET_OS_VISION
  if (@available(iOS 13.0, *)) {
    for (UIScene* scene in sharedApp.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        if (((UIWindowScene*)scene).windows.count > 0) {
          appHasWindows = YES;
          break;
        }
      }
    }
  }
#else
  appHasWindows = sharedApp.windows.count > 0;
#endif
  if (!appHasWindows) {
    // Log(@"🚀 Bootstrap: No app windows exist - creating foundational window hierarchy");

    // Create a basic foundational window that mimics what UIApplicationMain would create
    UIWindow* foundationWindow = nil;

    if (@available(iOS 13.0, *)) {
      // For iOS 13+, we need to handle window scenes properly
      UIWindowScene* foundationScene = nil;

      // Try to find or create a window scene
      for (UIScene* scene in sharedApp.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
          foundationScene = (UIWindowScene*)scene;
          // Log(@"🚀 Bootstrap: Found existing scene for foundation window");
          break;
        }
      }

      if (foundationScene) {
        foundationWindow = [[UIWindow alloc] initWithWindowScene:foundationScene];
        // Log(@"🚀 Bootstrap: Created foundation window with existing scene");
      } else {
        // If no scenes exist, create a window without scene (iOS 12 style fallback)
        // On visionOS, UIScreen is unavailable. Skip frame-based creation there.
#if !TARGET_OS_VISION
        foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
#endif
        // Log(@"🚀 Bootstrap: Created foundation window without scene (emergency mode)");
      }
    } else {
      // iOS 12 and below - simple window creation
      // On visionOS, UIScreen is unavailable; this branch is only for iOS 12 and below.
#if !TARGET_OS_VISION
      foundationWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
#endif
      // Log(@"🚀 Bootstrap: Created foundation window for iOS 12");
    }

    if (foundationWindow) {
      // Set up a basic root view controller to establish the hierarchy
      UIViewController* foundationViewController = [[UIViewController alloc] init];
      foundationViewController.view.backgroundColor = [UIColor blackColor];  // Invisible foundation
      foundationWindow.rootViewController = foundationViewController;
      foundationWindow.windowLevel = UIWindowLevelNormal;  // Base level
      foundationWindow.backgroundColor = [UIColor blackColor];

      // Make it key and visible to establish the window hierarchy
      [foundationWindow makeKeyAndVisible];

      // Keep a strong reference to prevent deallocation
      foundationWindowRef = foundationWindow;

      // Give iOS a moment to process the new window hierarchy (we're already on main queue)
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);

      // Detailed window hierarchy inspection
      BOOL appHasWindowsAfterBootstrap = NO;
#if TARGET_OS_VISION
      if (@available(iOS 13.0, *)) {
        for (UIScene* scene in sharedApp.connectedScenes) {
          if ([scene isKindOfClass:[UIWindowScene class]]) {
            if (((UIWindowScene*)scene).windows.count > 0) {
              appHasWindowsAfterBootstrap = YES;
              break;
            }
          }
        }
      }
#else
      appHasWindowsAfterBootstrap = sharedApp.windows.count > 0;
#endif
      if (!appHasWindowsAfterBootstrap) {
        // Log(@"🚀 Bootstrap: 🚨 CRITICAL: Foundation window not in app.windows hierarchy!");
        // Log(@"🚀 Bootstrap: This indicates a fundamental iOS window system issue");

        // Try alternative window registration approach
        // Log(@"🚀 Bootstrap: Attempting alternative window registration...");
        [foundationWindow.layer setNeedsDisplay];
        [foundationWindow.layer displayIfNeeded];
        [foundationWindow layoutIfNeeded];

        // Force another run loop cycle
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
      }
    } else {
      // Log(@"🚀 Bootstrap: WARNING - Failed to create foundation window");
    }
  } else {
    // Log(@"🚀 Bootstrap: App windows already exist (%lu) - no bootstrap needed",
    //       (unsigned long)sharedApp.windows.count);
  }

  // Create a dedicated error window that works even during early app lifecycle

  // Clean up any previous error window
  if (errorWindow) {
    errorWindow.hidden = YES;
    [errorWindow resignKeyWindow];
    errorWindow = nil;
    gErrorStackTextView = nil;
  }

  // iOS 13+ requires proper window scene handling
  if (@available(iOS 13.0, *)) {
    // Try to find an existing window scene, or create one if needed
    UIWindowScene* windowScene = nil;

    // First, try to find an existing connected scene
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        windowScene = (UIWindowScene*)scene;
        // Log(@"🎨 Found existing window scene for error modal");
        break;
      }
    }

    if (windowScene) {
      errorWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
      // Log(@"🎨 Created error window with existing scene");
    } else {
      // Fallback: create window with screen bounds (older behavior)
      // On visionOS, UIScreen is unavailable. Guard frame-based creation.
#if !TARGET_OS_VISION
      errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
#endif
      // Log(@"🎨 Created error window with screen bounds (no scene available)");
    }
  } else {
    // iOS 12 and below
    // On visionOS, UIScreen is unavailable; this branch is only for iOS 12 and below.
#if !TARGET_OS_VISION
    errorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
#endif
    // Log(@"🎨 Created error window for iOS 12");
  }

  errorWindow.windowLevel = UIWindowLevelAlert + 1000;  // Above everything
  errorWindow.backgroundColor = [UIColor colorWithRed:0.15
                                                green:0.15
                                                 blue:0.15
                                                alpha:1.0];  // Match the dark gray theme

  // Ensure window is visible regardless of app state
  errorWindow.hidden = NO;
  errorWindow.alpha = 1.0;

  // Create the error view controller
  UIViewController* errorViewController = [[UIViewController alloc] init];
  errorViewController.view.backgroundColor = [UIColor colorWithRed:0.15
                                                             green:0.15
                                                              blue:0.15
                                                             alpha:1.0];  // Dark gray tech theme

  // Content container
  UIView* contentView = [[UIView alloc] init];
  contentView.translatesAutoresizingMaskIntoConstraints = NO;
  [errorViewController.view addSubview:contentView];

  // NativeScript Logo (will be loaded asynchronously)
  UIImageView* logoImageView = [[UIImageView alloc] init];
  logoImageView.contentMode = UIViewContentModeScaleAspectFit;
  logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
  logoImageView.backgroundColor = [UIColor clearColor];
  [contentView addSubview:logoImageView];

  // Load NativeScript logo asynchronously
  NSString* logoURL = @"https://github.com/NativeScript/artwork/raw/refs/heads/main/logo/export/"
                      @"NativeScript_Logo_Wide_Transparent_White_Rounded_White.png";
  NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:logoURL]];
  NSURLSessionDataTask* logoTask = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
          if (data && !error) {
            UIImage* logoImage = [UIImage imageWithData:data];
            if (logoImage) {
              dispatch_async(dispatch_get_main_queue(), ^{
                logoImageView.image = logoImage;
                // Log(@"🎨 NativeScript logo loaded successfully");
              });
            } else {
              // Log(@"🎨 Failed to create image from logo data");
            }
          } else {
            // Log(@"🎨 Failed to load NativeScript logo: %@", error.localizedDescription);
            // Fallback: show text logo
            dispatch_async(dispatch_get_main_queue(), ^{
              UILabel* fallbackLogo = [[UILabel alloc] init];
              fallbackLogo.text = @"NativeScript";
              fallbackLogo.textColor = [UIColor whiteColor];
              fallbackLogo.font = [UIFont boldSystemFontOfSize:28];
              fallbackLogo.textAlignment = NSTextAlignmentCenter;
              fallbackLogo.translatesAutoresizingMaskIntoConstraints = NO;
              [contentView addSubview:fallbackLogo];

              // Update constraints for fallback
              [NSLayoutConstraint activateConstraints:@[
                [fallbackLogo.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:40],
                [fallbackLogo.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
                [fallbackLogo.heightAnchor constraintEqualToConstant:40]
              ]];
            });
          }
        }];
  [logoTask resume];

  // Instruction message (between logo and error)
  UILabel* instructionLabel = [[UILabel alloc] init];
  instructionLabel.text = @"Please resolve the error shown to continue.";
  instructionLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
  instructionLabel.font = [UIFont systemFontOfSize:16];
  instructionLabel.textAlignment = NSTextAlignmentCenter;
  instructionLabel.numberOfLines = 0;
  instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:instructionLabel];

  // Error title (simplified)
  UILabel* errorTitleLabel = [[UILabel alloc] init];
  errorTitleLabel.text = @"⚠️ JavaScript Error";
  errorTitleLabel.textColor = [UIColor colorWithRed:1.0
                                              green:0.6
                                               blue:0.2
                                              alpha:1.0];  // Orange warning
  errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
  errorTitleLabel.textAlignment = NSTextAlignmentCenter;
  errorTitleLabel.numberOfLines = 0;
  errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:errorTitleLabel];

  // Stack trace container - BLACK background for terminal-like feel
  UIView* stackTraceContainer = [[UIView alloc] init];
  stackTraceContainer.backgroundColor = [UIColor blackColor];  // Pure black for terminal feel
  stackTraceContainer.layer.cornerRadius = 12;
  stackTraceContainer.layer.borderWidth = 1;
  stackTraceContainer.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
  stackTraceContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:stackTraceContainer];

  // Log(@"errorToDisplay from in NativeScriptException ShowErrorModal: %s", stackTrace.c_str());
  // Stack trace text view - with proper terminal styling
  UITextView* stackTraceTextView = [[UITextView alloc] init];
  NSString* initialStackText = gLatestStackText;
  if (initialStackText == nil) {
    initialStackText = [NSString stringWithUTF8String:stackTrace.c_str()];
    if (initialStackText == nil) {
      initialStackText = @"(invalid UTF-8 stack trace)";
    }
    gLatestStackText = initialStackText;
  }
  stackTraceTextView.text = initialStackText;
  stackTraceTextView.textColor = [UIColor colorWithRed:0.0
                                                 green:1.0
                                                  blue:0.0
                                                 alpha:1.0];  // Terminal green
  stackTraceTextView.backgroundColor = [UIColor clearColor];
  stackTraceTextView.font = [UIFont fontWithName:@"Menlo" size:16];  // Monospace
  stackTraceTextView.editable = NO;
  stackTraceTextView.selectable = YES;
  stackTraceTextView.scrollEnabled = YES;
  stackTraceTextView.contentInset = UIEdgeInsetsMake(15, 15, 15, 15);
  stackTraceTextView.translatesAutoresizingMaskIntoConstraints = NO;
  [stackTraceContainer addSubview:stackTraceTextView];
  gErrorStackTextView = stackTraceTextView;

  // Hot-reload indicator
  UILabel* hotReloadLabel = [[UILabel alloc] init];
  hotReloadLabel.text = @"Fix the error and save your changes to continue.";
  hotReloadLabel.textColor = [UIColor colorWithRed:0.2
                                             green:0.8
                                              blue:1.0
                                             alpha:1.0];  // Bright blue
  hotReloadLabel.font = [UIFont systemFontOfSize:14];
  hotReloadLabel.textAlignment = NSTextAlignmentCenter;
  hotReloadLabel.numberOfLines = 0;
  hotReloadLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [contentView addSubview:hotReloadLabel];

  // Set up constraints
  [NSLayoutConstraint activateConstraints:@[
    // Content view
    [contentView.topAnchor
        constraintEqualToAnchor:errorViewController.view.safeAreaLayoutGuide.topAnchor],
    [contentView.leadingAnchor constraintEqualToAnchor:errorViewController.view.leadingAnchor],
    [contentView.trailingAnchor constraintEqualToAnchor:errorViewController.view.trailingAnchor],
    [contentView.bottomAnchor
        constraintEqualToAnchor:errorViewController.view.safeAreaLayoutGuide.bottomAnchor],

    // NativeScript Logo at top center
    [logoImageView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:30],
    [logoImageView.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
    [logoImageView.heightAnchor constraintEqualToConstant:60],
    [logoImageView.widthAnchor constraintLessThanOrEqualToConstant:300],

    // Instruction message below logo
    [instructionLabel.topAnchor constraintEqualToAnchor:logoImageView.bottomAnchor constant:20],
    [instructionLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [instructionLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                    constant:-20],

    // Error title below instruction
    [errorTitleLabel.topAnchor constraintEqualToAnchor:instructionLabel.bottomAnchor constant:20],
    [errorTitleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [errorTitleLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                   constant:-20],

    // Stack trace container (black terminal-like background) - flexible height
    [stackTraceContainer.topAnchor constraintEqualToAnchor:errorTitleLabel.bottomAnchor
                                                  constant:15],
    [stackTraceContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor
                                                      constant:20],
    [stackTraceContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                       constant:-20],

    // Stack trace text view (terminal green text on black)
    [stackTraceTextView.topAnchor constraintEqualToAnchor:stackTraceContainer.topAnchor],
    [stackTraceTextView.leadingAnchor constraintEqualToAnchor:stackTraceContainer.leadingAnchor],
    [stackTraceTextView.trailingAnchor constraintEqualToAnchor:stackTraceContainer.trailingAnchor],
    [stackTraceTextView.bottomAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor],

    [hotReloadLabel.topAnchor constraintEqualToAnchor:stackTraceContainer.bottomAnchor constant:15],
    [hotReloadLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
    [hotReloadLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
    [hotReloadLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-30],
  ]];

  // Present the error window with robust error handling
  errorWindow.rootViewController = errorViewController;

  // Force the window to be visible with multiple approaches
  // Log(@"Attempting to display error modal...");

  @try {
    // Primary approach: makeKeyAndVisible
    [errorWindow makeKeyAndVisible];
    // Log(@"makeKeyAndVisible called successfully");

    // Secondary approach: force visibility
    errorWindow.hidden = NO;
    errorWindow.alpha = 1.0;

    // Force a layout pass to ensure UI is rendered
    [errorWindow layoutIfNeeded];
    [errorViewController.view layoutIfNeeded];

    // Bring window to front (alternative to makeKeyAndVisible)
    [errorWindow bringSubviewToFront:errorViewController.view];

    // Verify the window is in the window hierarchy
    NSArray<UIWindow*>* windows = nil;
#if TARGET_OS_VISION
    if (@available(iOS 13.0, *)) {
      NSMutableArray<UIWindow*>* acc = [NSMutableArray array];
      for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
          [acc addObjectsFromArray:((UIWindowScene*)scene).windows];
        }
      }
      windows = [acc copy];
    } else {
      windows = @[];
    }
#else
    windows = [UIApplication sharedApplication].windows;
#endif
    BOOL windowInHierarchy = [windows containsObject:errorWindow];
    // Log(@"Error window in app windows: %@", windowInHierarchy ? @"YES" : @"NO");

    if (!windowInHierarchy) {
      // Aggressive fix 1: Try to force the window to be key and make it the only visible window
      Log(@"Total app windows before fix: %lu", (unsigned long)windows.count);

      // Hide all other windows to ensure our error window is the only one visible
      for (UIWindow* window in windows) {
        if (window != errorWindow) {
          window.hidden = YES;
          window.alpha = 0.0;
          // Log(@"🎨 Hiding existing window: %@", window);
        }
      }

      // Force our window to be the key window and front-most
      errorWindow.windowLevel = UIWindowLevelAlert + 2000;  // Even higher level
      errorWindow.hidden = NO;
      errorWindow.alpha = 1.0;

      // Try multiple approaches to make it visible
      [errorWindow makeKeyAndVisible];
      [errorWindow becomeKeyWindow];

      // Force immediate layout and display
      [errorWindow setNeedsLayout];
      [errorWindow layoutIfNeeded];
      [errorWindow setNeedsDisplay];
    }

    // Log(@"Error modal displayed successfully!");

  } @catch (NSException* exception) {
    // Log(@"ERROR: Failed to display error modal: %@", exception);
    // Log(@"Attempting fallback display method...");

    // Fallback: Try to show an alert instead
    NSString* fallbackMessage = gLatestStackText;
    if (fallbackMessage == nil) {
      fallbackMessage = [NSString stringWithUTF8String:stackTrace.c_str()];
      if (fallbackMessage == nil) {
        fallbackMessage = @"(invalid UTF-8 stack trace)";
      }
    }

    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"⚠️ JavaScript Error"
                                            message:fallbackMessage
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* action = [UIAlertAction actionWithTitle:@"Continue Development 🚀"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil];
    [alert addAction:action];

    // Try to present the alert
    UIViewController* topViewController = errorViewController;
    [topViewController presentViewController:alert
                                    animated:YES
                                  completion:^{
                                    Log(@"🎨 Fallback alert displayed successfully!");
                                  }];
  }

  // Add a delay to ensure the UI is fully rendered and give the modal time to stabilize
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   //  Log(@"🎨 Error modal UI fully rendered and stable - app should stay alive
                   //  now");

                   // Force the main run loop to process any pending events to keep the app
                   // responsive
                   CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
                 });
}  // namespace

}  // namespace tns
