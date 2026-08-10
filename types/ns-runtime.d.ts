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
  }

  /**
   * Sets a runtime config key.
   *
   * Throws `TypeError` on an unknown key, an invalid value, or — for
   * process-wide keys such as `releasedObjectPolicy` — when called from a
   * worker isolate.
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
}
