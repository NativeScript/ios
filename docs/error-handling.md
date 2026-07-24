# Error handling

The runtime implements the WHATWG error model at the global level: uncaught JavaScript exceptions and unhandled promise rejections are dispatched as cancelable events on `globalThis`, native `NSException`s round-trip into JavaScript with the original object attached, and `interop.escapeException` forwards a JavaScript throw to a native caller as a real `@throw`. By default nothing crashes the app — reporting is opt-out per error (`preventDefault()`), and rethrowing unprevented errors natively is opt-in (`uncaughtErrorPolicy: "throw"`).

## Quick reference

| Situation | Default behavior |
|---|---|
| Uncaught JS exception | Cancelable `error` event on `globalThis` → if unprevented: `__onUncaughtError` hook, fatal log, error modal in debug. App keeps running. |
| Unhandled promise rejection | Tracked per isolate, reported once per run-loop turn: cancelable `unhandledrejection` event → same fallback chain, prefixed `Unhandled promise rejection:`. |
| `.catch()` added after the report | `rejectionhandled` event (non-cancelable), carrying the original reason. |
| JS throw inside a native callback (overridden method, block, property accessor, adapter) | Reported through the same pipeline; the native caller receives a zero/`nil` default and continues. The process never aborts on a JS throw. |
| `throw interop.escapeException(x)` inside a native callback | Converted to a real native `@throw` at the boundary — no JS-side reporting; the native caller's `@try/@catch` sees the exception. |
| Native `@throw` during a JS→native call | Surfaced to JS as an `Error` carrying the original exception as `error.nativeException`. |

## JavaScript API

### Global error events

```js
globalThis.addEventListener("error", (e) => {
  // e is an ErrorEvent: { message, error, filename, lineno, colno }
  // (filename/lineno/colno are not populated yet)
  console.log(e.message, e.error);
  e.preventDefault(); // marks the error handled: no hook, no fatal log, no modal
});

globalThis.addEventListener("unhandledrejection", (e) => {
  // e is a PromiseRejectionEvent: { promise, reason }
  console.log(e.reason);
  e.preventDefault();
});

globalThis.addEventListener("rejectionhandled", (e) => {
  // fired (as a task, on the next run-loop turn) when a handler is attached
  // to a promise whose rejection was already reported; carries the original
  // reason. Not cancelable.
});
```

Notes:

- `error` and `unhandledrejection` are `cancelable`; `preventDefault()` suppresses every downstream consequence (legacy hooks, fatal log, error modal, the `uncaughtErrorPolicy: "throw"` rethrow).
- Events fire even if app code overwrites `globalThis.dispatchEvent` — native dispatch goes through closures captured at startup.
- A listener that throws does not stop the remaining listeners; the thrown value is routed to the fatal reporting tail directly (never recursively dispatched as another `error` event).
- The events also fire on worker globals. A worker's unhandled rejection dispatches `unhandledrejection` on the worker's own global first; only when unprevented does it continue to the worker-global `onerror` and then to the main isolate's `worker.onerror`, mirroring uncaught worker errors.

### `reportError`

Routes a caught-but-fatal error through the exact same pipeline as an uncaught exception:

```js
reportError(new Error("something unrecoverable"));
```

### Event classes

`Event`, `EventTarget`, `ErrorEvent` and `PromiseRejectionEvent` are installed as global constructors. `Event`/`EventTarget` are general-purpose (registration order, `once`/`capture` options, `stopImmediatePropagation`, `handleEvent` objects) and usable for your own eventing:

```js
const target = new EventTarget();
target.addEventListener("tick", (e) => { ... }, { once: true });
target.dispatchEvent(new Event("tick")); // returns !defaultPrevented
```

### What lands on the events

The stacks live on the error/reason **value**, not on the event — and the thrown value can be anything, so shape-check before use:

| You wrote | `e.error` / `e.reason` is | JS stack | Native exception |
|---|---|---|---|
| `throw new Error("x")` | that `Error` | `e.error.stack` | — |
| called a native method that threw, without try/catch | an `Error` with `name` = the `NSException` name, `message` = its reason | `e.error.stack` (the JS call site) | `e.error.nativeException` — the original `NSException` (`.name`, `.reason`, `.userInfo`, `.callStackSymbols` captured at the native throw) |
| `throw NSException.exceptionWithNameReasonUserInfo(...)` | the wrapped `NSException` itself — not an `Error`, no `.stack` | — | `e.error` directly (`instanceof NSException`); `.callStackSymbols` is only populated if it was actually thrown natively, not when merely constructed |

