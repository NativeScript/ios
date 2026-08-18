// ModuleInternalCallbacks.h
#pragma once
#include <v8.h>

#include <functional>
#include <string>
#include <vector>

#include "HttpLoader.h"
#include "robin_hood.h"

namespace tns {

// ── The loader vocabulary ────────────────────────────────────
//
// Everything the dev client teaches one isolate's module loader: which bare
// specifiers resolve where, how URLs are keyed, and which URLs are never
// cached. Per-isolate, not process-wide — it lives in the isolate's
// ModuleLoaderState slot and dies with the isolate.
//
// A worker inherits a COPY taken on the parent's thread at spawn (see
// CaptureLoaderVocabulary / InstallLoaderVocabulary), so no synchronization is
// needed anywhere: each isolate only ever reads and writes its own. A live
// worker therefore does not observe a later reconfiguration — the dev client
// restarts workers on updates.

// One import-map section: specifier key → target. Lookup within a section is
// exact-then-trailing-slash-prefix with longest match, per the import-maps
// spec.
using ImportMapEntries = robin_hood::unordered_map<std::string, std::string>;

// A parsed import map. `scopes` is kept ordered most-specific-first so the
// resolution cascade walks it without re-sorting on every lookup.
struct ParsedImportMap {
  ImportMapEntries imports;
  std::vector<std::pair<std::string, ImportMapEntries>> scopes;

  bool empty() const { return imports.empty() && scopes.empty(); }
};

struct LoaderVocabulary {
  ParsedImportMap importMap;
  CanonicalizationConfig canonicalization;
  // Distinguishes "no vocabulary supplied" (mechanical canonicalization only)
  // from "supplied, and empty" — an empty vocabulary is explicit policy.
  bool canonicalizationConfigured = false;
  // URL substrings whose modules are always re-fetched, never cached.
  std::vector<std::string> volatilePatterns;
};

// Copy `isolate`'s vocabulary. Call on that isolate's own thread.
LoaderVocabulary CaptureLoaderVocabulary(v8::Isolate* isolate);

// Replace `isolate`'s vocabulary wholesale. Call on that isolate's own thread,
// before it loads any module.
void InstallLoaderVocabulary(v8::Isolate* isolate, LoaderVocabulary vocabulary);

// The calling isolate's canonicalization vocabulary, or null when it has none
// (the mechanical, fragment-only canonicalization applies). Isolate thread
// only — the transport never calls this, it carries canonical keys instead.
const CanonicalizationConfig* CanonicalizationConfigForCurrentIsolate();

// Install the client-supplied canonicalization vocabulary on the calling
// isolate. Its presence replaces the mechanical default entirely — empty
// vectors are honored as explicit policy.
void SetCanonicalizationConfig(CanonicalizationConfig config);

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

// The require(esm) exports facade: a synthetic source-text module that
// re-exports everything from `target` and adds `__esModule = true`, so
// transpiled CJS consumers (`_mod.__esModule ? _mod.default : _mod`) pick up a
// real ESM default export through require(). Re-exports keep the target's live
// bindings and enumerability, which a copied object would not. Returns the
// facade instantiated and evaluated; the caller takes GetModuleNamespace().
// One facade per target module, cached until the target leaves the registry.
v8::MaybeLocal<v8::Module> GetOrCreateRequireFacade(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    v8::Local<v8::Module> target, const std::string& targetCanonicalPath);

// Authoritative HTTP URL loader for dev-served ESM. This compiles and
// registers the module under its canonical URL key without evaluating it.
v8::MaybeLocal<v8::Module> LoadHttpModuleForUrl(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& requestedUrl);

// ── The module-graph walk ────────────────────────
//
// Standard three-phase module-map pipeline (the Node/Blink shape) under V8's
// synchronous ResolveModuleCallback: the sync constraint applies to
// *resolution*, not *fetching*. Starting from `root` (an absolute http(s) URL
// or a canonical filesystem path), the walk discovers the transitive closure
// and compiles + registers every module in it, so that by InstantiateModule
// time the resolver is a pure registry lookup.
//
// Discovery is scheme-agnostic; only the fetch is per-scheme. Every edge goes
// through the same resolution the resolver uses (ResolveSpecifierToPath), so
// both agree on a module's registry key:
//   - http(s) edges are fetched concurrently off-thread
//     (FetchModuleBodyAsync) and compiled on the isolate's JS thread;
//   - local edges are read and compiled inline during the walk — the bytes
//     are already on disk, and a thread hop would only reorder discovery;
//   - builtins are left to the resolver, which serves them from the builtin
//     registry;
//   - specifiers the walk cannot resolve (typically a bare name with no
//     import-map entry) stay on the resolver's lazy path.
//
// Compilation runs no user code, so pre-compiling the closure cannot change
// evaluation order: V8 still evaluates in spec order from the root.
//
// `onComplete(ok, errorMessage, context)` runs exactly once on the isolate's
// JS thread with the isolate entered and `context` (the context captured at
// start) already scoped. `ok` is false only when an HTTP ROOT fetch/compile
// failed. Every other failure — a dependency, or anything local including the
// root — is left unregistered for the resolver (or the caller's own load
// path) to report with its own message, so the walk introduces no new failure
// modes and steals no error text.
void StartModuleGraphLoad(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& root,
    std::function<void(bool ok, const std::string& errorMessage,
                       v8::Local<v8::Context> context)>
        onComplete);

// Synchronous wrapper for callers that need the graph ready before
// continuing: starts the walk, then pumps the current thread's runloop until
// it settles or `timeoutSeconds` elapses. A graph with no http(s) edges
// completes entirely inside StartModuleGraphLoad, so this returns without
// entering the wait loop at all — a disk-only load pays no runloop slice.
// Returns true when the walk completed (regardless of root success — the
// caller's own load path reports root failures).
bool RunModuleGraphLoadPumped(v8::Isolate* isolate,
                              v8::Local<v8::Context> context,
                              const std::string& root, double timeoutSeconds);

// True while any async graph load (any isolate) has fetches or compiles
// outstanding. Read by the boot handoff in [NativeScript runMainApplication]
// to decide whether to keep pumping a manual runloop after Tasks::Drain
// returned without UIApplicationMain having been invoked.
bool HasPendingAsyncModuleGraphWork();

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

// Import map support.
//
// Shape: {"imports": {"specifier": "target", ...},
//         "scopes": {"<referrer-key-prefix>": {imports-shaped map}, ...}}
//
// Parsed and validated in full before anything is installed: on any invalid
// input this returns false with `error` explaining which key or section is
// wrong, and the currently installed map is left untouched. Applies to the
// calling isolate only.
bool SetImportMap(const std::string& json, std::string* error);

// Set URL patterns that should bypass module cache (e.g. "?v=", "/hot/") on
// the calling isolate.
void SetVolatilePatterns(const std::vector<std::string>& patterns);

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
//                                      canonicalization vocabulary, applied to
//                                      the calling isolate)
//   - invalidateModules(urls)         (registry + cache eviction)
//   - getLoadedModuleUrls()           (registry introspection)
//   - createRequire(baseDir, pumping) (a require bound to baseDir; the JS half
//                                      in ns-module.js validates the caller's
//                                      filename/URL and splits the two
//                                      exported flavors)
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
