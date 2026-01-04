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
bool HttpFetchText(const std::string& url, std::string& out, std::string& contentType, int& status);

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