### Catching native exceptions

```js
try {
  NSArray.alloc().init().objectAtIndex(3);
} catch (e) {
  e.nativeException instanceof NSException; // true
  e.nativeException.name;                   // "NSRangeException"
  e.nativeException.reason;                 // "... index 3 beyond bounds ..."
  e.nativeException.callStackSymbols;       // native frames at the throw site
}
```

Methods with `NSError**` out-parameters are unchanged: they throw a JS `Error` with `code`, `domain` and `nativeException` set to the `NSError`.

### Forwarding a throw to native: `interop.escapeException`

A plain JS throw inside a native callback is reported and the native caller continues with a default value. When the native caller *must* observe the failure — a parent `@try/@catch` is waiting, or you want a real native crash — brand the throw:

```js
const Delegate = NSObject.extend({
  someNativeMethod() {
    throw interop.escapeException(new Error("propagate me natively"));
  },
}, { protocols: [SomeProtocol] });
```

At the JS→native boundary the branded throw becomes a native `@throw` (executed only after every V8 scope has unwound). Semantics:

- `escapeException(err)` returns a JS `Error` (message/stack copied), so it behaves like a normal throw in pure-JS paths; the brand is an isolate-private symbol that user code cannot forge. Passing an already-branded value is a no-op; calling with no argument throws `TypeError`.
- If `err` is (or carries via `.nativeException`) a native `NSException`, the **original object** is rethrown — a parent `@catch (NSRangeException *)` matches, and identity is preserved:

```js
try {
  riskyNativeCall();
} catch (e) {
  throw interop.escapeException(e); // rethrows the exact original NSException
}
```

- Otherwise an `NSException` is synthesized: `name` from the error's name, `reason` from its message plus the JS stack, and the stacks in `userInfo` (see the native section).
- An escaped exception that nothing catches natively terminates the app with a real native crash report.
- Escapes thrown from *inside* an `error`/`unhandledrejection` listener are honored too: the reporting tail detects the brand and schedules the native throw.
- `escapeException` is the per-call tool and works **regardless of `uncaughtErrorPolicy`** and **at every boundary** (including native→JS blocks and overridden methods): it bypasses JS-side reporting entirely and converts *that one throw* into a native `@throw`. `uncaughtErrorPolicy: "throw"` is the global policy — it applies only to *unprevented, unbranded* errors, only *after* they are reported, and only rethrows synchronously at boundaries that report within their own frame (property accessors / adapters); block and overridden-method boundaries fall back to the deferred clean-frame throw. When you need a native handler around a specific block/method call to catch a JS failure, use `escapeException`, not the policy.

Limitations: two boundaries execute under the *caller's* live V8 scopes and therefore cannot convert a branded escape into a native throw — fast enumeration (`for...in` over a JS object from native) and `DictionaryAdapter.getProperties`. There, a branded escape surfaces as an ordinary JS exception.

## Native API

### Catching escaped exceptions

```objc
@try {
  [jsImplementedObject someNativeMethod];
} @catch (NSException *e) {
  // For synthesized escapes: e.name/e.reason come from the JS error, and
  // e.reason includes the JS stack. For rethrown originals: e is the very
  // same object that was originally thrown natively.
}
```

### JS stack traces on `NSException`

Every `NSException` produced by the escape/crash machinery carries the JavaScript context:

```objc
#import <NativeScript/NSExceptionSupport.h>

NSString *jsStack = exception.tns_javascriptStackTrace; // nil when no JS involvement
```

The accessor is uniform across all cases; underneath:

| Exception | Where the JS stack lives |
|---|---|
| Synthesized escape | `userInfo[TNSJavaScriptStackTraceKey]` (`@"JavaScriptStack"`), plus `userInfo[TNSJavaScriptEscapeStackTraceKey]` (`@"JavaScriptEscapeStack"`) when the `escapeException` call site differs from the error's origin; also appended to `reason` |
| Rethrown original `NSException` | attached as an associated object (identity and `userInfo` are untouched); the string combines the origin stack and the escape site |
| `uncaughtErrorPolicy: "throw"` fatal (`NativeScriptFatalJSException`) | `userInfo[TNSJavaScriptStackTraceKey]`, also in `reason` |

