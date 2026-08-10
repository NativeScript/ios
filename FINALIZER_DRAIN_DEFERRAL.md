# Deferring the finalizer drain out of the GC epilogue

Status: **DEFERRED** — not implemented. The husk-hardening (`tns::GetValueOrReport`) and
the `IterateFinalizerHandlesAsRoots` pending-bit guard were prioritized instead as the
likely fixes for the field crash (BLACKOUT-V3-IOS-41/42,
`ConcurrentMarkingVisitor::RecordSlot` / `MainMarkingVisitor::RecordSlot`, fault addresses
all `<256 KiB page base> | 1`). This note records the design and its constraints for when
the drain move is picked up.

Background: [docs/knowledge/v8-resurrecting-finalizers.md](docs/knowledge/v8-resurrecting-finalizers.md).
Today `GlobalHandles::InvokeFinalizerCallbacks()` runs inside the GC epilogue
(`PostGarbageCollectionProcessing`), under an `AllowJavascriptExecution` lift, because
finalizers re-enter JS (`DisposeValue` → `-dealloc` → JS overrides). The proposal was to
run the drain from a posted foreground task instead, deleting the lift and the whole
"JS + nested GC inside `Heap::CollectGarbage`" hazard class.

## Why it was deferred: "cycles are resolved by early release"

The concern: JS↔ObjC cycles (wrapper W owns native N; N natively retains a JS-backed
object that leads back to W) only collect because disposal is driven by **native retain
count**, not JS reachability — W's finalizer releases N even though surviving JS may still
reach W, and the release cascade is what unwinds the cycle.

**Analysis: deferral does not change those semantics.** The same callbacks make the same
protect/release decisions; only *when* they run changes. A deferred drain still releases
N, N's dealloc still drops its retains, and the next GC still queues the newly
unprotected handles. Cycle resolution is latency-shifted (one runloop turn per cascade
step, worst case), not broken.

What genuinely depends on the drain being synchronous with the GC is **promptness**, in
exactly two scenarios:

1. **Memory pressure.** `Heap::CollectAllAvailableGarbage` loops up to 7 attempts until
   nothing more frees. With the epilogue drain, each round's finalizers release native
   memory *inside the loop*, so round N+1 reclaims what round N unblocked. Deferred,
   every pending finalizer is a strong root, rounds 2–7 free nothing native, and no
   native memory is released until the runloop turns — under a jetsam-adjacent memory
   warning that latency can kill the process.
2. **Long synchronous JS.** Allocation-pressure full GCs during a heavy synchronous
   stretch never reach the runloop; pending finalizers pile up as strong roots and
   interop temporaries are unreclaimable until the JS yields.

Steady-state disposal latency (one extra turn) is invisible.

## The design to revisit: hybrid, mirroring upstream

V8 already encodes this exact trade-off for second-pass phantom callbacks, ten lines
below our drain (`global-handles.cc:1002` @ 14.9.207.39):

```cpp
const bool synchronous_second_pass =
    isolate_->MemorySaverModeEnabled() || v8_flags.predictable ||
    isolate_->heap()->IsTearingDown() ||
    (gc_callback_flags &
     (kGCCallbackFlagForced | kGCCallbackFlagCollectAllAvailableGarbage |
      kGCCallbackFlagSynchronousPhantomCallbackProcessing)) != 0;
```

Mirror it for the finalizer drain:

- **Default: defer** to a posted foreground task. The drain then runs in an ordinary JS
  context — no `AllowJavascriptExecution` lift, no nested-GC-inside-the-epilogue.
- **Synchronous (keeping the lift) only when V8 itself goes synchronous**:
  `kGCCallbackFlagCollectAllAvailableGarbage`, teardown, and *debatably*
  `kGCCallbackFlagForced`.

### Caveats

- **`gc()` always passes `kGCCallbackFlagForced`** (`gc-extension.cc:204`), and the
  Blackout app currently calls `gc()` from a timer (`Utils.queueGC`) — every crash stack
  in the field goes through `GCExtension::GC`. If plain Forced stays on the synchronous
  path, the hazardous epilogue drain remains the *hot* path in production. Either exclude
  plain Forced from the sync set (a `gc()` caller cannot observe native release
  synchronously anyway — nothing reachable from JS dies), or pair the change with
  removing the app-side `gc()` timer.
- **Scenario 2 (sync-JS starvation) needs its own trigger** if it matters in practice:
  `Isolate::RequestInterrupt` fires at JS safepoints on the JS thread, where JS execution
  is legal (the inspector's pause-on-interrupt runs a nested message loop from there).
  Post a task *and* an interrupt; whichever fires first drains. Needs separate
  validation: stack-depth headroom for `-dealloc` → JS chains, reentrancy. Follow-up,
  not a blocker.
- **The `IterateFinalizerHandlesAsRoots()` pending-bit guard is load-bearing here, not
  hardening.** Deferral widens the window between queueing and draining to a full
  runloop turn of arbitrary JS; any GC in that window iterates `pending_finalizers_`
  and must skip entries whose bit was cleared (freed or re-armed nodes). The patch
  already skips and compacts stale entries — keep that behaviour when reworking the
  drain.
- **Teardown** needs a synchronous final drain (`~Runtime` / `DisposeAllRegistered`).
- Ordering relative to second-pass callbacks and Heap epilogue callbacks changes;
  nothing known to depend on it, but re-check when implementing.

## What this does NOT fix

- The **husk hazard** (a finalized object outliving its native half — the n1→n2 pair in
  the knowledge doc). That is created at `IdentifyDeadFinalizerHandles()` snapshot time,
  before any drain, and is unaffected by drain timing. The checked-accessor hardening in
  the runtime is the fix for that, and is the prime suspect for the field crash.
- Anything the reachability redesign
  ([RESURRECTION_TO_REACHABILITY.md](RESURRECTION_TO_REACHABILITY.md)) addresses. That
  remains the endgame — tracing collects cycles without early release at all — and this
  hybrid is compatible scaffolding until then.

## Validation plan when picked up

1. TestRunner suite green with the drain deferred (default path).
2. A memory-pressure test: allocate wrapper-heavy garbage, trigger
   `CollectAllAvailableGarbage` (low-memory notification), assert native memory is
   reclaimed without a runloop turn.
3. Worker teardown specs (synchronous final drain).
4. Soak on a checked V8 build (`dcheck_always_on=true v8_enable_verify_heap=true`) with
   `--verify-heap --stress-incremental-marking --stress-concurrent-marking`.
