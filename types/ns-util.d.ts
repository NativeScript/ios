declare module "ns:util" {
  export interface InspectOptions {
    /** Recursion depth for nested objects. Default: `2`. */
    depth?: number;
  }

  /**
   * Formats any value for human consumption: depth-limited, output-capped,
   * cycle-safe, and never invokes getters (except a guarded `error.stack`
   * read and custom `toString` overrides, which are honored).
   *
   * The output may change between runtime versions for readability; it is
   * intended for humans and must not be parsed programmatically.
   */
  export function inspect(value: unknown, options?: InspectOptions): string;

  /**
   * Node-style printf formatting: `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%O`,
   * `%%`. Extra arguments are appended space-separated, objects rendered via
   * {@link inspect}. When `format` is not a string or contains no
   * substitutions, all arguments are formatted and joined with spaces.
   *
   * `console.*` routes its arguments through this.
   */
  export function format(format?: unknown, ...args: unknown[]): string;

  export interface TextEncoderInstance {
    readonly encoding: "utf-8";
    encode(input?: string): Uint8Array;
    encodeInto(
      source: string,
      destination: Uint8Array
    ): { read: number; written: number };
  }

  export interface TextDecoderInstance {
    readonly encoding: string;
    readonly fatal: boolean;
    readonly ignoreBOM: boolean;
    decode(
      input?: ArrayBuffer | ArrayBufferView | null,
      options?: { stream?: boolean }
    ): string;
  }

  /**
   * The WHATWG `TextEncoder`, which is the very object the global of that name
   * holds: `require("ns:util").TextEncoder === globalThis.TextEncoder`. The
   * members are declared here rather than taken from `globalThis` so the
   * declaration stands on its own, without a DOM lib in the program.
   */
  export const TextEncoder: { new (): TextEncoderInstance };

  /** The WHATWG `TextDecoder`, likewise identical to the global. */
  export const TextDecoder: {
    new (
      label?: string,
      options?: { fatal?: boolean; ignoreBOM?: boolean }
    ): TextDecoderInstance;
  };
}