`tns_javascriptStackTrace` and the two `userInfo` keys are the stable contract for crash-SDK integrations.

## Configuration

`uncaughtErrorPolicy` in the app's `package.json` is the uncaught-error contract, unified across NativeScript runtimes (9.1+):

```jsonc
{ "uncaughtErrorPolicy": "report" } // default: report and keep running
{ "uncaughtErrorPolicy": "throw" }  // unprevented errors are rethrown natively
```

- `"report"` — after the event dispatch and legacy hooks, log the fatal message and keep the app alive.
- `"throw"` — additionally rethrow the error as a real `NSException` (`NativeScriptFatalJSException`, JS stack in `reason` and `userInfo`). When a JS→native boundary reports the error **synchronously within its own frame** (a property accessor or `DictionaryAdapter` read invoked from native), it is rethrown **synchronously at that boundary** — after every V8 scope unwinds — so a native `@try/@catch` around that call can catch it, matching Android. Otherwise — loop-originated errors (timers, microtasks, unhandled rejections) and native→JS **block / overridden-method** callbacks (whose throw is surfaced to V8 and reported up-stack, not in the callback's own frame) — it is thrown from a clean frame on the runtime loop on the next turn. Either way this is a **throw, not a crash guarantee**: the app terminates only if nothing catches it — which also means crash reporters capture it properly when it does. To force a synchronous native `@throw` at *any* boundary regardless of policy, use `interop.escapeException`.
- Unknown values log a warning once and fall back to `"report"`.

Deprecated: `discardUncaughtJsExceptions` is still honored in full for now — unprevented errors route to `__onDiscardedError` instead of `__onUncaughtError`, the fatal log is skipped, and any `"throw"` policy is suppressed — but it logs a deprecation warning. Migrate to an `error`/`unhandledrejection` listener calling `preventDefault()` (per-error, more precise) and `uncaughtErrorPolicy`.

Terminal-path decision table for an uncaught error / unhandled rejection:

| Condition | legacy hook called | fatal log / modal | native throw |
|---|---|---|---|
| `"report"` (default) | `__onUncaughtError` | yes | no |
| `"throw"`, unprevented | `__onUncaughtError` | yes | yes |
| listener called `preventDefault()` | no | no | no |
| `discardUncaughtJsExceptions` (deprecated) | `__onDiscardedError` | no | no |

## Crash reporter integration

JS side — attach both the JS and native exception from one listener:

```js
function nativeExceptionOf(value) {
  if (value instanceof NSException) return value;
  return (value && value.nativeException instanceof NSException) ? value.nativeException : null;
}

globalThis.addEventListener("error", (e) => {
  const err = e.error;
  const native = nativeExceptionOf(err);
  crashReporter.capture(err instanceof Error ? err : new Error(e.message), {
    nativeName: native?.name,
    nativeReason: native?.reason,
    nativeStack: native?.callStackSymbols, // NSArray of symbolicated frames
  });
  // e.preventDefault(); // only if the reporter fully owns error handling
});
```

Native side — for the `NSUncaughtExceptionHandler`/signal layer, read `exception.tns_javascriptStackTrace` (or the `userInfo` keys) to attach the JS stack to crashes that never pass through the JS event layer (escaped exceptions, `uncaughtErrorPolicy: "throw"`).

## Legacy hooks (deprecated)

`global.__onUncaughtError` and `global.__onDiscardedError` keep working exactly as before and are what `@nativescript/core` currently installs (surfaced as `Application.uncaughtErrorEvent` / `discardedErrorEvent`). They are invoked only when no event listener called `preventDefault()`. New code should prefer `globalThis.addEventListener("error" | "unhandledrejection", ...)`.

## Behavior details

- Every error is reported exactly once: either the V8 message listener (synchronous throws), the rejection drain (once per run-loop turn, `kCFRunLoopBeforeWaiting`), or the boundary handler — never two of them for the same error.
- A rejection that gets a handler before the end-of-turn drain is never reported (and produces no `rejectionhandled` either).
- Rejection events carry the underlying V8 promise. `Promise.reject(...)` returns a `PromiseProxy`-wrapped object, so compare promises between events (`unhandledrejection` ↔ `rejectionhandled`), not against your proxy handle.
- ObjC exceptions never unwind through live V8 frames: boundaries catch on the JS side and rethrow after scope teardown, and crash-mode throws are deferred to a clean run-loop frame. Preserve this invariant when touching the boundary code.
