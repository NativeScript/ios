#include "ErrorEvents.h"

#include "Caches.h"
#include "Helpers.h"
#include "NativeScriptException.h"

using namespace v8;

namespace tns {

// Native function handed to the bootstrap IIFE as `nativeReportFatal(error,
// stackString)`. It runs the terminal tail (shim + fatal log) WITHOUT
// re-dispatching an event: reportError and listener-thrown errors have already
// gone through JS dispatch, so dispatching again here would recurse.
static void NativeReportFatalCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Value> error =
      info.Length() > 0 ? info[0] : v8::Undefined(isolate).As<Value>();
  std::string stack = info.Length() > 1 ? tns::ToString(isolate, info[1]) : "";
  NativeScriptException::ReportFatalTail(isolate, error, Local<v8::Message>(),
                                         stack, "");
}

void ErrorEvents::Init(Local<Context> context) {
  // WHATWG error-events layer, layered on top of the generic event primitives
  // installed by Events::Init. Plain (module-free) script, strict inside the
  // IIFE, ES5-ish so it never depends on other runtime extensions. The IIFE is
  // invoked with two arguments — the internal EventTarget backing the global
  // (so native dispatch survives app code overwriting globalThis.dispatchEvent)
  // and the native nativeReportFatal(error, stack) function that runs the
  // terminal tail — and returns three closures bound to that backing store.
  // ErrorEvent/PromiseRejectionEvent subclass the Event captured off globalThis
  // at init time, which runs before any user code.
  std::string source = R"(
    (function (globalTarget, nativeReportFatal) {
      "use strict";
      var g = globalThis;
      var Event = g.Event;

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
      globalTarget._installListenerErrorReporter(function (e) {
        try { nativeReportFatal(e, (e && e.stack) || ""); } catch (ignored) {}
      });

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

  auto cache = Caches::Get(isolate);
  tns::Assert(cache != nullptr && cache->GlobalEventTarget != nullptr, isolate);
  Local<Object> globalTarget = cache->GlobalEventTarget->Get(isolate);

  Local<Script> script;
  bool success = Script::Compile(context, tns::ToV8String(isolate, source))
                     .ToLocal(&script);
  tns::Assert(success && !script.IsEmpty(), isolate);

  Local<Value> result;
  success = script->Run(context).ToLocal(&result);
  tns::Assert(success && result->IsFunction(), isolate);

  Local<v8::Function> iife = result.As<v8::Function>();

  Local<v8::Function> nativeReportFatal;
  success = v8::Function::New(context, NativeReportFatalCallback)
                .ToLocal(&nativeReportFatal);
  tns::Assert(success, isolate);

  Local<Value> installArgs[] = {globalTarget, nativeReportFatal};
  Local<Value> iifeResult;
  success = iife->Call(context, context->Global(), 2, installArgs)
                .ToLocal(&iifeResult);
  tns::Assert(success && iifeResult->IsArray(), isolate);

  Local<v8::Array> closures = iifeResult.As<v8::Array>();
  Local<Value> errorFn, rejectionFn, handledFn;
  tns::Assert(
      closures->Get(context, 0).ToLocal(&errorFn) && errorFn->IsFunction(),
      isolate);
  tns::Assert(closures->Get(context, 1).ToLocal(&rejectionFn) &&
                  rejectionFn->IsFunction(),
              isolate);
  tns::Assert(
      closures->Get(context, 2).ToLocal(&handledFn) && handledFn->IsFunction(),
      isolate);

  cache->DispatchErrorEventFunc = std::make_unique<Persistent<v8::Function>>(
      isolate, errorFn.As<v8::Function>());
  cache->DispatchUnhandledRejectionFunc =
      std::make_unique<Persistent<v8::Function>>(
          isolate, rejectionFn.As<v8::Function>());
  cache->DispatchRejectionHandledFunc =
      std::make_unique<Persistent<v8::Function>>(isolate,
                                                 handledFn.As<v8::Function>());
}

// Dispatches the cancelable `error` ErrorEvent through the JS listener store.
// Returns true when a listener called preventDefault(). A dispatch that itself
// throws is logged and treated as unprevented so an error is never lost.
bool ErrorEvents::DispatchError(Isolate* isolate, Local<Value> error,
                                const std::string& messageString,
                                const std::string& stack) {
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
  bool success =
      dispatch->Call(context, context->Global(), 3, args).ToLocal(&result);
  if (tc.HasCaught()) {
    tns::LogError(isolate, tc);
    return false;
  }
  return success && !result.IsEmpty() && result->BooleanValue(isolate);
}

bool ErrorEvents::DispatchUnhandledRejection(Isolate* isolate,
                                             Local<Promise> promise,
                                             Local<Value> reason) {
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->DispatchUnhandledRejectionFunc == nullptr) {
    return false;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> dispatch =
      cache->DispatchUnhandledRejectionFunc->Get(isolate);
  Local<Value> args[] = {promise, reason};
  Local<Value> result;
  TryCatch tc(isolate);
  bool success =
      dispatch->Call(context, context->Global(), 2, args).ToLocal(&result);
  if (tc.HasCaught()) {
    tns::LogError(isolate, tc);
    return false;
  }
  return success && !result.IsEmpty() && result->BooleanValue(isolate);
}

void ErrorEvents::DispatchRejectionHandled(Isolate* isolate,
                                           Local<Promise> promise,
                                           Local<Value> reason) {
  auto cache = Caches::Get(isolate);
  if (cache == nullptr || cache->DispatchRejectionHandledFunc == nullptr) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> dispatch =
      cache->DispatchRejectionHandledFunc->Get(isolate);
  Local<Value> args[] = {promise, reason};
  Local<Value> result;
  TryCatch tc(isolate);
  if (!dispatch->Call(context, context->Global(), 2, args).ToLocal(&result) &&
      tc.HasCaught()) {
    tns::LogError(isolate, tc);
  }
}

}  // namespace tns
