#!/usr/bin/env bash
# Background hang sampler for CI.
#
# The runtime unit-test suite has intermittently DEADLOCKED on the constrained
# CI runner (a worker-teardown lock cycle that does not reproduce on
# many-core dev machines). When that happens the app stays alive but the JS
# thread is wedged, so nothing is POSTed and the watchdog fails at 600s — with
# no native stack to explain WHY. NativeScript's console.log goes to stdout (not
# os_log), so the unified-log archive doesn't capture it either.
#
# This script periodically `sample`s the TestRunner *app* process while the test
# runs, leaving per-thread native backtraces behind. If the suite hangs, the
# later snapshots show every thread's stack (main blocked on a lock + whatever
# the worker threads are doing) — i.e. the actual lock cycle. The files are
# written into the diagnostics dir that the workflow uploads as `test-diagnostics`.
#
# Best-effort: it never fails the build, and it exits on its own (the Xcode test
# step also kills it via a trap when xcodebuild returns). `sample` needs no sudo.
set -u

DIAG="${1:?usage: sample-hung-app.sh <diagnostics-dir>}"
mkdir -p "$DIAG"

# ~25 minutes of coverage: build (~6m) + the test phase including a full 600s
# hang + teardown. pgrep finds nothing during the build, so those ticks no-op.
for i in $(seq 1 25); do
  sleep 60
  # Exact-name match: the app is "TestRunner"; the XCUITest host is
  # "TestRunnerTests-Runner" — we want the app, where the JS thread lives.
  pid="$(pgrep -x TestRunner 2>/dev/null | head -1 || true)"
  [ -z "${pid:-}" ] && continue
  out="$DIAG/sample-app-$(printf '%02d' "$i").txt"
  # 4s sample of all threads. -mayDie tolerates the process exiting mid-sample.
  sample "$pid" 4 -mayDie -fullPaths -file "$out" >/dev/null 2>&1 || true
done

exit 0
