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
}
