// ModuleInternalCallbacks.h
#pragma once
#include <v8.h>

#include <functional>
#include <string>
#include <vector>

#include "robin_hood.h"

namespace tns {

// Canonical module key → compiled-module handle map used by the per-isolate
// registries below.
using ModuleHandleMap =
    robin_hood::unordered_map<std::string, v8::Global<v8::Module>>;

// Per-isolate module registry accessor: map canonical keys → compiled
// v8::Module handles for `isolate`. Keyed by v8::Isolate* (not thread) because
// v8::Global<Module> handles are isolate-bound; see the long-form comment above
// the definition in ModuleInternalCallbacks.mm for the cross-isolate-handle bug
// this prevents. The map lives in a Caches state slot, so this returns null
// once the isolate's teardown has begun — callers must bail.
ModuleHandleMap* ModuleRegistryFor(v8::Isolate* isolate);

// Mark every in-flight async graph load owned by `isolate` dead and Reset
// their context Globals. Must be called while the isolate is still alive (the
// Runtime destructor calls this before disposal); the rest of the loader state
// is destroyed with the isolate's Caches.
void QuiesceModuleLoadsForIsolate(v8::Isolate* isolate);

// Utility to drop modules from the registry when compilation/instantiation
// fails. Only ever called on the isolate's own JS thread during module
// resolution/loading.
void RemoveModuleFromRegistry(v8::Isolate* isolate,
                              const std::string& canonicalPath);

// The canonical registry key whose live entry is `mod`, or empty when the
// module is not registered for `isolate`. O(1) via the loader state's
// identity-hash index.
std::string LookupModuleKeyForModule(v8::Isolate* isolate,
                                     v8::Local<v8::Module> mod);

// Record `mod` in the identity-hash index under `canonicalKey`. Call alongside
// every registry insert performed outside ModuleInternalCallbacks.mm.
void IndexModuleForIsolate(v8::Isolate* isolate,
                           const std::string& canonicalKey,
                           v8::Local<v8::Module> mod);

// Authoritative HTTP URL loader for dev-served ESM. This compiles and
// registers the module under its canonical URL key without evaluating it.
v8::MaybeLocal<v8::Module> LoadHttpModuleForUrl(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& requestedUrl);

// ── Async HTTP module-graph pipeline ─────────────
//
// Standard three-phase module-map pipeline (the Node/Blink shape) under V8's
// synchronous ResolveModuleCallback: the sync constraint applies to
// *resolution*, not *fetching*. Starting from `rootUrl`, the walk fetches
// bodies concurrently off-thread (FetchModuleBodyAsync), compiles each on the
// isolate's JS thread (ScriptCompiler::CompileModule parses without
// resolving), resolves every static module request with the same import-map +
// relative-URL logic ResolveModuleCallback uses, and recurses until the
// transitive closure is compiled + registered. By InstantiateModule time the
// resolver is a pure registry lookup for the walked graph; anything the walk
// missed falls back to the legacy synchronous fetch inside the resolver.
//
// `onComplete(ok, errorMessage, context)` runs exactly once on the isolate's
// JS thread with the isolate entered and `context` (the context captured at
// start) already scoped. `ok` is false only when the ROOT fetch/compile
// failed — dependency failures are logged and left to surface through the
// resolver during instantiation, so the walk itself introduces no new
// failure modes.
void StartAsyncHttpModuleGraphLoad(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& rootUrl,
    std::function<void(bool ok, const std::string& errorMessage,
                       v8::Local<v8::Context> context)>
        onComplete);

// Synchronous wrapper for callers that need the graph ready before
// continuing (static HTTP entry loads): starts the walk, then pumps the
// current thread's runloop until it settles or `timeoutSeconds` elapses.
// Returns true when the walk completed (regardless of root success — the
// caller's own load path reports root failures). This is the "manual run
// loop until settled" boot handoff.
bool RunAsyncHttpModuleGraphLoadPumped(v8::Isolate* isolate,
                                       v8::Local<v8::Context> context,
                                       const std::string& rootUrl,
                                       double timeoutSeconds);

// True while any async graph load (any isolate) has fetches or compiles
// outstanding. Read by the boot handoff in [NativeScript runMainApplication]
// to decide whether to keep pumping a manual runloop after Tasks::Drain
// returned without UIApplicationMain having been invoked.
bool HasPendingAsyncModuleGraphWork();

// Keep a fallback copy of the last evaluated module so could be served while
// reloading if needed
void UpdateModuleFallback(v8::Isolate* isolate,
                          const std::string& canonicalPath,
                          v8::Local<v8::Module> module);

// Drop exact URL-keyed modules from the registry and clear any in-flight
// invalidation bookkeeping tied to those canonical keys.
void InvalidateModules(v8::Isolate* isolate, v8::Local<v8::Context> context,
                       const std::vector<std::string>& urls);

// Diagnostics helper: returns URL-like keys currently loaded in the module
// registry.
std::vector<std::string> GetLoadedModuleUrls();

// Resolve callback signature (with import‑assertions slot)
v8::MaybeLocal<v8::Module> ResolveModuleCallback(
    v8::Local<v8::Context> context, v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions,
    v8::Local<v8::Module> referrer);

// Host callback for dynamic import() expressions
v8::MaybeLocal<v8::Promise> ImportModuleDynamicallyCallback(
    v8::Local<v8::Context> context, v8::Local<v8::Data> host_defined_options,
    v8::Local<v8::Value> resource_name, v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions);

// Import map support
// Parse and store an import map from JSON. Expected shape: {"imports": {"key":
// "value", ...}}
void SetImportMap(const std::string& json);

// Set URL patterns that should bypass module cache (e.g. "/@ns/sfc/", "?v=")
void SetVolatilePatterns(const std::vector<std::string>& patterns);

// Clear import map state and vendor module cache. Must be called before isolate
// disposal.
void CleanupImportMapGlobals();

}  // namespace tns
