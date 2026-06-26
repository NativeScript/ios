# Quarantined runtime tests

A few specs in the runtime suite (`TestRunner`) are skipped at the harness level
via a `specFilter` in
`TestRunner/app/Infrastructure/Jasmine/jasmine-2.0.1/boot.js`
(`QUARANTINED_SPEC_SUBSTRINGS`). They are matched by substring against each
spec's full name. This file records *why* and *how to re-enable* each one.

Quarantining here touches only the test app — it does **not** edit the shared
`common-runtime-tests-app` submodule.

---

## 1. `TNS Workers` → "no crash during or after runtime teardown on iOS"

**Symptom:** the whole suite hangs (~600s, no JUnit report) on the CI runner;
passes on multi-core dev machines.

**Root cause:** an **AB–BA deadlock between two V8 isolate locks**, captured from
native stacks of the hung app:

- Main thread holds the *main* isolate lock and, while posting a `'send-to-worker'`
  `NSNotification`, synchronously runs a worker's `queue:nil` observer block →
  blocks acquiring the *worker* isolate lock.
- A worker thread holds *its* isolate lock and, loading its entry script, triggers
  a main-isolate-defined class's `+initialize`
  (`ClassBuilder::RegisterNativeTypeScriptExtendsFunction`) → blocks acquiring the
  *main* isolate lock.

It only manifests when those two windows overlap, which is reliable on
constrained CI cores and essentially never on fast hardware.

**Tracking:** https://github.com/NativeScript/ios/issues/397
**Re-enable when:** the cross-isolate lock-ordering is fixed (see the issue for
the two candidate fix directions).

---

## 2. `HTTP ESM Loader` → "HMR hot.data" and "URL Key Canonicalization" describes

(8 specs: `should expose import.meta.hot.data and stable API`, `should share
hot.data across …` ×3, `preserves query for non-dev/public URLs`, `drops
t/v/import for NativeScript dev endpoints`, `sorts query params for NativeScript
dev endpoints`, `ignores URL fragments for cache identity`.)

**Symptom:** each spec times out; the dynamic `import()` of an `http://127.0.0.1:<port>/…`
URL never resolves. (Previously masked by quarantine #1 hanging the suite first.)

**Root cause — a TEST-HARNESS limitation, not a loader bug.** Instrumented runs
(`logScriptLoading`) show **0 successful fetches** to the in-runner Embassy test
server: it *accepts* the connection but never delivers a response, so every GET
hits the loader's ~5s client timeout (×2 with retry).

The runtime's HTTP module loader fetches **synchronously via the deprecated
`NSURLConnection`** (`HMRSupport.mm`). For those accepted sockets the Embassy
server's `getPeerName()` returns **EINVAL** — the exact crash originally seen at
`DefaultHTTPServer.swift:87` — and the socket can't be served. The JUnit POST
works only because it uses `NSURLSession`. The Embassy server is an IPv6 socket
(`sockaddr_in6`) bound to an IPv4 address, the likely culprit for the
`NSURLConnection`-specific breakage.

**The loader itself is fine** — it correctly resolves, fetches, retries, and
fails gracefully; it works against real dev servers. Only the in-runner test
server can't serve these requests.

**Harness changes already in place** (so re-enabling is mostly removing the
filter once the server is fixed):
- `DefaultHTTPServer.handleNewConnection` tolerates `getPeerName()` failure and
  serves the connection with a placeholder peer (instead of crashing/dropping).
- `TCPSocket.ignoreSigPipe` get/set no longer `assert()` on
  getsockopt/setsockopt failure — a half-dead loader socket made
  `setsockopt(SO_NOSIGPIPE)` fail with EINVAL, and the assert trapped (live in
  the Debug runner build) → `_assertionFailure` aborted the whole run
  ("Executed 0 tests"). Now best-effort.
- `Transport.handleRead`/`handleWrite` tear the connection down
  (`closedByPeer()`) on any unexpected recv/send error instead of `fatalError`,
  for the same reason: those sockets reach `Transport` once `getPeerName`/
  `ignoreSigPipe` stopped trapping, and the next event-loop read/write on a
  dead socket would otherwise crash the runner.
- `/esm/timeout.mjs` responds via a non-blocking `loop.call(withDelay:)` instead
  of `Thread.sleep` (which wedged the single-threaded server).
- The server also serves the `/ns/m/…` hot-data aliases and `/ns/core` bridge
  endpoints the identity specs import.

**Re-enable when:** the Embassy test server reliably answers the runtime's
synchronous (`NSURLConnection`) GET — e.g. fix the IPv6/IPv4 socket handling, or
replace the in-runner server with a GCD/Network.framework listener for these
specs.
