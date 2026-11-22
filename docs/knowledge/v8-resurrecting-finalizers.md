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

## Which thread releases the native object

Finalizers run on whichever thread triggered the collection, and that can be any thread holding
the isolate's Locker — a JS function dispatched to a background queue included. An object that
first reached JS on the runtime's thread (`ObjCDataWrapper`/`BlockWrapper::BornOnRuntimeThread`,
recorded when the wrapper is built) is released on that thread: off it, `ObjectManager` queues
the native release (`[object release]`, `Block_release`) and posts one event loop task to drain
the queue; the JS side is disposed immediately either way. The same applies to
`__releaseNativeCounterpart` called from such a thread: the wrapper is retired at once, the
object a loop turn later. Objects that first reached JS on another thread are released where the
collection runs, as are collection adapters, whose `-dealloc` retires the wrapper.

The queue needs no synchronization of its own: finalizers, `__releaseNativeCounterpart`, the
drain task, wrapper creation and teardown all hold the Locker. A new wrapper built for an object
whose release is still queued takes that release over (keeping the retain counts the extended
classes' swizzle reads exact). Teardown drains the queue inline, since the event loop has stopped
by then. For a worker, the runtime's thread is the worker's own thread, not the main thread.

While a release is queued the object is alive without a wrapper, where an inline release would
have deallocated it and zeroed the weak references to it. A native callback reaching it in that
window (a delegate method through a weak reference) builds a new wrapper, which takes the queued
release over: the JS override runs on a blank `this`, without the state the collected wrapper
held, and the object then lives as long as that new wrapper. Only an object that nothing but its
wrapper owned, collected off the runtime's thread, has this window.

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
husk (`delete wrapper`, then internal field 0 is overwritten), so it is not a dangling
`BaseDataWrapper*` — but consumers that read the field without checking, `Pointer.cpp` among
them, would read it as an `External` and dereference it. ObjC object husks get a per-isolate
`tns::ReleasedReason` Symbol in the field (`tns::MarkReleased`: collected, released explicitly
through `__releaseNativeCounterpart`, teardown, or a receiver lent to JS from `-dealloc`);
other wrapper types get `Undefined`. `tns::GetValue` only reads `External`s, so both read as
"no wrapper". The reason is matched by identity, not as a number: URL, URLSearchParams,
URLPattern and MessagePort keep a raw aligned pointer in field 0, which reads back as a Smi
in builds without pointer compression.

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
both struct field accessors, the two `InteropTypes.mm` argument readers, and the
`Reference.cpp` accessors (`SetValueCallback`, `GetWrappedPointer`, `GetDataPair` → indexed
get/set, toString). Regression spec: *"throws instead of crashing when touching a released
object through a resurrected parent"* in `GCFinalizerTests.js`.

An ObjC object husk reaching native code where an object is expected used to fall through to a
`DictionaryAdapter` standing in for it (a released `UIColor` reached UIKit as one and raised
`unrecognized selector`). The `ReleasedReason` marker now catches it on those paths, through
`tns::ReportReleasedObject()` with the same policy: an argument (`Interop::WriteValue`) becomes
`nil` or throws before the call (`tns::ThrowReleasedObject`); a collection element (`Interop::ToObject`) becomes `NSNull`; a JS-implemented
method's return value (`ArgConverter::SetValue`) becomes `nil` (both report only, since native
code is on the stack); a method or property call on the husk (`ArgConverter::Invoke`, Proxy
receivers included) always throws. `ns:runtime`'s `getWrapperLifetimeStats()` counts
resurrections, collections, explicit releases and released-object accesses. Specs:
`WrapperLifetimeTests.js`.

