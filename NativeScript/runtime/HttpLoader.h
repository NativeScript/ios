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
//   - eviction plumbing (an eviction-driven fetch nonce that defeats
//     CFNetwork's HTTP cache),
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
// `CanonicalizeHttpUrlKey`.
//
// When unconfigured, a built-in vocabulary matching current
// `@nativescript/vite` conventions applies.
struct CanonicalizationConfig {
  std::vector<std::string> stripParams;      // query param names to drop
  std::vector<std::string> devPathPrefixes;  // StartsWith → normalize query
  std::vector<std::string> preserveQueryPrefixes;  // contains → keep query
};

// Install the client-supplied vocabulary. Presence of the configuration
// replaces the built-in fallback entirely — empty vectors are honored as
// explicit policy.
void SetCanonicalizationConfig(CanonicalizationConfig config);

// Normalize an HTTP(S) URL into a stable module registry/cache key.
// - Always strips URL fragments.
// - For NativeScript dev endpoints, drops known cache busters (t/v/import)
//   and sorts remaining query params for stability.
// - For non-dev/public URLs, preserves the full query string as part of the
//   cache key.
// Module identity IS the (canonical) URL — the dev server serves every
// module under exactly one URL and never varies it for freshness.
std::string CanonicalizeHttpUrlKey(const std::string& url);

// Minimal text fetch for HTTP ESM loader. Returns true on 2xx with non-empty
// body.
// - out: response body
// - contentType: Content-Type header if present
// - status: HTTP status code
//
// Synchronous fetch with one retry — this is the fallback path for
// anything the async module-graph walk missed.
bool HttpFetchText(const std::string& url, std::string& out,
                   std::string& contentType, int& status);

// Asynchronous single-URL module body fetch — the I/O primitive behind the
// phase-1 module-graph walk (see StartModuleGraphLoad in
// ModuleInternalCallbacks.h). Same semantics as HttpFetchText, minus the
// JS-thread block:
//   - security gate (IsRemoteUrlAllowed) checked up front,
//   - an NSURLSession GET on a background queue with the same request
//     shape as the sync path (cache-bust nonce, zero-cache headers,
//     no cookies) and one retry on transport error,
//   - empty 2xx bodies normalize to the canonical empty module.
// `completion(ok, status, body)` is invoked exactly once, on an arbitrary
// thread — callers must hop to their JS thread before touching V8.
void FetchModuleBodyAsync(
    const std::string& url,
    std::function<void(bool ok, int status, std::string body)> completion);

// Register a "yield" callback that `HttpFetchText` should invoke around its
// synchronous network turn so the caller can pump its own runloop (e.g. the
// JS-thread runloop so a placeholder UI can repaint during cold-boot).
//
// Default: a built-in pump that no-ops outside the JS thread / after the
// dev boot completes (see `MaybePumpJSThreadDuringBoot` in HttpLoader.mm).
//
// Pass `nullptr` to disable any yielding (used by hosts that drive their own
// run loop or by tests that want bit-for-bit deterministic fetch timing).
// Safe to call from any thread; reads use acquire/release ordering.
void RegisterHttpFetchYield(void (*callback)());

// Mark a URL set (canonicalized internally) so that the NEXT network
// fetch of each URL carries a unique `__ns_dev_nonce` query parameter,
// guaranteeing CFNetwork cannot satisfy the request from any HTTP cache
// layer (observed on iOS 18+/26+ Simulator even with `no-store` headers
// and a reload-ignoring cache policy). Called by `InvalidateModules` for
// the eviction set; marks are consumed when a fresh body arrives.
// The nonce is transport-only and never affects module identity.
void MarkUrlsForCacheBust(const std::vector<std::string>& urls);

// Arm/disarm this thread's boot-evaluation window: while nonzero, the yield
// inside synchronous HTTP fetches may pump the JS thread's runloop (safe
// only while the entry module is evaluating — nothing else owns the runloop
// yet). Balanced RAII-style by ModuleInternal::RunModule.
void SetBootEvaluationActive(bool active);

// Clear process-wide HTTP-loader state (cache-bust marks,
// canonicalization vocabulary). MUST be called inside
// Runtime::~Runtime() before isolate disposal — and only for the MAIN
// isolate (worker teardown must not wipe shared state the main isolate
// still uses).
void CleanupHttpLoaderGlobals();

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
