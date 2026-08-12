# Runtime documentation

- [Performance API](performance.md) — WHATWG `performance` (hr-time, user
  timing, performance timeline with `PerformanceObserver`), per-isolate time
  origins for workers, the native clock hook that future `requestAnimationFrame`
  work must share, and the documented spec deviations.
- [Error handling](error-handling.md) — global `error`/`unhandledrejection` events, `reportError`, catching native exceptions in JS (`error.nativeException`), forwarding JS throws to native (`interop.escapeException`), JS stacks on `NSException`, configuration flags, and crash-reporter integration.

- [structuredClone](structured-clone.md) — the WHATWG `structuredClone(value, { transfer })` global: what clones, how graph identity and cycles are preserved, `ArrayBuffer` transfer, and the `DataCloneError`-named `Error` that stands in for `DOMException`.

- [Node-API](node-api.md) — writing a Node-API addon for this runtime: registering a module and loading it with `require()`, getting the `napi_env` from native code, the threading contract, finalizer timing, which Node-API version applies, and the divergences from Node's `node_api.h`.

## Knowledge

Notes on work that is done, kept because the reasoning is expensive to
reconstruct rather than because anything needs doing.

- [V8 10.3 → 14.9 migration](knowledge/v8-14-migration.md) — the API changes and
  their site counts, why each non-default gn arg exists, the accessor rules that
  are not mechanical, and the traps that only show up at runtime.
- [Resurrecting finalizers](knowledge/v8-resurrecting-finalizers.md) — the patch
  that restores `WeakCallbackType::kFinalizer`, removed upstream right after
  10.3.22, with its invariants and test plan.