The app config `"wrapperLifetime": { "mode": "rooted" }` (`WrapperLifetime.{h,mm}`) avoids the
hazard instead of reporting it. An adopted wrapper never gets a `kFinalizer` callback: it is a
strong root while something other than the runtime retains its object and a phantom
(`kParameter`) weak handle otherwise. Strength is decided by a `-retainCount` scan in a
major-GC prologue, where flipping weakness is legal, and a wrapper is born strong and made
strong again whenever it crosses the JS/native boundary. A JS-unreachable holder therefore
stays rooted with its whole closure for as long as native code owns it, so nothing it reaches
is queued. Phantom callbacks only queue; the native objects are released later on the
runtime's thread, where JS may run. The extended classes' retain/release swizzle is not
installed in this mode. `"scope": "extended"` (default) roots only JS-extended instances;
`"all"` roots every ObjC wrapper except blocks and tagged pointers, at the cost of keeping
JS-referencing native cycles alive (ARC rules: break them with a `WeakRef`). Specs:
`WrapperLifetimeModesTests.js`; CI runs the default mode only, so the rooted expectations run
when the TestRunner app config selects `"mode": "rooted"`.

The state-lost warnings (`wrapperLifetimeWarnings`) watch for resurrecting finalizers and stay
silent in the rooted and canary modes. Under `"scope": "extended"` in the rooted mode, a plain (not JS-extended) wrapper
is a phantom handle that a scavenge can collect, so JS properties set on plain objects that
native code owns are lost without a warning.

