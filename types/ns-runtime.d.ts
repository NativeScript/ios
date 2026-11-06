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
}
