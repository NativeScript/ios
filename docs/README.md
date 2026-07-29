# Runtime documentation

- [Error handling](error-handling.md) — global `error`/`unhandledrejection` events, `reportError`, catching native exceptions in JS (`error.nativeException`), forwarding JS throws to native (`interop.escapeException`), JS stacks on `NSException`, configuration flags, and crash-reporter integration.

## Knowledge

Notes on work that is done, kept because the reasoning is expensive to
reconstruct rather than because anything needs doing.

- [V8 10.3 → 14.9 migration](knowledge/v8-14-migration.md) — the API changes and
  their site counts, why each non-default gn arg exists, the accessor rules that
  are not mechanical, and the traps that only show up at runtime.
- [Resurrecting finalizers](knowledge/v8-resurrecting-finalizers.md) — the patch
  that restores `WeakCallbackType::kFinalizer`, removed upstream right after
  10.3.22, with its invariants and test plan.
- [The optional-module placeholder](knowledge/optional-module-placeholder.md) —
  why the V8 14.9 rebase reinstated the machinery #412 removed, and the
  consistent way to remove it if that was the intent. Needs review.
