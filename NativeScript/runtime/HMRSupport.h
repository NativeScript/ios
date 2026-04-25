#pragma once

#include <string>
#include <vector>

// Forward declare v8 types to keep this header lightweight and avoid
// requiring V8 headers at include sites.
namespace v8 {
class Isolate;
template <class T> class Local;
class Object;
class Function;
class Context;
class Value;
}

namespace tns {

// HMRSupport: Isolated helpers for minimal HMR (import.meta.hot) support.
//
// This module contains:
// - Per-module hot data store
// - Registration for accept/disable callbacks
// - Active dev-session state and helpers
// - Initializer to attach import.meta.hot to a module's import.meta
//
// Note: Triggering/dispatch is handled by the HMR system elsewhere.

// Retrieve or create the per-module hot data object.
v8::Local<v8::Object> GetOrCreateHotData(v8::Isolate* isolate, const std::string& key);

// Register accept and dispose callbacks for a module key.
void RegisterHotAccept(v8::Isolate* isolate, const std::string& key, v8::Local<v8::Function> cb);
void RegisterHotDispose(v8::Isolate* isolate, const std::string& key, v8::Local<v8::Function> cb);

// Optional: expose read helpers (may be useful for debugging/integration)
std::vector<v8::Local<v8::Function>> GetHotAcceptCallbacks(v8::Isolate* isolate, const std::string& key);
std::vector<v8::Local<v8::Function>> GetHotDisposeCallbacks(v8::Isolate* isolate, const std::string& key);

// `import.meta.hot` implementation
// Provides:
// - `hot.data` (per-module persistent object across HMR updates)
// - `hot.accept(...)` (deps argument currently ignored; registers callback if provided)
// - `hot.dispose(cb)` (registers disposer)
// - `hot.decline()` / `hot.invalidate()` (currently no-ops)
// - `hot.prune` (currently always false)
//
// Notes/limitations:
// - Event APIs (`hot.on/off`), messaging (`hot.send`), and status handling are not implemented.
// - `modulePath` is used to derive the per-module key for `hot.data` and callbacks.
void InitializeImportMetaHot(v8::Isolate* isolate,
                             v8::Local<v8::Context> context,
                             v8::Local<v8::Object> importMeta,
                             const std::string& modulePath);

// ─────────────────────────────────────────────────────────────
// Dev session helpers

struct DevSessionState {
    bool active = false;
    bool started = false;
    std::string sessionId;
    std::string origin;
    std::string entryUrl;
    std::string clientUrl;
    std::string wsUrl;
    std::string platform;
    std::string runtimeConfigUrl;
    bool fullReload = false;
    bool cssHmr = false;
};

// Read and validate the JS dev-session config object.
bool ReadDevSessionConfig(v8::Isolate* isolate,
                                                    v8::Local<v8::Context> context,
                                                    v8::Local<v8::Object> config,
                                                    DevSessionState* out,
                                                    std::string* errorMessage);

// Active dev-session storage.
void ResetActiveDevSession();
DevSessionState GetActiveDevSessionSnapshot();
void StoreActiveDevSession(const DevSessionState& session);
bool HasDevSessionChanged(const DevSessionState& previous,
                                                    const DevSessionState& next);
std::vector<std::string> CollectSessionModuleUrls(const DevSessionState& session);
bool ApplyDevRuntimeConfigFromUrl(const std::string& url,
                                  std::string* errorMessage);

// Runtime global helpers for the deterministic dev session boot path.
void ApplyDevSessionGlobals(v8::Isolate* isolate,
                                                        v8::Local<v8::Context> context,
                                                        const DevSessionState& session);
void SetDevSessionBootComplete(v8::Isolate* isolate,
                                                             v8::Local<v8::Context> context,
                                                             bool value);

// ─────────────────────────────────────────────────────────────
// HTTP loader helpers (used by dev/HMR and general-purpose HTTP module loading)
//
// Normalize an HTTP(S) URL into a stable module registry/cache key.
// - Always strips URL fragments.
// - For NativeScript dev endpoints, normalizes known cache busters (e.g. t/v/import)
//   and normalizes some versioned bridge paths.
// - For non-dev/public URLs, preserves the full query string as part of the cache key.
std::string CanonicalizeHttpUrlKey(const std::string& url);

// Minimal text fetch for HTTP ESM loader. Returns true on 2xx with non-empty body.
// - out: response body
// - contentType: Content-Type header if present
// - status: HTTP status code
//
// On a fast path, returns from the in-memory speculative-prefetch cache
// without touching the network. On the slow path, performs a synchronous
// fetch and additionally schedules background prefetches for the body's
// static imports so subsequent HttpFetchText calls hit the cache. See
// the prefetcher block in HMRSupport.mm for full design notes.
bool HttpFetchText(const std::string& url, std::string& out, std::string& contentType, int& status);

// Drop all entries in the speculative-prefetch cache. Safe to call from
// any thread. Used by Runtime teardown and by HMR cache-poison scenarios
// where the dev server has indicated a graph version bump.
void ClearHttpModulePrefetchCache();

// Drop a specific URL set from the speculative-prefetch cache. Safe
// to call from any thread; missing keys are silently ignored. Used by
// `InvalidateModules` so that an HMR eviction also purges any stale
// HTTP body the previous prefetch wave (or kickstart) left behind.
// Without this, the kickstart's "skip if URL already cached"
// early-out, plus `HttpFetchText`'s destructive-read fast path, would
// happily serve V8 a stale body from the prior save — visible to the
// user as a 1-cycle lag between save and visual update.
void EvictHttpModulePrefetchCacheUrls(const std::vector<std::string>& urls);

// Kickstart an HMR-driven module prefetch
// rooted at `seedUrl`. Walks the static-import graph in parallel (up to
// `maxConcurrent` simultaneous HTTP fetches), storing every reachable
// module body in the speculative-prefetch cache. Blocks the calling
// thread until the BFS has fully drained or `timeoutSeconds` elapses.
//
// Designed to be invoked from JS (via `__nsKickstartHmrPrefetch`)
// immediately before the Angular HMR client re-imports the entry —
// by the time V8 walks the dep tree, every reachable body is already
// in `g_prefetchCache` and the walk runs at memory speed instead of
// network speed (turning a ~3s 200-fetch refresh into ~250ms).
//
// Returns `true` when the BFS drained cleanly. On timeout or seed
// fetch failure returns `false`; callers should treat that as "no
// kickstart speedup this round" and fall back to V8's normal
// synchronous walk, which always succeeds independently.
//
// `outFetchedCount` (optional) receives the number of distinct URLs
// fetched. `outElapsedMs` (optional) receives wall-clock time.
bool KickstartHmrPrefetchSync(const std::string& seedUrl,
                              int maxConcurrent,
                              double timeoutSeconds,
                              size_t* outFetchedCount,
                              uint64_t* outElapsedMs);

// Multi-URL kickstart for HMR cycles. Unlike the legacy seed-rooted
// variant above, this one fetches ONLY the explicit URL list it was
// given (no body scanning, no BFS recursion).
//
// This is the right shape for HMR: the dev server's
// `collectAngularEvictionUrls` already computed the inverse-dep
// closure of the changed file; re-discovering it via in-process
// scanning would just duplicate that work and re-fetch modules V8
// has already compiled. By feeding the precomputed list directly we
// turn N sequential `LoadHttpModuleForUrl` calls (the importer chain
// during V8's ResolveModuleCallback walk) into a single parallel
// wave that completes before V8 starts walking.
//
// Same semantics as `KickstartHmrPrefetchSync` for everything else:
// blocks the calling thread until the wave drains or `timeoutSeconds`
// elapses; cleared/blocked URLs are filtered up front; partial
// success is reported as success (the V8 walk falls back to
// per-module HttpFetchText for anything we couldn't pre-fill).
bool KickstartHmrPrefetchUrlsSync(const std::vector<std::string>& urls,
                                  int maxConcurrent,
                                  double timeoutSeconds,
                                  size_t* outFetchedCount,
                                  uint64_t* outElapsedMs);

// Clear all HMR-related v8::Global handles (g_hotData, g_hotAccept, g_hotDispose).
// MUST be called inside Runtime::~Runtime() before isolate disposal to prevent
// crashes during static destructor cleanup (__cxa_finalize_ranges).
void CleanupHMRGlobals();
// ─────────────────────────────────────────────────────────────
// Custom HMR event support

// Register a custom event listener (called by import.meta.hot.on())
void RegisterHotEventListener(v8::Isolate* isolate, const std::string& event, v8::Local<v8::Function> cb);

// Get all listeners for a custom event
std::vector<v8::Local<v8::Function>> GetHotEventListeners(v8::Isolate* isolate, const std::string& event);

// Dispatch a custom event to all registered listeners
// This should be called when the HMR WebSocket receives framework-specific events
void DispatchHotEvent(v8::Isolate* isolate, v8::Local<v8::Context> context, const std::string& event, v8::Local<v8::Value> data);

// Initialize the global event dispatcher function (__NS_DISPATCH_HOT_EVENT__)
// This exposes a JavaScript-callable function that the HMR client can use to dispatch events
void InitializeHotEventDispatcher(v8::Isolate* isolate, v8::Local<v8::Context> context);

} // namespace tns
