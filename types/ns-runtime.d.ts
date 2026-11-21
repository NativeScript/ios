declare module "ns:runtime" {
  /**
   * Controls what happens when JS touches a wrapper whose native counterpart
   * has already been released:
   *
   * - `"report"` (default): the operation no-ops and a cancelable
   *   `releasednativeaccess` event fires on `globalThis`.
   * - `"throw"`: the touch throws a catchable `ReferenceError` synchronously,
   *   and no event fires.
   */
  export type ReleasedObjectPolicy = "report" | "throw";

  /**
   * The config keys these types know about, mapped to their value domains.
   *
   * Keys are registered and validated natively, and other runtimes (or newer
   * runtime versions) may register keys not listed here — `setConfig` and
   * `getConfig` therefore accept any string key, falling back to `unknown`
   * for the value. A runtime's own types can merge additional keys into this
   * interface via declaration merging.
   */
  export interface RuntimeConfig {
    releasedObjectPolicy: ReleasedObjectPolicy;
    /**
     * The enabled debug-trace categories, as a comma-separated list — the
     * whole set is replaced on every write, so `""` disables tracing.
     * `getConfig` returns the canonical list of what is currently on.
     * Unknown names are ignored with one warning line.
     *
     * Also settable before boot through the `NS_DEBUG` environment variable.
     * Available in release builds too. Process-wide; main-isolate writes only.
     */
    debug: string;
    /**
     * Whether the runtime logs a warning (once per class) when JS properties
     * on a native object's wrapper are lost because the wrapper was garbage
     * collected while native code still owned the object.
     *
     * Defaults to on in debug builds and off otherwise; the app config key
     * `"wrapperLifetime": { "warnings": boolean }` overrides the default.
     * Process-wide; main-isolate writes only.
     */
    wrapperLifetimeWarnings: boolean;
    /**
     * How ObjC object wrappers live, from the app config
     * `"wrapperLifetime": { "mode": ... }`. Read-only: `setConfig` throws.
     *
     * - `"resurrecting"` (default): a collected wrapper whose JS-extended
     *   object native code still retains is resurrected by its finalizer.
     * - `"rooted"`: no resurrection. A wrapper in scope stays a strong root
     *   while something other than the runtime retains its object, and is
     *   weak otherwise; native objects of collected wrappers are released on
     *   the runtime's thread.
     * - `"canary"`: no resurrection. A wrapper in scope dies with its JS
     *   references; JS properties set on it, including ones that shadow a
     *   prototype member (a rebound JS method, or a native method where
     *   `wrapperLifetimeAllowShadowingNativeMembers` lets one be assigned), are
     *   also copied to a state object kept until the native object is
     *   deallocated, and a wrapper built for the object later gets them back
     *   with their attributes while that state object lives. An object that
     *   is not JS-extended is tracked through an associated token, so
     *   `objc_removeAssociatedObjects` on it lets its state object go while
     *   it lives, and one whose class forbids associated objects (or, under
     *   the alternative death signal, refuses weak references) gets none.
     *   Native property writes still reach the native setter. Writes cost more than in the other modes; reads do not.
     *   WeakMap, WeakSet, WeakRef and FinalizationRegistry key such native
     *   objects by their lifetime in this mode, so they carry over too; a
     *   WeakMap value that references its own native key keeps that object
     *   alive while the map lives. Native `#private` fields and index-keyed
     *   properties do not.
     *   State that references its own object keeps that object alive.
     */
    wrapperLifetimeMode: "resurrecting" | "rooted" | "canary";
    /**
     * Which wrappers `"rooted"` roots, or `"canary"` makes canaries, from the app config
     * `"wrapperLifetime": { "scope": ... }`. Read-only: `setConfig` throws.
     *
     * - `"extended"` (default): instances of JS-extended classes.
     * - `"all"`: every ObjC object wrapper except blocks and tagged pointers.
     */
    wrapperLifetimeScope: "extended" | "all";
    /**
     * From the app config `"wrapperLifetime": { "allowShadowingNativeMembers": ... }`,
     * `false` by default. Read-only: `setConfig` throws.
     *
     * In debug builds under the `"rooted"` and `"canary"` modes, assigning a
     * native instance method's name (or `toString`, or an NSArray's
     * `Symbol.iterator`) on a native object throws a `TypeError`, since native
     * code never calls a JS own property of a native object; `true` turns that
     * off. Those members are then accessor pairs on their class's prototype.
     * Release builds and the `"resurrecting"` mode never throw.
     */
    wrapperLifetimeAllowShadowingNativeMembers: boolean;
  }

  /**
   * Wrapper lifetime counters for the calling isolate, maintained in every
   * build.
   */
  export interface WrapperLifetimeStats {
    /** Finalizers that kept a wrapper alive because native code still retained its object. */
    resurrections: number;
    /** Finalizers that released their native object. */
    collected: number;
    /** Native objects released through `__releaseNativeCounterpart`. */
    releasedExplicitly: number;
    /** Times JS passed a released wrapper to native code, called a method on it, or touched a released pointer, reference or struct. */
    releasedAccesses: number;
    /** Collected wrappers with JS properties whose object was still retained elsewhere. */
    stateLostCandidates: number;
    /** Candidates whose object was still alive a runloop turn later, once queued releases ran (warnings enabled only). */
    stateLostConfirmed: number;
    /** `"rooted"` only: weak wrappers made strong because native code retained their object. */
    promotions: number;
    /** `"rooted"` only: strong wrappers made weak because native code let go of their object. */
    demotions: number;
    /** `"rooted"` and `"canary"`: collected wrappers whose native object was queued for release. */
    queuedReleases: number;
    /** `"canary"` only: state objects created for native objects' JS properties. */
    canaryStates: number;
    /** `"canary"` only: state objects let go of because their native object was deallocated, or because `objc_removeAssociatedObjects` released its lifecycle token. */
    canaryNativeDeaths: number;
    /** `"canary"` only: writes to canaries the runtime's write handler saw. */
    canaryInterceptedWrites: number;
  }

  /** Live native object wrappers of one class in the calling isolate. */
  export interface WrapperClassCounts {
    /** JS wrappers the runtime holds a retain for. */
    wrappers: number;
    /** `"rooted"` only: wrappers currently strong because native code owns their object. */
    strong: number;
    /** `"canary"` only: native objects whose JS properties live on a state object. */
    states: number;
  }

  export interface LeakCycleOptions {
    /**
     * Also report cycles through objects whose retain count is lower than the
     * references found to them (some found reference does not own), marked
     * `uncertain`. Off by default: such objects are treated as externally owned.
     * Every cycle the default run finds on the same heap is reported as well.
     */
    strict?: boolean;
    /** Class-name prefixes whose native objects the report details in `inspected`. */
    inspect?: string[];
  }

  export interface LeakCycle {
    /**
     * The cycle rotated canonically, with addresses, V8 ids, element indices and
     * storage offsets removed: stable across runs.
     */
    signature: string;
    /** The cycle in the same rotation as `signature`, with those details kept. */
    path: string;
    /** Native objects on the cycle, and the objects of wrappers on it. */
    members: { className: string; address: string }[];
    /**
     * The cycle passes an object freed while the probe ran, or, in strict mode,
     * one whose retains the graph over-explains; `reasons` names each.
     */
    uncertain: boolean;
    reasons: string[];
  }

  export interface LeakCycleReport {
    mode: "resurrecting" | "rooted" | "canary";
    scope: "extended" | "all";
    strict: boolean;
    cycles: LeakCycle[];
    /** Native objects in the graph: wrapped ones, ones with state, and what they own. */
    nativeObjects: number;
    /** Native objects whose retain count is lower than the references found to them. */
    uncertainNativeObjects: number;
    /**
     * Native objects freed (or freed and replaced) by other threads while the
     * probe ran. They keep the references found before they changed, are never
     * treated as owned from outside, and a cycle through one is marked
     * `uncertain`.
     */
    changedNativeObjects: number;
    /** Up to 50 of them, with the reference that led to each. */
    changed: { className: string; address: string; seed: boolean; depth: number; foundFrom: string }[];
    /** The native graph hit its 200,000-object limit; cycles past it are not seen. */
    truncated: boolean;
    /** Where the walk stopped short; cycles past these limits are not seen. */
    cutOffs: {
      /** Native objects 8 references from a wrapped one, not expanded. */
      depth: number;
      /** Storage blocks read only up to 64 KB, and one object's storage up to 256 KB in all. */
      storage: number;
      /** Cycles longer than 64 hops, not reported. */
      cycleLength: number;
    };
    /** Layouts read instead of scanned, as measured in this process. */
    calibrated: {
      /** `CALayer`'s unretained superlayer, and delegate when it has none, are skipped. */
      layer: boolean;
      /** Only the live range of an `NSMutableArray`'s storage is read. */
      mutableArray: boolean;
    };
    snapshotNodes: number;
    snapshotMs: number;
    analysisMs: number;
    inspected?: {
      className: string;
      address: string;
      seed: boolean;
      retainCount: number;
      /**
       * No retain count readable without messaging the class, or without the
       * object possibly being freed meanwhile: owned from outside.
       */
      retainCountUnknown: boolean;
      runtimeRetains: number;
      incoming: number;
      out: string;
      root: boolean;
      jsBlock: boolean;
      reached: boolean;
      reachedFrom: string;
    }[];
  }

  /**
   * Sets a runtime config key.
   *
   * Throws `TypeError` on an unknown key, an invalid value, or — for
   * process-wide keys such as `releasedObjectPolicy` — when called from a
   * worker isolate. Remote-module security (`security.allowRemoteModules`,
   * `security.remoteModuleAllowlist`) is not a runtime config key: it is
   * read once from nativescript.config at boot and cannot be changed here.
   */
  export function setConfig<K extends keyof RuntimeConfig | (string & {})>(
    key: K,
    value: K extends keyof RuntimeConfig ? RuntimeConfig[K] : unknown
  ): void;

  /**
   * Returns the current value of a config key. Readable from any isolate.
   *
   * Throws `TypeError` on an unknown key.
   */
  export function getConfig<K extends keyof RuntimeConfig | (string & {})>(
    key: K
  ): K extends keyof RuntimeConfig ? RuntimeConfig[K] : unknown;

  /**
   * Marks `error` to cross the next JS-to-native boundary as a native
   * exception instead of being reported in JS: `throw escapeException(e)`
   * inside a native callback reaches the native caller's `@try/@catch`, with
   * the original `NSException` when `e` carries one. Returns an `Error`
   * (message and stack copied), so the throw also behaves normally in pure-JS
   * paths. An already-escaped value is returned unchanged; calling with no
   * argument throws `TypeError`.
   */
  export function escapeException(error: unknown): Error;

  /**
   * Reports `bytes` of native memory held by `target` (a native object,
   * pointer, reference, block or function reference) to the garbage
   * collector, replacing any earlier size; `0` clears it. The charge is
   * returned when `target` is collected or released. Throws `TypeError` for
   * any other value and `RangeError` for a byte count outside `0`–`2^34`.
   */
  export function setExternalSize(target: object, bytes: number): void;

  /**
   * The size last reported for `target` through `setExternalSize` or by the
   * runtime itself, `0` when there is none.
   */
  export function getExternalSize(target: unknown): number;

  /**
   * Wrapper lifetime counters for the calling isolate. The state-lost
   * counters only advance while `wrapperLifetimeWarnings` is on.
   */
  export function getWrapperLifetimeStats(): WrapperLifetimeStats;

  /**
   * Live wrappers per native class name in the calling isolate.
   *
   * @throws {Error} When the app does not embed `NativeScriptLeakProbe.framework`,
   * which app templates embed in debug builds only; list it in
   * `NS_SHIP_DEBUG_FRAMEWORKS` to ship it in other builds.
   */
  export function getWrapperClassCounts(): Record<string, WrapperClassCounts>;

  /**
   * Takes a heap snapshot of the calling isolate and reports JS <-> native
   * reference cycles that keep native objects alive: what the `"rooted"` and
   * `"canary"` wrapper lifetime modes leak, and JS blocks whose callback
   * reaches their owner in every mode. Slow (a full snapshot plus a native
   * object graph walk); meant for diagnostics, not production paths.
   *
   * What it cannot read counts as owned from outside, so those cycles are
   * missed rather than misreported: among others, the contents of
   * `NSHashTable`, `NSMapTable` and `NSPointerArray`. Before iOS 26, UIKit's
   * gesture environment retains every recognizer attached to a view, so a
   * cycle through a view's gesture recognizer is not reported, even when
   * strict (seen on iOS 18.5; iOS 26.3 reports it).
   *
   * @throws {Error} When the app does not embed `NativeScriptLeakProbe.framework`,
   * which app templates embed in debug builds only; list it in
   * `NS_SHIP_DEBUG_FRAMEWORKS` to ship it in other builds.
   */
  export function findLeakCycles(options?: LeakCycleOptions): LeakCycleReport;
}
