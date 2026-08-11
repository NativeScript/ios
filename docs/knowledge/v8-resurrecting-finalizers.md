# Restoring resurrecting finalizers on V8 14.9

Status: **exercised by the runtime suite** (904 tests, 0 failures); the flag-driven stress
scenarios below are still unrun
Patch: [`v8_resurrecting_finalizers.patch`](v8_resurrecting_finalizers.patch) — 6 files, +184/-3,
against V8 **14.9.207.39** (`branch-heads/14.9`). The patch and the pinned
version live in [NativeScript/v8-buildscripts](https://github.com/NativeScript/v8-buildscripts).
Built clean for `arm64-iphonesimulator` (lite mode, no sandbox, no pointer compression).

Also applies unmodified to 14.4, 14.5 and 14.6; on 14.8+ the `heap-symbols.h` hunk needs
re-alignment (whitespace only).

## Why

`ObjectManager::FinalizerCallback` ([ObjectManager.mm:34](NativeScript/runtime/ObjectManager.mm#L34))
reads the dying object's internal fields and may **refuse** disposal by re-arming its
handle (`ClearWeak()` + `SetWeak()`). That requires `v8::WeakCallbackType::kFinalizer`,
which upstream removed one day after our pinned 10.3.22:

| Change | Commit | Landed in |
|---|---|---|
| `kFinalizer` API removed | `2ae2aa92` | ~10.3.24 |
| GC machinery removed | `cb92ed09` | ~10.3.27 |
| Node state machine simplified | `015632a0` | ~10.3.46 |

On stock 14.x the pattern is not merely unsupported but fatal: the handle slot is zapped
to `0xCA11` before the callback runs, and `CHECK_WITH_MSG(Node::FREE == node->state(), ...)`
crashes if a callback re-arms instead of resetting. Re-arming a `kParameter` handle is not
a workaround — that callback only fires once V8 has already committed to the object's death.

This patch exists to buy time: it keeps the current ownership semantics working on a modern
V8 while the reachability-based redesign in
[RESURRECTION_TO_REACHABILITY.md](RESURRECTION_TO_REACHABILITY.md) is proven out. It is
deliberately **narrower** than what upstream removed.

## Scope: major GC only

Upstream supported finalizers in both young and full GC. This patch does not.

- **Young GC (scavenger + minor mark-sweep): finalizer handles are strong roots.** They are
  visited by `IterateYoungStrongAndDependentRoots()` and skipped by `ProcessWeakYoungObjects()`.
  A young collection never finalizes; it just promotes. Collection is deferred to the next
  full GC.
- **Full GC: the keep-alive pass runs**, objects are queued, and callbacks fire after the pause.

This is what deletes the hardest part of a faithful revert. Upstream's young-generation
hooks lived in `MinorMarkCompactCollector`, which no longer exists (replaced by
`minor-mark-sweep.cc`), so a faithful port would have had to re-derive them. Both young
collectors call the same two `GlobalHandles` entry points, so treating finalizers as strong
is one change covering both, and `scavenger.cc` / `minor-mark-sweep.cc` are untouched.

## How it works

**1. Keep-alive** (`mark-compact.cc`, end of `MarkLiveObjects()`). After the final marking
closure, `IdentifyDeadFinalizerHandles()` queues every finalizer handle whose object is
unmarked, `IterateFinalizerHandlesAsRoots()` visits them, and the marking closure
(`MarkTransitiveClosureFixpoint()`, falling back to `MarkTransitiveClosureLinear()`)
re-drains the worklists.

**2. Pending bit** (`global-handles.cc`). A queued node carries a `pending_finalizer` flag
(bit 5 of `flags_`, previously unused) and is added to `pending_finalizers_`. While set, the
node is visited by `IterateStrongRoots()`, and re-identification is suppressed. The bit —
not the queue — is the source of truth: entries are re-checked before invocation, because GC
epilogue callbacks run before the drain and may reset a queued handle out from under it.

**3. Post-pause invocation** (`GlobalHandles::PostGarbageCollectionProcessing`). Callbacks
run from the GC epilogue via `InvokeExternalCallbacks` — *not* from the first-pass phantom
path, which runs in-pause and forbids allocation. The drain is wrapped in
`AllowJavascriptExecution`; see below for why that is required rather than incidental.

**4. Lifting `DisallowJavascriptExecution`.** `Heap::CollectGarbage` holds one across the
*entire* collection, epilogue included — `heap.cc`, "JS execution is not allowed in any of
the callbacks" — and `InvokeExternalCallbacks()` re-enables allocation
(`AllowGarbageCollection`) but deliberately not JS, asserting on entry that JS is disallowed.
Entering JS from a callback therefore hits

```cpp
// src/execution/execution.cc, Invoke()
if (!AllowJavascriptExecution::IsAllowed(isolate)) {
  GRACEFUL_FATAL("Invoke in DisallowJavascriptExecutionScope");
}
```

and aborts the process. **This is a behavioural change from 10.3**, where
`InvokeSecondPassPhantomCallbacks()` ran under an explicit `AllowJavascriptExecution`.

The runtime depends on the 10.3 behaviour and cannot avoid it:
`ObjectManager::FinalizerCallback` → `DisposeValue` → `[target release]` runs `-dealloc`, and
any JS-backed override that teardown reaches — a JS `UIView` subclass being removed from its
superview, a delegate, a block — re-enters JS through `ArgConverter::MethodCallback`. So the
patch lifts the scope around the finalizer drain **only**: `InvokeSecondPassPhantomCallbacks()`
below it still asserts JS is disallowed, so the scope is closed before it runs.

Both scopes are live in release builds. Only the `…DebugOnly` aliases generated in
`assert-scope.h` compile away, and neither `Heap::CollectGarbage` nor this patch uses those.

The Android runtime shares this patch but does not depend on the lift: its finalizer makes a
single runtime-internal JNI call (`makeInstanceWeakAndCheckIfAlive`) and Java has no
synchronous destructor that could re-enter JS.

The public enum gains a third value; `api.cc` needs no change (it passes the type through,
and the only switch is in `Node::MakeWeak`).

## Invariants

These are the things that make it correct. Breaking any of them is a use-after-free, not a leak.

1. **The keep-alive must run at the end of `MarkLiveObjects()`, inside the cppgc atomic pause.**
   Not in `ClearNonLiveReferences()`. At the chosen point the cppgc marker is still live
   (`CppHeap::FinishMarkingAndProcessWeakness()` has not run), so the re-drained closure
   still pushes to cppgc via `VisitCppHeapPointer` → `AdvanceMarking`. A resurrected wrapper whose
   JS properties reach cppgc-managed objects therefore marks correctly. Moving this block after
   `CollectGarbage:534` silently drops those pushes and sweeps live cppgc objects.

2. **The keep-alive must precede all weakness processing.** Everything that consumes liveness —
   phantom handles, ephemerons, `WeakRef`/`FinalizationRegistry`, map-transition pruning, code
   flushing — lives in `ClearNonLiveReferences()`, which runs after. Every such pass must observe
   the resurrected closure as live.

3. **The pending bit must never survive into a reallocated node.** Cleared in `ClearImplFields()`
   (release path), `ClearWeakness()` and both `MakeWeak()` overloads (re-arm path). A freed node
   carries a zapped location; visiting it as a root would crash.

4. **A finalizer callback must reset or re-arm its handle.** Enforced by `CHECK_WITH_MSG` after
   invocation. Doing neither leaves the handle rooted forever.

Two supporting facts, verified in 14.9 and worth re-checking on any upgrade: marking iterates
global handles via `IterateStrongRoots` (`SkipRoot::kWeak`), so pending nodes are protected
during a nested GC; root *updating* uses `IterateAllRoots`, a single pass over `NORMAL||WEAK`,
so a pending node's slot is updated exactly once after evacuation.

## Deliberate deviations from upstream's original

- **No `PENDING` state, no `NEAR_DEATH` for finalizers.** 14.9's `NodeState` is 2 bits with all
  four values used; a separate flag bit avoids widening it, and keeps finalizer nodes out of the
  `NEAR_DEATH` accounting in `UpdateListOfYoungNodesImpl()`.
- **Pending nodes are strong roots, not weak retainers.** Upstream left a `NEAR_DEATH` finalizer
  node weak while its callback ran, which leaves the object unprotected against a GC nested
  inside the callback. Rooting it is stricter.
- **`ResetWeakNodeIfDead()` reports finalizer handles alive rather than `UNREACHABLE()`.**
  Client isolates of a shared space get their own `IterateWeakRootsForPhantomHandles()` pass
  (`mark-compact.cc:3166`) that the keep-alive does not cover. Reporting alive defers collection
  by a cycle in that exotic case instead of crashing.
- **`Node::PostGarbageCollectionProcessing` keeps upstream's name deliberately.**
  `tools/cfi/ignores.txt` blocklists `*GlobalHandles*PostGarbageCollectionProcessing*` because
  `weak_callback_` is invoked on the wrong type. Renaming it breaks CFI builds.

## Known hazard: a finalized object can outlive its native half

`IdentifyDeadFinalizerHandles()` snapshots the dead set *before* `IterateFinalizerHandlesAsRoots()`
and the re-drain, so the queue is built against pre-resurrection marking. If two wrappers are
both JS-unreachable and one references the other, **both** are queued:

- `n1` holds `n2`; neither is reachable from a JS root, so both are queued.
- The keep-alive marks `n1`'s whole closure — `n2` included — live, so nothing is swept.
- `n2`'s callback runs first and disposes: `[N2 release]`, wrapper deleted.
- `n1`'s callback finds `IsGcProtected()` and re-arms.

`n1` comes back holding a JS object whose native half is gone. `DisposeValue` does neuter the
husk (`delete wrapper` then `tns::DeleteValue`, which sets internal field 0 to `Undefined`), so
it is not a dangling `BaseDataWrapper*` — but consumers that read the field without checking,
`Pointer.cpp` among them, will read `Undefined` as an `External` and dereference it.

**This is not fixable by deferring the release or by re-checking liveness after the drain.**
Every queued node is rooted by `IterateFinalizerHandlesAsRoots()` and treated as a strong
retainer for the rest of the cycle, so immediately after the GC *every* disposed object still
looks alive; the check cannot separate "alive because a referrer revived" from "alive because
it was rooted for its own finalization". Waiting a cycle does not converge either: `n1` re-arms
weak, so the next `IdentifyDeadFinalizerHandles()` finds both unmarked again and re-queues the
same pair.

Nor is it fixable by making `GcProtect()` a strong root instead of a disposal veto. Disposal
here is driven by whether *native* still needs the object, not by JS reachability, and that is
precisely what lets a JS↔ObjC cycle collect at all: an unprotected object is released even
though surviving JS still references it. Turning protection into an opaque strong root would
convert every such cycle into a permanent leak.

The real fix is to stop expressing liveness with roots and express it by *tracing* — `CppHeap`,
`v8::Object::Wrap`/`Unwrap`, `TracedReference` and cppgc `Trace()`, which mark *through* the
embedder graph and so collect cross-heap cycles without resurrection. That is
[RESURRECTION_TO_REACHABILITY.md](RESURRECTION_TO_REACHABILITY.md). Note that the intermediate
option is gone: `EmbedderRootsHandler::IsRoot()`, which used to let an embedder declare a
`TracedReference` a root per-GC, no longer exists in 14.9 — only `ResetRoot`/`TryResetRoot`
remain.

Until then, the husk has defined behaviour: `tns::GetValueOrReport()` (Helpers) applies
the `releasedObjectPolicy` runtime config (ns:runtime, docs/ns-builtin-modules.md) on a
missing wrapper — default `"report"` no-ops the operation and fires the
`releasednativeaccess` global event with the touch site's stack; `"throw"` raises a
catchable JS `ReferenceError` — and every internal-field read that could otherwise see a
neutered field goes through it — `Pointer.cpp`'s methods, `ExtVector.cpp` toString,
`Interop::SetStructPropertyValue` (both struct cases), `MetadataBuilder::GetStructData` and
both struct property interceptors, the two `InteropTypes.mm` argument readers, and the
`Reference.cpp` accessors (`SetValueCallback`, `GetWrappedPointer`, `GetDataPair` → indexed
get/set, toString). Regression spec: *"throws instead of crashing when touching a released
object through a resurrected parent"* in `GCFinalizerTests.js`.

Two facts worth knowing when reasoning about which objects can husk:

- `Pointer`/`interop.alloc` objects never husk at runtime — `Caches::PointerInstances`
  holds them behind strong persistents, so their finalizers cannot fire. Struct instances
  and `Reference`s are held only by their own weak finalizer handle and do husk.
- Only the TypeScript `__extends` path installs the retain/release swizzles that drive
  `GcProtect()`; a class from plain `.extend()` is never protected, so its instances are
  disposed rather than resurrected when natively retained.

## Verified so far

- **Runs.** The TestRunner suite is green against the patched V8 — 904 tests, 0 failures,
  0 errors, 11 skipped — including the GC tests named at the end of the next section.
- **Compiles.** Full V8 build for `arm64-iphonesimulator` at 14.9.207.39, exit 0, no warnings
  in the patched files.
- Applies cleanly to pristine 14.9.207.39.
- Public API surface compiles: a standalone TU using `SetWeak(..., kFinalizer)`, `Get()` inside
  the callback, and both the re-arm and reset paths passes `clang++ -fsyntax-only -std=c++20`.
- Adds no clang-format violations (mark-compact.cc's 30 are pre-existing).
- No exhaustive switch over `WeakCallbackType` exists outside `Node::MakeWeak`, so adding the
  enum value breaks no other translation unit.

## Still unverified

The runtime suite passes against the patched V8, which drives the resurrection path in anger —
see *"Worker instance should not be garbage collected if the worker thread is alive"* below.
Everything in this section is narrower: it needs a V8 run under specific flags, and the suite's
default configuration reaches none of it.

1. **Re-running the marking closure after `EnterProcessGlobalAtomicPause()`.** The
   closure is asserted empty at that point and this patch pushes new roots and re-drives it. The
   `CHECK(IsCppHeapMarkingFinished(...))` after the second drain is the tripwire. Run under
   `--stress-incremental-marking` and `--stress-concurrent-marking`. **Highest-value test.**
2. **Resurrect-then-rearm, end to end.** A finalizer that re-arms N times then resets, across
   repeated `--expose-gc` major GCs, under `--verify-heap`. Confirms the callback site, the
   un-zapped slot through `MakeWeak`'s `CHECK_NE(object_, kGlobalHandleZapValue)`, and the
   `CHECK_WITH_MSG` contract.
3. **Resurrected object reaching a cppgc object.** Give a resurrected wrapper a JS property
   chain to a cppgc-managed wrapper and confirm it is not swept. This is invariant 1's test; it
   is the failure mode with no loud assertion.
4. **Young-generation path.** A finalizer handle on a young object: confirm scavenge promotes it
   rather than finalizing, and that `IncrementNodesDiedInNewSpace` accounting stays sane.
5. **Nested GC inside a finalizer callback.** Allocate heavily in the callback; confirm no
   double-invocation and no collection of the object under inspection.

The runtime's existing GC tests are the acceptance gate for the patch as the runtime uses it,
and they pass — in particular *"Worker instance should not be garbage collected if the worker
thread is alive"*, which exercises the `WorkerWrapper` resurrection site directly.

## Upgrade cost

Every V8 bump requires re-checking the four invariants above, since three of them are about
*where* the block sits relative to phases that upstream reorders freely. This is intermediate
scaffolding with a real carrying cost — it is cheaper than a faithful revert, not free.
