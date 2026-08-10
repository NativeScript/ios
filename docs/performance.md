# Performance API

The runtime implements the WHATWG/WinterTC Performance surface: [High
Resolution Time](https://w3c.github.io/hr-time/), [User Timing Level
3](https://w3c.github.io/user-timing/) and the [Performance
Timeline](https://w3c.github.io/performance-timeline/) with
`PerformanceObserver`.

## Surface

Globals (own, writable, enumerable, configurable properties of `globalThis`,
in main and worker isolates alike): `performance`, `Performance`,
`PerformanceEntry`, `PerformanceMark`, `PerformanceMeasure`,
`PerformanceObserver`, `PerformanceObserverEntryList`.

- `performance.now()` — double milliseconds since the isolate's time origin,
  monotonic (V8 platform clock, `mach_absolute_time`-based: it does not tick
  while the device is asleep), full double precision with no coarsening.
- `performance.timeOrigin` — readonly accessor; wall-clock milliseconds since
  the Unix epoch, sampled once when the isolate's runtime is created. Each
  worker gets its own time origin at worker-thread start, so
  `timeOrigin + now()` tracks `Date.now()` per isolate.
- `performance.toJSON()`, `Symbol.toStringTag`, and `Performance extends
  EventTarget` per spec; `performance`, `PerformanceEntry`,
  `PerformanceMeasure` and `PerformanceObserverEntryList` are not
  user-constructible (`new` throws `TypeError`); `new PerformanceMark(name,
  options)` is constructible per spec but does not buffer the entry.
- User timing: `mark(name, {startTime, detail})`, `measure(name,
  startOrOptions, endMark)` with the full Level 3 options algebra (`{start,
  end, duration, detail}`, mark names or timestamps, over-/under-constraint
  errors), `clearMarks(name?)`, `clearMeasures(name?)`.
- Timeline: `getEntries()`, `getEntriesByType(type)`, `getEntriesByName(name,
  type?)` return copies sorted chronologically by `startTime` (stable for
  ties).
- Observers: `new PerformanceObserver(cb)`, `observe({entryTypes})` or
  `observe({type, buffered})`, `disconnect()`, `takeRecords()`, static frozen
  `PerformanceObserver.supportedEntryTypes === ["mark", "measure"]`.

## Architecture

All spec logic lives in the `internal/performance.js` builtin
(`NativeScript/runtime/js/performance.js`), which is deliberately portable:
the native side hands it only `{ now(), timeOrigin }`, so the same file is
meant to be reused unchanged by the Android runtime against an equivalent
binding bag.

The native clock is owned by `Runtime` (`Runtime::PerformanceNowMillis()`,
`Runtime::TimeOriginMillis()`, captured in `Runtime::CreateIsolate`) and
exposed to native callers through `tns::Performance::NowMillis(isolate)`
(`NativeScript/runtime/Performance.h`). Any future native producer of
JS-visible timestamps — `requestAnimationFrame` in particular — must read the
clock through that hook rather than sampling its own, so every timestamp
shares `performance.timeOrigin` as its base.

## Deviations from the specs

- **`detail` is held by reference.** The runtime has no `structuredClone`, so
  `mark`/`measure` `detail` values are stored as-is. Mutating the object later
  is visible through the entry, and entries retain whatever `detail`
  references until `clearMarks()`/`clearMeasures()`.
- **Buffers are unbounded.** Per spec for user timing, but combined with
  by-reference `detail` it means a long-lived app marking in a loop should
  clear entries periodically.
- **Observer callbacks run from a microtask**, not a queued task: delivery is
  asynchronous relative to `mark()`/`measure()` but precedes timer callbacks
  scheduled in the same turn. Callback exceptions are routed to
  `reportError`, so one throwing observer does not starve the others.
- **No `DOMException`.** Errors the specs express as `DOMException` — the
  `SyntaxError` for a missing mark name, the `InvalidModificationError` for
  switching an observer between the `entryTypes` and `type` forms — are
  `Error` instances with `name` patched. `err.name` checks work;
  `instanceof DOMException` does not.
- Browser-only surface is absent: no resource/navigation timing, no
  `eventCounts`, and no `PerformanceTiming`-attribute resolution in
  `measure()`.
