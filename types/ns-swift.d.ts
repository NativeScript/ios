declare module "ns:swift" {
  /**
   * The Swift modules whose declarations are in the program, by module name.
   * The metadata generator's `swift!<Module>.d.ts` files add one entry each,
   * typed as their `ns:swift/<Module>` module.
   */
  export interface SwiftModules {}

  export interface SwiftModuleInfo {
    readonly name: string;
    /** The generation unit the module's thunks belong to. */
    readonly unit: string;
    /** Changes whenever the module's registered surface changes. */
    readonly fingerprint: string;
    /** Interop ABI the module's thunks were generated for. */
    readonly abiVersion: number;
    /** Number of registered members. */
    readonly members: number;
  }

  /** Interop ABI the runtime implements. */
  export const abiVersion: number;

  /**
   * A Swift module's types, functions and variables (the same object
   * `ns:swift/<name>` exports). Throws when the app does not link the
   * module's generated thunks.
   */
  export function module<Name extends keyof SwiftModules>(name: Name): SwiftModules[Name];
  export function module(name: string): unknown;

  export function info(name: string): SwiftModuleInfo;

  /**
   * Runs `read`, then calls `onChange` once, when an `@Observable` property
   * `read` accessed is about to change (Swift's `withObservationTracking`).
   * Needs iOS 17 and a loaded Swift module.
   */
  export function track(read: () => void, onChange: () => void): void;

  /**
   * Calls `onChange` after each change to the `@Observable` properties
   * `read` accesses, re-reading them every time. Returns a function that
   * stops observing.
   */
  export function observe(read: () => void, onChange: () => void): () => void;
}

/**
 * Async Swift members take an optional trailing AbortSignal: aborting rejects
 * the call's Promise with the signal's reason and cancels the Swift task.
 * Declared here for programs without the DOM library; it merges with it.
 */
interface AbortSignal {
  readonly aborted: boolean;
  readonly reason: any;
}
