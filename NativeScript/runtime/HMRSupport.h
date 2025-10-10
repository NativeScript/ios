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

// Attach a minimal import.meta.hot object to the provided import.meta object.
// The modulePath should be the canonical path used to key callback/data maps.
void InitializeImportMetaHot(v8::Isolate* isolate,
                             v8::Local<v8::Context> context,
                             v8::Local<v8::Object> importMeta,
                             const std::string& modulePath);

// ─────────────────────────────────────────────────────────────
// Dev HTTP loader helpers (used during HMR only)
// These are isolated here so ModuleInternalCallbacks stays lean.
//
// Normalize HTTP(S) URLs for module registry keys.
// - Preserves versioning params for SFC endpoints (/@ns/sfc, /@ns/asm)
// - Drops cache-busting segments for /@ns/rt and /@ns/core
// - Drops query params for general app modules (/@ns/m)
std::string CanonicalizeHttpUrlKey(const std::string& url);

// Minimal text fetch for dev HTTP ESM loader. Returns true on 2xx with non-empty body.
// - out: response body
// - contentType: Content-Type header if present
// - status: HTTP status code
bool HttpFetchText(const std::string& url, std::string& out, std::string& contentType, int& status);

} // namespace tns
