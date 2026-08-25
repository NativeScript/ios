"use strict";

const { globalTarget, nativeReportFatal, isDebug } = binding;
const { FunctionPrototypeCall, ObjectCreate, String, TypeError } = primordials;
var g = globalThis;
var Event = g.Event;

function ErrorEvent(type, opts) {
  opts = opts || {};
  FunctionPrototypeCall(Event, this, type, opts);
  this.message = opts.message !== undefined ? String(opts.message) : "";
  this.filename = opts.filename !== undefined ? String(opts.filename) : "";
  this.lineno = opts.lineno !== undefined ? (opts.lineno | 0) : 0;
  this.colno = opts.colno !== undefined ? (opts.colno | 0) : 0;
  this.error = opts.error !== undefined ? opts.error : null;
}
ErrorEvent.prototype = ObjectCreate(Event.prototype);
ErrorEvent.prototype.constructor = ErrorEvent;

function PromiseRejectionEvent(type, opts) {
  opts = opts || {};
  FunctionPrototypeCall(Event, this, type, opts);
  this.promise = opts.promise;
  this.reason = opts.reason;
}
PromiseRejectionEvent.prototype = ObjectCreate(Event.prototype);
PromiseRejectionEvent.prototype.constructor = PromiseRejectionEvent;

// A listener that throws must not stop other listeners: route the thrown
// value to the native fatal tail instead of ever recursively dispatching
// another `error` event from inside dispatch.
require("internal/events").setListenerErrorReporter(function (e) {
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

// Fired when JS touches a wrapper whose native counterpart was already
// released (see docs/knowledge/v8-resurrecting-finalizers.md) and the
// `releasedObjectPolicy` runtime config (ns:runtime) is "report". The
// operation itself no-ops; this event is the observability channel.
function ReleasedNativeAccessEvent(type, opts) {
  opts = opts || {};
  FunctionPrototypeCall(Event, this, type, opts);
  this.error = opts.error !== undefined ? opts.error : null;
  this.operation = opts.operation !== undefined ? String(opts.operation) : "";
}
ReleasedNativeAccessEvent.prototype = ObjectCreate(Event.prototype);
ReleasedNativeAccessEvent.prototype.constructor = ReleasedNativeAccessEvent;

function dispatchReleasedNativeAccess(error, operation) {
  var ev = new ReleasedNativeAccessEvent("releasednativeaccess", {
    error: error,
    operation: operation,
    cancelable: true
  });
  // The debug console warning is the event's default action: a listener that
  // handles the report (e.g. forwards it to a crash reporter) suppresses it
  // with preventDefault().
  if (globalTarget.dispatchEvent(ev) && isDebug) {
    // Deliberately a dynamic lookup: logging pipelines legitimately replace
    // console, and this warning should flow through whatever is installed.
    try {
      g.console.warn("Access to a released native object (" + operation + ")", error);
    } catch (ignored) { /* console gone or throwing must not break dispatch */ }
  }
}

module.exports = [dispatchErrorEvent, dispatchUnhandledRejection, dispatchRejectionHandled, dispatchReleasedNativeAccess];
