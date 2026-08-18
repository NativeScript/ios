declare module "ns:module" {
  /**
   * An import map in the WHATWG shape the dev server emits: bare specifier →
   * absolute URL. Consulted inside the engine's synchronous module resolver,
   * which is why it must be handed to the runtime ahead of time rather than
   * resolved on demand.
   */
  export interface ImportMap {
    imports: Record<string, string>;
  }

  /**
   * The URL vocabulary the runtime's canonical-key function applies when
   * keying its module registry. The mechanism (fragment strip, cache-buster
   * param drop, param sort) is native; this vocabulary is server policy and
   * is supplied by the development tooling.
   */
  export interface CanonicalizationConfig {
    /**
     * Query param names that are pure cache busters and are dropped for dev
     * endpoints (e.g. `t`, `v`, `import`).
     */
    stripParams?: string[];
    /**
     * Path prefixes (starts-with) identifying dev endpoints whose query may
     * be normalized (e.g. `/ns/`, `/@id/`).
     */
    forPathPrefixes?: string[];
    /**
     * Path substrings whose query IS the module identity and must be
     * preserved verbatim (e.g. `/@ng/component`).
     */
    preserveQueryFor?: string[];
  }

  /**
   * Loader policy, installed before the dev session imports anything. Every
   * section is optional; each present section replaces its native state
   * wholesale.
   */
  export interface LoaderConfig {
    importMap?: ImportMap;
    /** URL substrings identifying modules that are always re-fetched, never cached. */
    volatilePatterns?: string[];
    canonicalization?: CanonicalizationConfig;
  }

  /**
   * Installs loader policy — the sole channel by which server/framework URL
   * policy enters the runtime's module loader.
   */
  export function configureLoader(config: LoaderConfig): void;

  /**
   * Evicts the given URLs (canonicalized) from the module registry and marks
   * them bust-next-fetch, so the next network fetch bypasses every HTTP
   * cache layer.
   */
  export function invalidateModules(urls: string[]): void;

  /**
   * The URL-like keys currently in the module registry (used to compute
   * full-reload eviction sets).
   */
  export function getLoadedModuleUrls(): string[];

  /**
   * A `require` that resolves against the directory of `filenameOrURL` — a
   * trailing slash names the directory itself. Accepts an absolute path
   * string, a `file:` URL string, or a URL object; anything else throws a
   * `TypeError`, and an `http(s)` base is refused because `require()` of a
   * dev-served module is not supported (import those instead).
   *
   * ES module graphs load under Node's `require(esm)` rule: a graph
   * containing top-level await is refused before it evaluates.
   *
   * `require.resolve`, `require.cache` and `require.main` are not
   * implemented and are absent from the returned function.
   */
  export function createRequire(
    filenameOrURL: string | URL,
  ): (specifier: string) => any;

  /**
   * Like {@link createRequire}, except an ES module graph containing
   * top-level await is evaluated — by driving V8's nestable tasks and
   * microtasks until it settles — rather than refused. The Cocoa runloop is
   * never advanced, so a graph awaiting a native transport still cannot
   * settle here and fails on the deadline instead of returning a
   * half-initialized namespace.
   *
   * Callable only from a task context. The loop cannot be pumped
   * re-entrantly — V8 ignores a microtask checkpoint while the isolate is
   * already draining the microtask queue — and a top-level await resumes
   * through a promise reaction, which is a microtask. Requiring such a graph
   * from after an `await` or inside a `.then` callback throws immediately,
   * before evaluation, so `import()` can still load it. A synchronous graph
   * needs no pumping and stays legal from anywhere.
   */
  export function createPumpingRequire(
    filenameOrURL: string | URL,
  ): (specifier: string) => any;

  // Debug builds additionally carry `canonicalizeHttpUrlKey(url)`, a pure
  // test diagnostic; release builds omit the member entirely. It is
  // deliberately not declared here: it is not public API, and declaring it
  // unconditionally would misrepresent release builds, where feature checks
  // must observe it as absent.
}
