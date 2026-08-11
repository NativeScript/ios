#pragma once

#include <functional>
#include <string>
#include <vector>

// Forward declare v8 types to keep this header lightweight and avoid
// requiring V8 headers at include sites.
namespace v8 {
class Isolate;
template <class T>
class Local;
class Object;
class Function;
class Context;
class Value;
}  // namespace v8

namespace tns {

// HMRSupport: the native half of the NativeScript dev-loader contract.
//
// The runtime deliberately exposes *mechanism* only:
//   - the synchronous HTTP text fetch backing the HTTP ESM loader's
//     fallback path (V8's ResolveModuleCallback is synchronous — still
//     true as of 14.9.207.39 — so the fallback must be native),
//   - the async NSURLSession fetch behind the phase-1 module-graph walk
//     (StartAsyncHttpModuleGraphLoad), which is how module bodies
//     normally arrive,
//   - eviction plumbing (an eviction-driven fetch nonce that defeats
//     CFNetwork's HTTP cache),
//   - the dev-boot-complete signal that disarms cold-boot-only
//     behaviors (runloop pump, connection-recovery wait).
//

// ─────────────────────────────────────────────────────────────
// HTTP loader helpers (used by dev/HMR and general-purpose HTTP module loading)
//
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
// phase-1 module-graph walk (see StartAsyncHttpModuleGraphLoad in
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
// dev boot completes (see `MaybePumpJSThreadDuringBoot` in HMRSupport.mm).
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

// Flip the dev-boot-complete signal: sets the JS-visible
// `__NS_HMR_BOOT_COMPLETE__` global and the native atomic that gates the
// cold-boot-only behaviors (JS-thread runloop pump between synchronous
// fetches). Exposed to JS as ns:module
// `setDevBootComplete(value?: boolean)`.
void SetDevBootComplete(v8::Isolate* isolate, v8::Local<v8::Context> context,
                        bool value);

// Clear process-wide dev-loader state (cache-bust marks, boot-complete
// flag, canonicalization vocabulary). MUST be called inside
// Runtime::~Runtime() before isolate disposal — and only for the MAIN
// isolate (worker teardown must not wipe shared state the main isolate
// still uses).
void CleanupHMRGlobals();

// ─────────────────────────────────────────────────────────────
// The `ns:module` builtin binding
//
// Populates the native half of the `ns:module` builtin module — the one
// namespace carrying every JS-callable dev primitive that any tooling can
// depend on. Called from NsBuiltinModules::BuildBinding the first time a
// realm resolves `ns:module` (via require, static import, or import());
// ns-module.js shapes and freezes the exports.
//
// `ns:module` members:
//   - configureLoader(config)         (import map + volatile patterns +
//                                      canonicalization vocabulary)
//   - invalidateModules(urls)         (registry + cache eviction)
//   - getLoadedModuleUrls()           (registry introspection)
//   - setDevBootComplete(value?)      (boot-complete signal)
//   - canonicalizeHttpUrlKey(url)     (debug builds only; test diagnostic)
//
// Worker teardown across HMR cycles is userland: the dev client intercepts
// the global `Worker` constructor and terminates tracked instances
// (worker.terminate() cascades to nested workers via Runtime::~Runtime).
//
// Returns false (with an exception pending or a failed Set) when the
// binding could not be populated.
bool BuildNsModuleBinding(v8::Local<v8::Context> context,
                          v8::Local<v8::Object> binding);

}  // namespace tns
