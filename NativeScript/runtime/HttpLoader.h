#pragma once

#include <functional>
#include <string>
#include <vector>

namespace tns {

// HttpLoader: the native half of the NativeScript HTTP module-loader
// contract.
//
// The runtime deliberately exposes *mechanism* only:
//   - the synchronous HTTP text fetch backing the HTTP ESM loader's
//     fallback path (V8's ResolveModuleCallback is synchronous — still
//     true as of 14.9.207.39 — so the fallback must be native),
//   - the async NSURLSession fetch behind the phase-1 module-graph walk
//     (StartModuleGraphLoad), which is how module bodies
//     normally arrive,
//   - the boot-evaluation flag that arms the cold-boot runloop pump only
//     while an entry module is evaluating (derived by the runtime itself),
//   - the remote-module security gate, seeded once from nativescript.config
//     at boot and never exposed on ns:runtime getConfig/setConfig.

// ─────────────────────────────────────────────────────────────
// HTTP loader helpers (used by dev/HMR and general-purpose HTTP module loading)

// Canonicalization vocabulary (client-supplied policy).
//
// The canonical-key *mechanism* (fragment strip, cache-buster param drop,
// param sort) must be native because it keys the module registry inside
// V8's synchronous resolve walk. The *vocabulary* — which query params are
// pure cache busters, which path prefixes identify dev endpoints whose
// queries may be normalized, and which paths must keep their query verbatim
// because the query IS the identity — is server/framework policy, supplied
// by the dev client via
// ns:module `configureLoader({ canonicalization: {...} })` and consumed by
// `CanonicalizeHttpUrlKey`. It is per-isolate loader vocabulary — installed
// through SetCanonicalizationConfig in ModuleInternalCallbacks.h — so
// CanonicalizeHttpUrlKey runs on the isolate's own thread only. The transport
// never canonicalizes.
//
// When unconfigured, canonicalization is purely mechanical (fragment strip).
struct CanonicalizationConfig {
  std::vector<std::string> stripParams;      // query param names to drop
  std::vector<std::string> devPathPrefixes;  // StartsWith → normalize query
  std::vector<std::string> preserveQueryPrefixes;  // contains → keep query
};

// Normalize an HTTP(S) URL into a stable module registry/cache key.
// - Always strips URL fragments.
// - For NativeScript dev endpoints, drops known cache busters (t/v/import)
//   and sorts remaining query params for stability.
// - For non-dev/public URLs, preserves the full query string as part of the
//   cache key.
// Module identity IS the (canonical) URL — the dev server serves every
// module under exactly one URL and never varies it for freshness.
std::string CanonicalizeHttpUrlKey(const std::string& url);

// Repairs `http:/host` (one slash) back to `http://host`. Upstream path joins
// collapse the double slash, and every key derivation has to undo it BEFORE it
// tests the scheme — otherwise the collapsed form fails the test, is passed
// through verbatim, and the same module ends up with two registry identities:
// one from the resolver (which repairs) and one from whatever came in through
// invalidateModules (which did not).
std::string RepairCollapsedUrlScheme(const std::string& url);

// What a module response turned out to be. Decided once, by the shared
// classifier, for whichever transport produced the response.
enum class ModuleResponseKind {
  kJavaScript,
  kJson,
};

// The outcome of fetching one module over HTTP. Both transports produce this
// same verdict, so the synchronous fallback and the async graph walk cannot
// drift apart on what counts as a usable module.
struct ModuleFetchResult {
  bool ok = false;
  int status = 0;
  ModuleResponseKind kind = ModuleResponseKind::kJavaScript;
  // Normalized: an empty 2xx JavaScript body becomes the canonical empty
  // module. Meaningful only when `ok`.
  std::string body;
  std::string contentType;  // as received, parameters included
  // Reader-facing explanation, non-empty exactly when `!ok`. This is the text
  // that reaches the importer's rejection, so it names the URL and the cause.
  std::string failureReason;
};

// Synchronous module fetch with one retry on transport error — the fallback
// path for anything the async module-graph walk missed. Blocks the calling
// thread. Returns `result.ok`.
bool HttpFetchModule(const std::string& url, ModuleFetchResult& result);

// Asynchronous single-URL module fetch — the I/O primitive behind the
// module-graph walk (see StartModuleGraphLoad in ModuleInternalCallbacks.h).
// Same response policy as HttpFetchModule, minus the JS-thread block:
//   - security gate (IsRemoteUrlAllowed) checked up front,
//   - an NSURLSession GET on a background queue with the same request shape
//     as the sync path (no cookies, HTTP caching as the response headers
//     allow) and one retry on transport error.
// `fetchDeadline` is the enclosing graph load's fetch budget as an absolute
// CFAbsoluteTime (double; 0 = unbounded): attempts clamp their request
// timeout to the time remaining and the transport-error retry is skipped
// once no budget is left, so a bounded fetch can never outlive the wait
// that is pumping for it.
// `completion(result)` is invoked exactly once, on an arbitrary thread —
// callers must hop to their JS thread before touching V8.
void FetchModuleBodyAsync(
    const std::string& url, double fetchDeadline,
    std::function<void(ModuleFetchResult result)> completion);

// ─────────────────────────────────────────────────────────────
// Remote-module security gate
//
// Seeded once from nativescript.config / package.json (`security.allowRemoteModules`,
// `security.remoteModuleAllowlist`) the first time a fetch is gated. Debug
// builds always allow. These values are not readable or writable through
// ns:runtime getConfig/setConfig — only nativescript.config at boot.

// In debug mode (RuntimeConfig.IsDebug): always returns true.
// Otherwise returns the boot-time `security.allowRemoteModules` value.
bool IsRemoteModulesAllowed();

// Whether `url` may be fetched as a remote ES module. Debug builds always
// allow. Production requires allowRemoteModules, then an allowlist match
// (or all URLs if the allowlist is empty).
bool IsRemoteUrlAllowed(const std::string& url);

}  // namespace tns
