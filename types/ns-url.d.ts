declare module "ns:url" {
  /**
   * The WHATWG `URL` surface the runtime implements. Every component setter
   * stringifies its value.
   */
  export interface URL {
    hash: string;
    host: string;
    hostname: string;
    href: string;
    readonly origin: string;
    password: string;
    pathname: string;
    port: string;
    protocol: string;
    search: string;
    /**
     * The same object on every read, kept in step with `search` in both
     * directions.
     */
    readonly searchParams: URLSearchParams;
    username: string;
    /** Returns `href`. */
    toString(): string;
    /** Returns `href`, so `JSON.stringify` serializes a URL as its href. */
    toJSON(): string;
  }

  /** The WHATWG `URLSearchParams` surface the runtime implements. */
  export interface URLSearchParams {
    readonly size: number;
    append(name: string, value: string): void;
    /** With `value`, removes only the pairs matching both name and value. */
    delete(name: string, value?: string): void;
    get(name: string): string | null;
    getAll(name: string): string[];
    /** With `value`, matches only a pair with both that name and value. */
    has(name: string, value?: string): boolean;
    set(name: string, value: string): void;
    sort(): void;
    forEach<This = undefined>(
      callback: (
        this: This,
        value: string,
        name: string,
        searchParams: URLSearchParams
      ) => void,
      thisArg?: This
    ): void;
    /** The iterators are live: pairs added while iterating are visited. */
    entries(): IterableIterator<[string, string]>;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
    toString(): string;
  }

  /**
   * The runtime's `URL` constructor: the very function the global of that
   * name was created with, however `globalThis.URL` has been reassigned
   * since. A `url` or `base` that does not parse throws a `TypeError`.
   */
  export const URL: {
    readonly prototype: URL;
    new (url: string, base?: string | URL): URL;
    canParse(url: string, base?: string): boolean;
    /**
     * Registers a `Blob` or `File` under a fresh `blob:nativescript/` URL;
     * anything else yields `null`. `ext` records a file extension for the
     * consumers that read the blob back by URL.
     */
    createObjectURL(
      object: object,
      options?: { ext?: string } | null
    ): string | null;
    revokeObjectURL(url: string): void;
  };

  /**
   * The runtime's `URLSearchParams` constructor, the very function the global
   * of that name was created with. `init` is a query string (one leading `?`
   * is ignored), an iterable of name/value pairs (an element that is not
   * exactly a pair throws a `TypeError`), or a record of names to values.
   */
  export const URLSearchParams: {
    readonly prototype: URLSearchParams;
    new (
      init?: string | Iterable<readonly string[]> | Record<string, string>
    ): URLSearchParams;
  };

  /**
   * Converts a `file:` URL to an absolute path, percent-decoding it. Accepts
   * a string or any object with a string `href` (so a `URL` from another
   * realm works too). Throws a `TypeError` for a value that does not parse as
   * a URL, a scheme other than `file:`, a host other than empty or
   * `localhost`, or an encoded `/` in the path.
   */
  export function fileURLToPath(url: string | { readonly href: string }): string;

  /**
   * Converts an absolute path to a `file:` URL, percent-encoding the
   * characters the URL parser would otherwise read as syntax. There is no
   * working directory to resolve against, so a relative path throws a
   * `TypeError`.
   */
  export function pathToFileURL(path: string): URL;

  // An interface cannot extend an `import()` type, and inside `global` the
  // bare names mean the globals, hence the self-import.
  import {
    URL as NsURL,
    URLSearchParams as NsURLSearchParams,
  } from "ns:url";
  global {
    // Merged into the DOM's interfaces when a DOM lib is present.
    interface URL extends NsURL {}
    interface URLSearchParams extends NsURLSearchParams {}
  }
}

// Script-level declarations are global. The variables follow @types/node's
// rule for its own globals: when a DOM lib declares the global (detected
// through `onmessage`, which only the DOM libs put on `globalThis`), that
// declaration is reused verbatim so the two `declare var`s agree, and
// otherwise the module's constructor becomes the global.
declare var URL: typeof globalThis extends { onmessage: any; URL: infer T }
  ? T
  : typeof import("ns:url").URL;
declare var URLSearchParams: typeof globalThis extends {
  onmessage: any;
  URLSearchParams: infer T;
}
  ? T
  : typeof import("ns:url").URLSearchParams;
