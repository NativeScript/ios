# `ns:` builtin modules

Cross-runtime contract for exposing runtime-provided modules to application
code. This document is the specification both the iOS and Android runtimes
implement; a capability must behave identically on both platforms before it
ships in a stable release.

## The scheme

Builtin modules live under the URL-style `ns:` scheme, mirroring Node's
`node:` prefix:

```js
// CommonJS
const util = require("ns:util");

// ES modules
import util, { inspect } from "ns:util";
const util2 = await import("ns:util");
```

Rules:

- `ns:` specifiers are resolved by the runtime **before any filesystem or
  npm resolution**. They can never be shadowed by a file, a path mapping, or
  a package — and conversely, a file named `ns:util` is not reachable.
- Resolution of an unknown builtin fails synchronously with an `Error` whose
  message is exactly `No such built-in module: ns:<name>` (matching Node's
  wording for familiarity).
- A builtin module is a **singleton per JS realm** (main context and each
  worker get their own instance). `require("ns:util")` twice returns the same
  object; the CJS exports object and the ESM namespace expose the same
  underlying values (ESM additionally provides the exports object as
  `default`).
- There is no bare-specifier fallback: `require("util")` is **not** an alias
  for `require("ns:util")`. The unprefixed name continues to resolve to npm
  packages as it always has.
- Builtin exports are frozen. Apps patch behavior by wrapping, not by
  mutating the runtime's module.

## Modules

### `ns:util` (v1)

| export | description |
|---|---|
| `inspect(value[, options])` | Formats any value for human consumption: depth-limited, output-capped, cycle-safe, never invokes getters (except a guarded `error.stack` read and custom `toString` overrides, which are honored). `options.depth` (number) overrides the default depth of 2. Other option keys are reserved. |
| `format(fmt, ...args)` | Node-style printf formatting: `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%O`, `%%`. Extra arguments are appended space-separated, objects rendered via `inspect`. When `fmt` is not a string or contains no substitutions, all arguments are formatted and joined with spaces. `console.*` routes its arguments through this, so `console.log("%d apples", 3)` works. |

