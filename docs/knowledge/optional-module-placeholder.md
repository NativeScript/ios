# The optional-module placeholder — restored after the V8 14.9 rebase

**Status: needs review with @edusperoni (author of #412).** This branch
deliberately reinstates code that #412 removed. If the removal was intentional,
this document is the argument to overturn — delete the machinery *and* the test
and doc that still describe it, in one change.

**Update (2026-07-29): the import()-side branch was removed again, this time
deliberately.** The simplification pass
([hmr-simplification-pass.md](hmr-simplification-pass.md) §2) split the
question in two: on the ESM side a missing bare specifier now rejects
outright — optionality is `try { await import(x) } catch {}` at the call
site, and in dev sessions an import-map miss must fail loudly — while the
require() side below, where the placeholder's lazy-throw contract is
app-visible shipped behavior, stands exactly as this document describes and
still needs Ed's call. The decision rule applied: remove first, and let a
real-world reproduction argue it back in with evidence.

## What was restored

`feat!: upgrade V8 to 14.9.207.39` (0e89474) deleted the whole optional-module
mechanism:

| Symbol | File | Restored as |
|---|---|---|
| `IsLikelyOptionalModule` | `ModuleInternal.{h,mm}` | one shared definition (was two drifting copies) |
| `ModuleInternal::CreatePlaceholderModule` | `ModuleInternal.mm` | rewritten to pass the message as a V8 string, not interpolated source |
| `require()` call sites | `ModuleInternal::LoadImpl`, `ModuleInternal::ResolvePath` | restored |
| `import()` placeholder branch | `ModuleInternalCallbacks.mm` resolver | restored |

## Why the removal looks unintentional rather than decided

Three things on `main` contradict each other, all landed by the same commit:

1. **The test that asserts the behaviour is still there and still runs.**
   `TestRunner/app/tests/NodeBuiltinsAndOptionalModulesTests.mjs` contains
   *"creates an in-memory placeholder for likely-optional modules"*, which
   `await import("__ns_optional_test_module__")` and expects property access on
   the namespace's default export to throw. `index.js:94` still requires the
   file. With the implementation gone that import rejects with
   `Cannot find module '__ns_optional_test_module__'`, so the spec fails.

2. **#412's own migration notes say the logic was left alone.**
   `docs/knowledge/v8-14-migration.md` (§ Test status) reports the suite at
   *904 specs, 892 passing, 1 failing* and explains the one failure —
   `TNS require :: should throw error if cant find node module` — like this:

   > `IsLikelyOptionalModule()` treats any bare specifier without a path
   > separator as optional, so `require('nonExistingFileName.js')` yields a
   > lazily-throwing placeholder rather than throwing […] That logic is
   > version-independent and predates this work […] so it is **left alone here**
   > rather than changed as a side effect of the V8 upgrade.

   The code was not left alone; it was deleted. The doc still describes the
   pre-deletion behaviour, which means the deletion post-dates the notes and was
   never reflected back into them.

3. **Deleting the feature is a behaviour change in a commit scoped to a
   toolchain upgrade.** Optional dependencies that resolve to a placeholder
   instead of throwing is an app-visible contract. 0e89474 touches 457 files;
   a contract change of this kind is easy to lose in it.

## Why this branch keeps it rather than adopting the deletion

The failing spec #412 was reacting to is real, but the placeholder was not its
cause — the heuristic's *breadth* was. `IsLikelyOptionalModule` treated any bare
specifier as optional purely from the absence of a leading `.`/`~`/`/`, so
`require('nonExistingFileName.js')` — an explicit file reference — got a
placeholder instead of failing.

This branch fixes that directly: a bare specifier ending in `.js`, `.mjs`,
`.cjs`, `.json`, `.node` or `.ts` is excluded from the heuristic, because real
npm package names do not carry a file extension. `require('foo.js')` throws;
`require('lodash.debounce')` still gets a placeholder. That makes
`should throw error if cant find node module` pass **without** dropping optional
modules. The known trade-off is the small set of real packages whose names end
in an extension — `video.js` is the notable one — which now hard-fail rather
than deferring; the parity tests in
`NodeBuiltinsAndOptionalModulesTests.mjs` pin both sides of that boundary
explicitly.

So both branches make the same spec green. This one keeps the feature and the
existing test; #412's approach drops the feature and leaves a test asserting it.

## What was *not* carried over from the pre-rebase branch

Two deliberate departures, both adopting `main`'s decisions:

- **Error text.** `main` standardised on `Cannot find module '<name>'`
  (matching Node) over the old `Module not found: '<name>'`. Kept.
- **No debug-mode swallowing.** The pre-rebase code returned an empty
  `MaybeLocal` without throwing when `RuntimeConfig.IsDebug`, in the polyfill-
  and placeholder-creation failure paths. `main` removed that pattern across the
  resolver; returning empty without a pending exception leaves V8 to report a
  less useful failure. The restored branch always throws. No test covered the
  debug-only path.

## If the removal *was* intentional

Then the consistent version of it is:

1. Delete `IsLikelyOptionalModule`, `CreatePlaceholderModule`, and both call
   sites (as #412 did).
2. Delete the *"creates an in-memory placeholder for likely-optional modules"*
   spec and, if nothing else in the file survives, its `index.js` require.
3. Correct the § Test status paragraph in
   `docs/knowledge/v8-14-migration.md`, which currently documents behaviour that
   no longer exists.
4. Decide what apps carrying optional dependencies do instead — this is the part
   that needs a real answer before the feature goes, and the reason this branch
   did not make that call unilaterally.
