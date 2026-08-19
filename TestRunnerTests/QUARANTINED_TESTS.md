# Quarantined runtime tests

Specs in the runtime suite (`TestRunner`) can be skipped at the harness level
via a `specFilter` in
`TestRunner/app/Infrastructure/Jasmine/jasmine-2.0.1/boot.js`
(`QUARANTINED_SPEC_SUBSTRINGS`), matched by substring against each spec's full
name. Quarantining touches only the test app — it does **not** edit the shared
`common-runtime-tests-app` submodule. When adding an entry, record *why* and
*how to re-enable* it here.

The list is currently **empty**. Previously quarantined and since resolved:

- **`TNS Workers` → "no crash during or after runtime teardown on iOS"** — the
  AB–BA cross-isolate `v8::Locker` deadlock between a worker's `+initialize`
  and the main isolate's `send-to-worker` notification path
  ([#420](https://github.com/NativeScript/ios/issues/420)); fixed by
  serializing extended-class allocate/register and scoping worker-created
  extended class names to their isolate
  ([#428](https://github.com/NativeScript/ios/pull/428)).
- **`URL Key Canonicalization` HTTP-identity specs** and the background-thread
  HTTP import spec — the vendored in-runner Embassy server never answered the
  app's module GETs (half-dead accepted sockets, `getPeerName` EINVAL). The
  server was replaced with `ModuleTestServer` (Network.framework `NWListener`),
  which serves them.
