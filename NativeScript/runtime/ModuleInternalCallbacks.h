// ModuleInternalCallbacks.h
#pragma once
#include <v8.h>

#include <string>
#include <unordered_map>
#include <vector>

namespace tns {

// Export our registry so both LoadESModule and the callback see the same data.
// `thread_local`: each NS isolate (main thread + each Worker thread) gets its
// own per-thread map, because v8::Global<Module> handles are isolate-bound.
// See the long-form comment above the definition in ModuleInternalCallbacks.mm
// for the cross-isolate-handle bug this prevents.
extern thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_moduleRegistry;

// Utility to drop modules from the registry when compilation/instantiation fails
void RemoveModuleFromRegistry(const std::string& canonicalPath);

// Authoritative HTTP URL loader for dev-served ESM. This compiles and registers
// the module under its canonical URL key without evaluating it.
v8::MaybeLocal<v8::Module> LoadHttpModuleForUrl(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& requestedUrl);

// Keep a fallback copy of the last evaluated module so could be served while reloading if needed
void UpdateModuleFallback(v8::Isolate* isolate, const std::string& canonicalPath,
                          v8::Local<v8::Module> module);

// Drop exact URL-keyed modules from the registry and clear any in-flight
// invalidation bookkeeping tied to those canonical keys.
void InvalidateModules(v8::Isolate* isolate, v8::Local<v8::Context> context,
                       const std::vector<std::string>& urls);

// Diagnostics helper: returns URL-like keys currently loaded in the module registry.
std::vector<std::string> GetLoadedModuleUrls();

// Resolve callback signature (with import‑assertions slot)
v8::MaybeLocal<v8::Module> ResolveModuleCallback(
    v8::Local<v8::Context> context, v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions,
    v8::Local<v8::Module> referrer);

// Host callback for dynamic import() expressions
v8::MaybeLocal<v8::Promise> ImportModuleDynamicallyCallback(
    v8::Local<v8::Context> context, v8::Local<v8::ScriptOrModule> referrer,
    v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions);

// Import map support
// Parse and store an import map from JSON. Expected shape: {"imports": {"key": "value", ...}}
void SetImportMap(const std::string& json);

// Set URL patterns that should bypass module cache (e.g. "/@ns/sfc/", "?v=")
void SetVolatilePatterns(const std::vector<std::string>& patterns);

// Clear import map state and vendor module cache. Must be called before isolate disposal.
void CleanupImportMapGlobals();

}  // namespace tns