**Stability caveat (verbatim from Node's contract):** the output of `inspect`
(and therefore `format`'s object rendering) may change between runtime
versions for readability; it is intended for humans and must not be parsed
programmatically.

### `ns:runtime` (v1)

Runtime-level configuration. Keys, value domains, and scope are defined and
validated natively; the module surface is a thin frozen wrapper.

| export | description |
|---|---|
| `setConfig(key, value)` | Sets a runtime config key. Throws `TypeError` on an unknown key, an invalid value, or (for process-wide keys) when called from a worker isolate. |
| `getConfig(key)` | Returns the current value of a config key. Throws `TypeError` on an unknown key. Readable from any isolate. |

Config keys:

| key | values | scope | default |
|---|---|---|---|
| `releasedObjectPolicy` | `"report"` \| `"throw"` | process-wide (main-isolate writes only; read live by every isolate) | `"report"` |
| `debug` | comma-separated category list, e.g. `"esm,fetch"` | process-wide (main-isolate writes only; read live by every isolate) | the `NS_DEBUG` environment variable, or `""` |

Remote-module security (`security.allowRemoteModules`,
`security.remoteModuleAllowlist`) is **not** part of this surface. Those
values are read once from nativescript.config / package.json the first time
the HTTP loader gates a fetch, and they cannot be inspected or changed
through `getConfig` / `setConfig`.

`releasedObjectPolicy` controls what happens when JS touches a wrapper whose
native counterpart has already been released (a state a resurrected object can
expose — see the iOS runtime's `docs/knowledge/v8-resurrecting-finalizers.md`):

- `"report"` (default): the operation no-ops — reads produce `undefined`,
  writes are skipped, `toString` yields a `<Pointer: released>`-style
  placeholder — and a cancelable `releasednativeaccess` event fires on
  `globalThis` (`event.error` carries a `ReferenceError` whose stack names the
  touch site; `event.operation` names the API surface, e.g.
  `"struct field assignment"`). Reports are deduplicated per released object.
  In debug builds the event's default action is a `console.warn`; a listener
  that handles the report suppresses it with `preventDefault()`.
- `"throw"`: the touch throws a catchable `ReferenceError` synchronously, and
  no event fires.

`debug` turns on the runtime's category-scoped trace logs. Categories:

| category | covers |
|---|---|
| `esm` | module resolution, compilation, linking, evaluation, registry keying |
| `fetch` | the HTTP module transport (one line per fetched URL — high volume) |
| `registry` | registry invalidation and dynamic-import cache bookkeeping |

Each write replaces the whole set, so `setConfig('debug', '')` disables
tracing and no caller needs to know what was already on. `getConfig('debug')`
returns the canonical comma-separated list of what is enabled. Unknown names
are ignored, with one warning line naming the valid ones.

The same list can be given before boot as the `NS_DEBUG` environment variable
(`NS_DEBUG=esm,fetch`), which is the only way to trace boot itself. Traces are
compiled into release builds as well: a release build that cannot be traced is
a release build that cannot be diagnosed. Lines are written to the unified log
under subsystem `org.nativescript.runtime` with the category as the os_log
category, so `log stream` can filter them without matching message text.

### `ns:module` (v1)

The module-loader control surface consumed by development tooling
(`@nativescript/vite`). Mechanism only: every policy concern (boot
orchestration, `import.meta.hot`, full reload, CSS apply, worker teardown,
WebSocket protocol) lives in the tooling. See `HMR_RUNTIME_BOUNDARY.md` for
the full contract rationale.

| export | description |
|---|---|
| `configureLoader(config)` | Install loader policy before the session imports anything: `importMap` (bare specifier → URL, consulted inside the synchronous resolver), `volatilePatterns` (URL substrings always re-fetched), `canonicalization` (`stripParams`/`forPathPrefixes`/`preserveQueryFor` vocabulary for registry keying). Each present section replaces its state wholesale. |
| `invalidateModules(urls)` | Evict the given URLs (canonicalized) from the module registry and mark them bust-next-fetch, so the next network fetch bypasses every HTTP cache layer. |
| `getLoadedModuleUrls()` | URL-like keys currently in the module registry (used to compute full-reload eviction sets). |
| `createRequire(filenameOrURL)` | A `require` resolving against `filenameOrURL`'s directory (a trailing slash names the directory itself). Accepts an absolute path string, a `file:` URL string, or a URL object; anything else throws a `TypeError`, and an `http(s)` base is refused outright because `require()` of a dev-served module is not supported — import those. ES module graphs load under Node's `require(esm)` rule: a graph containing top-level await is refused before it evaluates. |
| `createPumpingRequire(filenameOrURL)` | Same argument contract and same resolution, but an ES module graph with top-level await is evaluated by driving V8's nestable tasks and microtasks until it settles, instead of being refused. **Callable only from a task context** — see below. It never advances the Cocoa runloop, so a graph awaiting a native transport still cannot settle here and fails on the deadline rather than returning a half-initialized namespace. Reach for it only where a synchronous boundary must consume an async module. |

`createPumpingRequire` pumps the loop, and the loop cannot be pumped
re-entrantly: V8 ignores a microtask checkpoint while the isolate is already
draining the microtask queue. A top-level await resumes through a promise
reaction — a microtask — so such a graph can never settle from inside a
microtask turn. Requiring one from after an `await` or inside a `.then`
callback therefore throws immediately, before evaluation, leaving the graph
instantiated so `import()` can still load it. Call it from a task context
instead — a native boundary, an event handler, a timer callback, or module
evaluation itself. A **synchronous** graph needs no pumping and stays legal
from anywhere, microtask turns included.

Not implemented on either require: `require.resolve`, `require.cache`, and
`require.main`. They are absent rather than throwing, so a feature check
works; adding them is a spec change here first.

Debug builds additionally carry `canonicalizeHttpUrlKey(url)`, a pure test
diagnostic; release builds omit it. Missing members are simply absent —
never present-but-throwing — so feature checks work. The module is
registered in every build; the security boundary for remote module loading
sits at the network layer (`security.allowRemoteModules` in
nativescript.config, enforced inside `HttpLoader`), not the module
registry and not `ns:runtime` getConfig/setConfig.

Note: `ns:module` (loader policy, structured, boot-time) is deliberately
separate from `ns:runtime` (live key-value runtime flags, `setConfig`/
`getConfig`).

## `node:` compatibility shims

The same registry serves the `node:` scheme with **compatibility shims** so
npm packages that require Node builtins by their prefixed names can run
unmodified where a shim exists:

- A shim implements a documented **subset** of the corresponding Node module's
  API, backed by `ns:` modules. Unimplemented members are simply absent
  (so `typeof util.promisify === "function"` feature-checks behave
  correctly); they are never present-but-throwing.
- **One source file per specifier.** A shim is its own module that consumes
  the `ns:` module it adapts through the internal require, and it owns *all*
  the adaptation — argument shapes, option names, aliases, anything that has
  to track Node. A standard `ns:` module never contains compatibility code
  and never knows a shim exists.
- Shims are **lazy**: a shim's source is only evaluated when its specifier is
  first resolved, so an app that never touches the `node:` scheme never pays
  for one.
- `node:` modules with no shim fail with the same error shape:
  `No such built-in module: node:<name>`.
- **Bare specifiers are untouched**: `require("util")` resolves through npm
  as it always has (many apps bundle the `util` polyfill package). Only the
  explicit `node:` prefix reaches the shim registry, so existing apps cannot
  break. Bundler-level aliases (webpack/rollup) continue to work and take
  precedence at build time.
- A shim is always a **distinct module object** from any `ns:` module, even
  when every member is re-exported unchanged. `ns:` modules may grow runtime-specific
  members freely; a `node:` shim only ever gains members that track Node's
  actual API. This mirrors how Bun (`bun:*`), Deno (`Deno.*`/JSR) and
  Cloudflare (`cloudflare:*`) all keep their own surface strictly apart from
  their `node:` compat layer.
- Shims ship on both runtimes under the same parity rule as `ns:` modules.

### v1 shims

| module | exports | notes |
|---|---|---|
| `node:util` | `inspect`, `format` | Re-exports `ns:util`'s members unchanged (`nodeUtil.inspect === nsUtil.inspect`) from a **distinct, separately frozen module object**. Documented as partial. |
| `node:url` | `fileURLToPath`, `pathToFileURL` | Node-strict converters between `file:` URLs and paths. Parsing goes through the URL intrinsic, so `file://localhost/x` is accepted (the URL spec folds a `localhost` authority to none) while any other host throws, and the query and fragment are not part of the path. `fileURLToPath` rejects a non-`file:` scheme and rejects `%2F` in the path rather than decoding a separator into it. `pathToFileURL` returns a real `URL` and requires an **absolute** path: Node resolves a relative one against the process working directory, and there is no such thing here. Documented as partial — no `URL`/`URLSearchParams` re-exports (both are globals), no legacy `url.parse`/`format`/`resolve`. |
| `node:module` | `createRequire` | Re-exports `ns:module`'s `createRequire` unchanged from a **distinct, separately frozen module object**. `createPumpingRequire` is deliberately absent: it has no Node counterpart, so code written against this shim keeps running on Node. `require.resolve`/`.cache`/`.main` are not implemented, and neither is any other `node:module` member (`Module`, `builtinModules`, `isBuiltin`, `register`, `syncBuiltinESMExports`). Documented as partial. |

Candidates for future shims, in rough order of ecosystem demand:
`node:events` (EventEmitter), `node:path` (pure JS), `node:buffer`,
`node:process` (subset). Each requires a spec update here first.

## The internal require

Builtin modules reach each other — and only each other — through an internal
`require` the runtime provides to every builtin source:

- It resolves **builtin specifiers only**. A path, a package name or any other
  specifier is not reachable from a builtin; an unregistered builtin name
  throws the same `No such built-in module: <specifier>` an app sees.
- It materializes the target module on first use and returns the realm's
  singleton afterwards, which is what makes shims lazy.
- Requiring a module that is still being built throws rather than recursing,
  so a dependency cycle between builtins is a loud error and not a hang.

This is the mechanism shims are built on, so it is normative: both runtimes
provide it.

## Adding a builtin module

- The name is a short, lowercase identifier (`ns:util`, `ns:timers`, ...).
- One module, one source file, one registry entry — including shims.
- New modules and new exports require this document to be updated first and
  an implementation on both runtimes before a stable release; a module may
  ship on one platform behind a documented "experimental, iOS-only" (or
  Android-only) note in between.
- Internal runtime machinery must never be reachable through the scheme:
  the registry distinguishes public modules from internal builtins, and only
  public ones resolve (Node's `canBeRequiredByUsers` split).

## Source-text modules: deliberately not supported

Builtins are classic function bodies, not ES modules, on both runtimes. If
cross-builtin code sharing is ever needed, the first answer is bundling at
generation time (author as ESM, emit function bodies); runtime source-text
builtin modules (Node's `kSourceTextModule`) are justified only by a concrete
need for live module semantics (TLA, live bindings, cyclic imports), which no
current or planned builtin has. Revisit here before building either.

## iOS implementation notes (non-normative)

Builtin modules are function-body builtins (`NativeScript/runtime/js/`,
see the README there) compiled via the RuntimeBuiltins table. The `ns:`
resolver intercepts specifiers in the CommonJS require path and in the ES
module resolve/dynamic-import callbacks; ESM consumption is served by a
synthetic module whose exports are populated from the same per-realm exports
object. The internal require is a fixed parameter of the builtin function
wrapper (`exports`, `require`, `module`, `binding`, `primordials`).