`"mode": "canary"` (`WrapperLifetimeCanary.{h,mm}`) is the portable variant, the shape Android and
the Node-API runtimes can implement. A wrapper in scope is a canary: a phantom-weak JS object
that dies with its JS references, releasing the runtime's retain through the same queue.
A masking named interceptor on the instance templates, with only a setter, a deleter and a
definer, mirrors JS properties into a null-prototype state object: each callback copies the
write into the state and declines, so V8 also applies it to the canary. Reads find real own
properties on the canary and never call into C++, so they cost what they cost on a plain
object. Being masking, the callbacks also see names the prototype chain has (a class method
rebound with `this.onTap = this.onTap.bind(this)`, a field called `copy`, any
`Object.defineProperty` over a prototype name), and those are state like any other. The
setter classifies the prototype chain itself, because once it declines V8 adds a new name
to the canary without calling the definer: a name that resolves to an inherited accessor (a
native property, a JS getter/setter) or a read-only data member never becomes state. When the
first object on the chain with the name is a native class prototype that still records a
native setter for it, the handler runs that setter itself
(`MetadataBuilder::TrySetNativeProperty`, the same code as the accessor's setter callback).
Everything else is left to V8: a JS accessor, a read-only member, a native property without a
setter, and a name JS assigned or defined on that prototype, which its own setter and definer
interceptors forget for good. The state is rooted from its first write until the native
object is deallocated (or, with the default death signal below, until its
token is released), and stays the source of truth: a canary built later
for the same object, or the receiver a JS-implemented `-dealloc` runs with, gets the state's
properties copied onto it with their attributes and accessors. The costs, measured on a
Release simulator build: the handler is installed per template, so every write to any ObjC
wrapper goes through the setter, and V8 looks the name up again after it declines. Under
`"extended"`, a plain wrapper's expando write takes about 64 ns instead of 17 and a native
property store about 200 ns instead of 120. On a canary, where the setter also classifies the
name, an expando write takes about 100 ns. A native property store took about 310 ns instead
of 125 (380 instead of 115 four prototypes up) while the handler left it to V8; running the
setter from the handler brings it from about 324 to 289 ns two prototypes up and from 396 to
324 for a `UIButton` `tag` four up (323 to 292 and 392 to 334 under `"all"`, where a plain
`UIButton`'s goes from 322 to 266). Building a canary for an object with state costs
about 330 ns per state property.

That masking handler is what JS-extended instances keep. Under `"scope": "all"`, wrappers of
plain objects get a non-masking forwarding set instead (getter, setter, query, deleter,
enumerator, definer and descriptor), unless `"allowShadowingNativeMembers": true` in the app
config gives them the masking one: the state is the only copy of their properties, every access
to one is answered from it, and a new canary needs no copy. V8 calls a non-masking interceptor
only for names absent from the object and its whole prototype chain, own lookups included
(WebIDL's named-property visibility, `LookupIterator::kSkipNonMaskingOwnProperty`), so native
calls and native property stores never reach C++. ObjC prototypes carry the swizzle interceptor,
which made an own lookup on such a canary stop at the prototype until the prebuilts' patch
`v8_nonmasking_own_lookup` (v8-buildscripts #11): without it `delete obj.m` deleted `m` from the
prototype. The holes are names the chain has: an instance write or `Object.defineProperty` over
an inherited data property (a native method, `toString`, `valueOf`, `constructor`, a member JS put
on a prototype) creates an own property of that canary only, and deleting such a name deletes
nothing. `v8::Object::Set` reports success for a store `[[Set]]` rejects, so the setter checks a
read-only property and a getter-only accessor in the state itself, and runs a state accessor's
setter with the canary as `this`. A record that dies under a live forwarding canary
(`objc_removeAssociatedObjects`) keeps its state while the canary holds it (`ReleaseStates` parks
it in `orphaned`, which the leak probe also walks, and `DropRecord` sweeps once the canary is
collected or released); the canary keeps reading it, and its next write moves the state object
into a new record, so what the weak collections keyed on the object survives too. A released
forwarding canary gets the state's properties copied onto it (`KeepWeakCollectionKey`), since its
handlers no longer reach the state; the handlers answer nothing while that copy runs, or V8 would
find each property already defined and skip it. An accessor kept in the state sees the canary as
`this` whatever the receiver, and a write through a Proxy or an inheriting object never runs its
setter: interceptors are given only the holder, and V8 consults only the query callback when the
holder is not the receiver. Measured on a Release
simulator build (iPhone 16 Pro simulator, jitless), forwarding vs masking for a plain `NSObject`:
an expando read takes 64 ns instead of 19 and a miss 47 instead of 20, `in` 111 instead of 21, an
expando rewrite 81 instead of 105, a first write creating the state 544 instead of 676, a native
property store (`UIView` `tag`) 112 instead of 219, and wrapping an object with five state
properties again costs what wrapping one without state does (903 vs 925 ns) instead of 2496;
native method calls and native property reads are unchanged.

Instances of JS-extended classes report their own
deallocation: the runtime gives each extended class a `-dealloc` that marks the instance's
records dying in every isolate, calls the superclass's (which can be a JS one the class
inherits, whose receiver still reads the state), and then retires them. For other objects it is
a compile-time choice (`NS_CANARY_DEATH_SIGNAL` in `WrapperLifetimeCanary.mm`): by default a
token associated with the
object reports it from its `-dealloc`, immediately and on any thread, but the ObjC runtime aborts
the process for a class that forbids associated objects (Swift actors, for one), and there is no
public query for that. The runtime checks the flag `objc_setAssociatedObject` aborts on
(`RW_FORBIDS_ASSOCIATED_OBJECTS` in the object's class's `class_rw_t`, reached through the
`objc_debug_class_rw_data_mask` libobjc exports for debuggers) before it attaches a token; an
object it flags, or whose class it cannot read, gets no state: its JS properties stay on the
canary and are gone after a replacement, and the weak collections key its wrapper. Code that
calls `objc_removeAssociatedObjects` on a live object releases the token too, which
retires the state as if the object had died: the next write through the canary starts a new
state from the canary's properties, but if the canary dies before such a write, a canary built
later starts without them. The weak collections' key for the object hangs off that state, so
what they keyed on the object is lost with it: `WeakMap` and `WeakSet` lookups miss,
`WeakRef.prototype.deref` returns `undefined`, and once the old key is collected the
`FinalizationRegistry` cleanup for it runs although the object lives. A JS write through the
canary starts a new state but no key; the next `set`, `add`, `new WeakRef` or `register` on the
object makes a new key, and entries keyed on the old one never come back. This stays a
limitation: `objc_removeAssociatedObjects` removes every client's associations, and Apple
documents it as not for general use. The alternative keeps an ObjC weak reference in each record
(`objc_initWeakOrNil`, which declines instead of aborting for classes that refuse weak
references) and sweeps the records after every major collection, so state lingers until then.
An instance of a class that refuses weak references and is not JS-extended gets no state
under it, in the same way. With the default, `"scope": "all"` stays experimental because that
check reads private runtime layout; `"extended"` attaches no tokens at all (the key-only
records below use the weak reference). It cannot be
rooted at canary death instead, because a state reachable only through the canary is garbage in
the same collection. The cost: state that references its own object (a closure over `this`)
keeps it alive. A canary built after a death is a new object, but `===` cannot tell: only one
canary lives at a time, and anything still referencing the old one would have kept it alive.
An explicit release is different: `__releaseNativeCounterpart` drops the object's
`Caches::Instances` entry but not its state, so if the object lives on, the next native return
of it builds a new canary with the state's properties while JS can still hold the released
one, and `===` tells them apart. What the weak collections keyed on the object follows the
object: before the release, `WrapperLifetimeCanary::KeepWeakCollectionKey` copies the key onto
the released canary (a private), so `unwrap` still returns it there, and marks the record
released, so `wrap` returns the object's live canary only once native code handed the object
back (a new canary adopted the record, which clears the mark) and `undefined` until then; it
never builds a canary for a released record, and never returns the released one. A canary
released with no key to copy gets `null` in that private instead, and `unwrap` reports each
weak-collection operation that reaches it as a released-object access (`ReportReleasedObject`). The key
lives while the state or the released canary does. A record whose token
`objc_removeAssociatedObjects` already retired gets neither: the released canary then keys
nothing, as that limitation describes. What could notice is whatever keys on the canary without keeping it. The weak collections
don't: in canary mode a builtin (`js/weak-collections.js`) replaces `WeakMap`, `WeakSet`,
`WeakRef` and `FinalizationRegistry` with subclasses that key a native object (a canary's, or
under `"extended"` a plain object's; not a tagged pointer, a block, or an object of a class
refusing weak references or, for a canary, forbidding associated objects) by an opaque, frozen key held by its state, so entries and targets live
exactly as long as the native object, and `WeakRef.prototype.deref` returns the live wrapper, a new
one, or `undefined` once the object is gone. Lookups never create that key, and a Proxy around a
native object stays a key of its own. Under `"extended"` a plain object's wrapper is a phantom
handle with no handlers and no state, which dies with its JS references just as a canary does, so
the first keying of a plain object (`unwrap` with `create`) gives it a key-only record: a weak
slot and a state holding nothing but the key, counted in `canaryStates` and in the registry's
`records`, so the leak probe walks it like any other state. Nothing is attached to the object: no
token, so no private class layout is read, a class forbidding associated objects is keyed like
any other, and `objc_removeAssociatedObjects` leaves the record alone. Only a class refusing weak
references keeps its wrapper as the key. The record is flagged `plain` and no wrapper holds it:
wrapping a plain object never consults the registry, and `unwrap` finds the record by the
object's address only after the canary lookups miss, behind an atomic count of plain records, so
a weak-collection lookup costs nothing more while no plain object was ever keyed, and canary
adoption skips the registry while every record is plain. `wrap` returns the object's `Instances`
wrapper or builds a plain one (no adoption, no hydration). Death is the weak sweep, whatever
`NS_CANARY_DEATH_SIGNAL` chooses for canaries: a major-GC epilogue posts `SweepPlain` (one atomic
load while there is no plain record), which walks the registry's `plainRecords` list, not the
map, and retires records whose weak slot was zeroed; a lookup that meets a zeroed slot retires
the record at once (`RetireIfDead`). So entries keyed on a dead plain object, and its
`FinalizationRegistry` callbacks, wait until the major collection after its deallocation (and the
key's own collection after that). The sweep bumps no `deref` cache epoch: a live wrapper retains
its object, so no cached wrapper outlives a swept object. Release semantics are the canary ones:
`__releaseNativeCounterpart` on a plain wrapper copies the key, or `null`, onto it
(`KeepPlainWeakCollectionKey`) and marks the record released; since no adoption looks the record
up, `unwrap` or `wrap` meeting a live wrapper of the object clears the mark instead. Limitation:
a native hand-back whose wrapper dies before any weak collection operation sees it leaves the
record released, so `deref` returns `undefined` until a later hand-back reaches `unwrap` or
`wrap`. Limitation: as for canaries, a `WeakMap` value referencing its plain key keeps the object
alive while the map lives, where the wrapper key used to let it go. Measured on a Release
simulator build (medians of launches, ns/op): a `WeakMap` hit on a keyed plain object 142 instead
of 39 (the wrapper was the key), a miss on a never-keyed plain wrapper 124 instead of 106 once any
plain object was keyed and unchanged (107) before, the first keying 870 instead of 154, a
`new WeakRef` of a fresh plain object 1570 instead of 216, and a `deref` that rebuilds a dead
plain wrapper about 1120. A major collection plus the next timer took about 500 µs with 1000
keyed plain objects held against 370 with the same objects unkeyed, the same as a build that
reported their deaths with tokens (540 against 385): the difference is the states and keys on the
heap, and the sweep is below that noise. Creating plain wrappers, native calls, native property
reads and stores, `Instances` lookups and a major collection with no plain record are unchanged. The cost is the other side of the same rooting: a `WeakMap`
value that references its native key keeps the key, its state and so the native object alive for
as long as the map lives, where in the other modes the entry would be collectable. Native `#private` fields are branded on the canary and do not carry over. Other
limits: `Object.freeze`, `seal` and `preventExtensions` throw on a canary (V8 refuses them on
objects with interceptors); index-keyed properties are not mirrored and die with the canary;
a write through an object whose prototype is a canary lands on that object, since
interceptors only see writes made through their own object. Class fields need the V8 fixes
in v8-buildscripts#13: before them, define-semantics fields reach the definer with inverted
attributes (the state keeps them read-only, hidden and undeletable) and, once their
initializer is warm, bypass it entirely (the field stays on the canary and is gone after a
replacement); `v8::Object::CreateDataProperty` bypasses it the same way.

Both modes leak what resurrection used to break early, so `NativeScriptLeakProbe.framework`
(debug builds only; the runtime reaches it through `LeakProbe.{h,mm}` and `LeakProbeSPI.h`)
finds JS ↔ native cycles: `ns:runtime`'s `getWrapperClassCounts()` (live wrappers and states per
class) and `findLeakCycles({ strict })`, which builds an embedder graph into a heap snapshot
(wrapped objects, what they own through strong ivars and collection or block storage, and the
runtime's cross-heap edges) and runs a trial deletion with `-retainCount` as the outside-owner
count. Debug builds also log class growth on memory warnings and answer Darwin notifications;
see "Leak diagnostics" in `docs/ns-builtin-modules.md`. Specs: `WrapperLifetimeLeaksTests.js`.

Two facts worth knowing when reasoning about which objects can husk:

- `Pointer`/`interop.alloc` objects never husk at runtime — `Caches::PointerInstances`
  holds them behind strong persistents, so their finalizers cannot fire. Struct instances
  never husk either: their wrapper and bytes live in an ArrayBuffer backing store held by
  the struct object, so the GC frees them only once nothing (resurrected or not) reaches
  it. `Reference`s are held only by their own weak finalizer handle and do husk.
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

`TestRunner/app/tests/GCFinalizerTests.js` is the acceptance gate for the patch as the runtime
uses it. The Worker wrapper no longer depends on resurrection: a running worker's JS object is a
strong root until its thread ends (`WorkerWrapper::RootWorkerObject`), so the shared test
*"Worker instance should not be garbage collected if the worker thread is alive"* passes through
rooting and never reaches the resurrection branch — it must not be read as evidence that a
re-ported patch works. ObjectManager's refuse-and-re-weaken branch remains only as a fallback.

## Upgrade cost

Every V8 bump requires re-checking the four invariants above, since three of them are about
*where* the block sits relative to phases that upstream reorders freely. This is intermediate
scaffolding with a real carrying cost — it is cheaper than a faithful revert, not free.
