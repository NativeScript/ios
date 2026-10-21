declare module "ns:swift" {
  /**
   * The Swift modules whose declarations are in the program, by module name.
   * The metadata generator's `swift!<Module>.d.ts` files add one entry each,
   * typed as their `ns:swift/<Module>` module.
   */
  export interface SwiftModules {}

  export interface SwiftModuleInfo {
    readonly name: string;
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
}
