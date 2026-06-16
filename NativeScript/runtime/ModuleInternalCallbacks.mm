// ModuleInternalCallbacks.mm
#include "ModuleInternalCallbacks.h"
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <v8.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <queue>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "Helpers.h"         // for tns::Exists
#include "ModuleInternal.h"  // for LoadScript(...)
#include "NativeScriptException.h"
#include "HMRSupport.h"
#include "DevFlags.h"
#include "Runtime.h"  // for GetAppConfigValue
#include "RuntimeConfig.h"

// Do NOT pull all v8 symbols into namespace here; String would clash with
// other typedefs inside the NativeScript codebase. We refer to v8 symbols
// with explicit `v8::` qualification to avoid ambiguities.

namespace tns {

// Helper function to check if a module name looks like an optional external module
static bool IsLikelyOptionalModule(const std::string& moduleName) {
  // Skip Node.js built-in modules (they should be handled separately)
  if (moduleName.rfind("node:", 0) == 0) {
    return false;
  }

  // Check if it's a bare module name (no path separators) that could be an npm package
  if (moduleName.find('/') == std::string::npos && moduleName.find('\\') == std::string::npos &&
      moduleName[0] != '.' && moduleName[0] != '~' && moduleName[0] != '/') {
    return true;
  }
  return false;
}

// Helper function to check if a module name is a Node.js built-in module
static bool IsNodeBuiltinModule(const std::string& moduleName) {
  return moduleName.rfind("node:", 0) == 0;
}

// Normalize absolute paths so we avoid duplicate registry entries caused by
// differing path representations (e.g. duplicate slashes, "./" segments).
static std::string NormalizePath(const std::string& path) {
  if (path.empty()) {
    return path;
  }

  NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
  if (nsPath == nil) {
    return path;
  }

  NSString* standardized = [nsPath stringByStandardizingPath];
  if (standardized == nil) {
    return path;
  }

  return std::string([standardized UTF8String]);
}

// Convert a file:// URL to a filesystem path using NSURL for correct decoding.
static std::string FileURLToPath(const std::string& url) {
  if (url.empty()) {
    return url;
  }
  if (url.rfind("file://", 0) != 0) {
    return url; // not a file URL; return as-is
  }
  @autoreleasepool {
    NSString* ns = [NSString stringWithUTF8String:url.c_str()];
    if (!ns) {
      return url;
    }
    NSURL* u = [NSURL URLWithString:ns];
    if (u && u.isFileURL) {
      NSString* p = [u path];
      if (p) {
        return std::string([[p stringByStandardizingPath] UTF8String]);
      }
    }
  }
  return url;
}


// Simple suffix check utility
static inline bool EndsWith(const std::string& value, const std::string& suffix) {
  if (suffix.size() > value.size()) return false;
  return std::equal(suffix.rbegin(), suffix.rend(), value.rbegin());
}

static inline bool StartsWith(const std::string& s, const char* prefix) {
  size_t n = strlen(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
}

static bool ShouldTraceRegistryKey(const std::string& rawKey, const std::string& registryKey);
static std::string CanonicalizeRegistryKey(const std::string& key);
static const char* ModuleStatusToString(v8::Module::Status status);


static v8::MaybeLocal<v8::Module> CompileModuleFromSource(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                                          const std::string& code, const std::string& urlStr) {
  v8::EscapableHandleScope hs(isolate);
  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, code.c_str());
  v8::Local<v8::String> urlV8;
  if (!v8::String::NewFromUtf8(isolate, urlStr.c_str(), v8::NewStringType::kNormal).ToLocal(&urlV8)) {
    return v8::MaybeLocal<v8::Module>();
  }
  v8::ScriptOrigin origin(isolate, urlV8, 0, 0, false, -1, v8::Local<v8::Value>(), false, false, true);
  v8::ScriptCompiler::Source src(sourceText, origin);
  v8::Local<v8::Module> mod;
  if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&mod)) {
    return v8::MaybeLocal<v8::Module>();
  }
  if (mod->GetStatus() == v8::Module::kUninstantiated) {
    if (!mod->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
      return v8::MaybeLocal<v8::Module>();
    }
  }
  if (mod->GetStatus() != v8::Module::kEvaluated) {
    if (mod->Evaluate(context).IsEmpty()) {
      return v8::MaybeLocal<v8::Module>();
    }
  }
  return hs.Escape(mod);
}

// Compile-only variant for use inside ResolveModuleCallback. It compiles a v8::Module and
// registers it under urlStr but does NOT instantiate or evaluate. V8 is currently instantiating
// the importer and will handle instantiation of this dependency.
static v8::MaybeLocal<v8::Module> CompileModuleForResolveRegisterOnly(v8::Isolate* isolate,
                                                                      v8::Local<v8::Context> context,
                                                                      const std::string& code,
                                                                      const std::string& urlStr) {
  v8::EscapableHandleScope hs(isolate);
  const std::string registryKey = CanonicalizeRegistryKey(urlStr);
  if (IsScriptLoadingLogEnabled() && ShouldTraceRegistryKey(urlStr, registryKey)) {
    Log(@"[resolver][register-resolve-only] raw=%s key=%s", urlStr.c_str(),
        registryKey.c_str());
  }
  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, code.c_str());
  v8::Local<v8::String> urlV8;
  if (!v8::String::NewFromUtf8(isolate, urlStr.c_str(), v8::NewStringType::kNormal).ToLocal(&urlV8)) {
    return v8::MaybeLocal<v8::Module>();
  }
  v8::ScriptOrigin origin(isolate, urlV8, 0, 0, false, -1, v8::Local<v8::Value>(), false, false, true);
  v8::ScriptCompiler::Source src(sourceText, origin);
  v8::Local<v8::Module> mod;
  {
    v8::TryCatch tcCompile(isolate);
    if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&mod)) {
      if (RuntimeConfig.IsDebug) {
        uint64_t h = 1469598103934665603ull; // FNV-1a 64-bit
        for (unsigned char c : code) { h ^= c; h *= 1099511628211ull; }
        std::string snippet = code.substr(0, 600);
        for (char& ch : snippet) { if (ch == '\n' || ch == '\r') ch = ' '; }
        const char* classification = "unknown";
        v8::Local<v8::Message> message = tcCompile.Message();
        std::string msgStr = ""; std::string srcLineStr = ""; int lineNum = 0; int startCol = 0; int endCol = 0;
        if (!message.IsEmpty()) {
          v8::String::Utf8Value m8(isolate, message->Get()); if (*m8) msgStr = *m8;
          lineNum = message->GetLineNumber(context).FromMaybe(0);
          startCol = message->GetStartColumn(); endCol = message->GetEndColumn();
          v8::MaybeLocal<v8::String> maybeLine = message->GetSourceLine(context);
            if (!maybeLine.IsEmpty()) { v8::String::Utf8Value l8(isolate, maybeLine.ToLocalChecked()); if (*l8) srcLineStr = *l8; }
          // Classification heuristics based on message
          if (msgStr.find("Unexpected identifier") != std::string::npos || msgStr.find("Unexpected token") != std::string::npos) {
            // refine unexpected token categories
            if (msgStr.find("export") != std::string::npos && code.find("export default") == std::string::npos && code.find("__sfc__") != std::string::npos) classification = "missing-export-default";
            else classification = "syntax";
          } else if (msgStr.find("Cannot use import statement") != std::string::npos) {
            classification = "wrap-error";
          }
        }
        if (classification == std::string("unknown")) {
          if (code.find("export default") == std::string::npos && code.find("__sfc__") != std::string::npos) classification = "missing-export-default";
          else if (code.find("__sfc__") != std::string::npos && code.find("export {") == std::string::npos && code.find("export ") == std::string::npos) classification = "no-exports";
          else if (code.find("import ") == std::string::npos && code.find("export ") == std::string::npos) classification = "not-module";
          else if (code.find("_openBlock") != std::string::npos && code.find("openBlock") == std::string::npos) classification = "underscore-helper-unmapped";
        }
        // Trim srcLineStr
        if (srcLineStr.size() > 240) srcLineStr = srcLineStr.substr(0, 240);
        Log(@"[http-esm][compile][v8-error][%s] %s line=%d col=%d..%d hash=%llx bytes=%lu msg=%s srcLine=%s snippet=%s",
            classification, urlStr.c_str(), lineNum, startCol, endCol, (unsigned long long)h, (unsigned long)code.size(), msgStr.c_str(), srcLineStr.c_str(), snippet.c_str());
      }
      return v8::MaybeLocal<v8::Module>();
    }
  }
  // If an entry already exists, reuse it
  auto itExisting = g_moduleRegistry.find(registryKey);
  if (itExisting != g_moduleRegistry.end()) {
    v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
    if (!existing.IsEmpty()) {
      return hs.Escape(existing);
    }
  }
  g_moduleRegistry[registryKey].Reset(isolate, mod);
  return hs.Escape(mod);
}

// ────────────────────────────────────────────────────────────────────────────
// Per-isolate (thread-local) module registries: map absolute file paths /
// canonical URLs → compiled v8::Module handles for the *current* isolate.
//
// Why thread_local: NS Worker creates a separate v8::Isolate on its own
// thread (see Worker::ConstructorCallback in Worker.mm). v8::Global<T>
// handles are bound to the isolate that created them; reading their
// internal state from a different isolate is undefined behaviour. A
// previous design held these registries as a single, process-global map,
// which under HMR (where the worker fetches the SAME `/ns/m/` URLs the
// main thread already loaded) caused the worker isolate to receive a
// Module compiled by the main isolate. V8's linker then read the cross-
// isolate Module's export table and emitted bogus errors like:
//   SyntaxError: The requested module 'X' does not provide an export named 'Y'
// even though the served source clearly declared `Y`. Making the
// registry thread_local keeps each NS runtime/worker walking its own
// fresh, valid handle graph.
//
// Why the leaky-pointer pattern (heap-allocated, never deleted by the
// thread-exit destructor): a `thread_local std::unordered_map<...,
// v8::Global<...>>` would, on thread exit, run the map's destructor —
// which iterates and calls v8::Global::Reset() on each handle. If the
// owning isolate was already torn down, those Resets blow up with the
// `__cxa_finalize_ranges` SIGSEGV/SIGBUS that the original comment
// warned about. By holding a thread_local *pointer* to a heap-allocated
// map, the variable's per-thread destructor is a no-op (it just drops
// a pointer); cleanup of the actual handles is handled explicitly by
// the Runtime destructor (Runtime.mm) and CleanupImportMapGlobals()
// below, which run *before* the isolate is disposed.
//
// The reference aliases below keep all existing access sites unchanged
// (no `()` or `->` rewrites needed across ~100+ call sites). On each
// thread's first use of e.g. `g_moduleRegistry`, the initializer below
// runs once per thread to bind the reference to that thread's map.
namespace {
using ModuleHandleMap = std::unordered_map<std::string, v8::Global<v8::Module>>;

ModuleHandleMap& MakePerIsolateModuleRegistry() {
	thread_local auto* p = new ModuleHandleMap();
	return *p;
}

ModuleHandleMap& MakePerIsolateModuleFallbackRegistry() {
	thread_local auto* p = new ModuleHandleMap();
	return *p;
}

ModuleHandleMap& MakePerIsolateModuleFallbackByRelative() {
	thread_local auto* p = new ModuleHandleMap();
	return *p;
}
}  // namespace

thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_moduleRegistry = MakePerIsolateModuleRegistry();
static thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_moduleFallbackRegistry = MakePerIsolateModuleFallbackRegistry();
static thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_moduleFallbackByRelative = MakePerIsolateModuleFallbackByRelative();

// ────────────────────────────────────────────────────────────────────────────
// Import map: bare specifier → resolved URL (populated by __nsConfigureRuntime)
// Instead of rewriting import statements in source code on the Vite side, the runtime
// resolves bare specifiers through this map to either vendor URLs (ns-vendor://)
// or HTTP module URLs. Source code is served as Vite transformed it.
static std::unordered_map<std::string, std::string> g_importMap;

// Volatile URL patterns: URLs matching these substrings are always re-fetched
// (cache is evicted before loading). Configured by Vite at boot instead of
// being hardcoded. Replaces hardcoded /@ns/sfc/ and __webpack_* checks.
static std::vector<std::string> g_volatilePatterns;

// Vendor module registry: maps vendor specifier → evaluated v8::Module.
// Populated when ns-vendor:// modules are first resolved via SyntheticModule.
// Per-isolate (thread_local) for the same reason as g_moduleRegistry above —
// vendor SyntheticModules are isolate-bound and reusing one across isolates
// breaks the linker's export-table check.
namespace {
std::unordered_map<std::string, v8::Global<v8::Module>>& MakePerIsolateVendorModuleCache() {
	thread_local auto* p = new std::unordered_map<std::string, v8::Global<v8::Module>>();
	return *p;
}
}  // namespace

static thread_local std::unordered_map<std::string, v8::Global<v8::Module>>& g_vendorModuleCache = MakePerIsolateVendorModuleCache();

static bool ShouldTraceRegistryKey(const std::string& rawKey, const std::string& registryKey) {
  if (rawKey != registryKey) {
    return true;
  }

  return StartsWith(registryKey, "ns-vendor://") || StartsWith(registryKey, "optional:") ||
         StartsWith(registryKey, "node:") || StartsWith(registryKey, "blob:");
}

static std::string CanonicalizeRegistryKey(const std::string& key) {
  if (key.empty()) {
    return key;
  }

  std::string registryKey;
  const char* classification = "path";
  bool traceEvenWithoutChange = false;

  if (StartsWith(key, "http://") || StartsWith(key, "https://") ||
      StartsWith(key, "file://http://") || StartsWith(key, "file://https://")) {
    registryKey = CanonicalizeHttpUrlKey(key);
    classification = "http";
  } else if (StartsWith(key, "file://")) {
    registryKey = NormalizePath(FileURLToPath(key));
    classification = "file-url";
  } else if (StartsWith(key, "blob:")) {
    registryKey = key;
    classification = "blob";
    traceEvenWithoutChange = true;
  } else {
    // Preserve non-filesystem module namespaces such as ns-vendor://, optional:,
    // and node: so synthetic/in-memory modules keep their exact registry identity.
    size_t schemePos = key.find(':');
    size_t slashPos = key.find('/');
    if (schemePos != std::string::npos && (slashPos == std::string::npos || schemePos < slashPos)) {
      registryKey = key;
      classification = "custom-scheme";
      traceEvenWithoutChange = true;
    } else {
      registryKey = NormalizePath(key);
    }
  }

  if (IsScriptLoadingLogEnabled() && (traceEvenWithoutChange || registryKey != key)) {
    Log(@"[resolver][registry-key][%s] raw=%s key=%s", classification, key.c_str(),
        registryKey.c_str());
  }

  return registryKey;
}

v8::MaybeLocal<v8::Module> LoadHttpModuleForUrl(v8::Isolate* isolate,
                                                v8::Local<v8::Context> context,
                                                const std::string& requestedUrl) {
  const std::string registryKey = CanonicalizeHttpUrlKey(requestedUrl);

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[http-esm][load][begin] request=%s key=%s", requestedUrl.c_str(),
        registryKey.c_str());
  }

  auto itExisting = g_moduleRegistry.find(registryKey);
  if (itExisting != g_moduleRegistry.end()) {
    v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[http-esm][load][cache-hit] key=%s", registryKey.c_str());
      }
      return v8::MaybeLocal<v8::Module>(existing);
    }

    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][load][drop-errored] key=%s", registryKey.c_str());
    }
    RemoveModuleFromRegistry(registryKey);
  }

  std::string body;
  std::string contentType;
  int status = 0;
  if (!HttpFetchText(requestedUrl, body, contentType, status) || body.empty()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][load][fetch-fail] request=%s key=%s status=%d",
          requestedUrl.c_str(), registryKey.c_str(), status);
    }
    if (RuntimeConfig.IsDebug) {
      std::string msg = "HTTP import failed: " + requestedUrl + " (status=" +
                        std::to_string(status) + ")";
      isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
    }
    return v8::MaybeLocal<v8::Module>();
  }

  v8::MaybeLocal<v8::Module> loaded =
      CompileModuleForResolveRegisterOnly(isolate, context, body, registryKey);
  if (loaded.IsEmpty()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][load][compile-fail] request=%s key=%s bytes=%zu",
          requestedUrl.c_str(), registryKey.c_str(), body.size());
    }
    if (RuntimeConfig.IsDebug) {
      std::string msg = "HTTP import compile failed: " + requestedUrl;
      isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
    }
    return v8::MaybeLocal<v8::Module>();
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[http-esm][load][ok] request=%s key=%s type=%s bytes=%zu",
        requestedUrl.c_str(), registryKey.c_str(), contentType.c_str(), body.size());
  }

  return loaded;
}

// ── Import map helpers ──────────────────────────────────────────────────────

void SetImportMap(const std::string& json) {
  g_importMap.clear();
  // The import map is a small, flat {"imports": {"specifier": "target", ...}}
  // object. Parse it with Foundation's JSON reader rather than a hand-rolled
  // scanner so escapes, nesting, and malformed input are handled correctly and
  // can't desync key/value pairing.
  @autoreleasepool {
    NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
    if (data == nil || data.length == 0) {
      return;
    }
    NSError* err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:kNilOptions
                                                  error:&err];
    if (parsed == nil || ![parsed isKindOfClass:[NSDictionary class]]) {
      if (IsScriptLoadingLogEnabled()) {
        NSString* detail = err.localizedDescription ?: @"not an object";
        Log(@"[import-map] parse failed: %s", [detail UTF8String] ?: "unknown");
      }
      return;
    }
    id imports = [(NSDictionary*)parsed objectForKey:@"imports"];
    if (![imports isKindOfClass:[NSDictionary class]]) {
      return;  // no "imports" object → empty map, same as the prior parser
    }
    for (id key in (NSDictionary*)imports) {
      if (![key isKindOfClass:[NSString class]]) continue;
      id value = [(NSDictionary*)imports objectForKey:key];
      if (![value isKindOfClass:[NSString class]]) continue;  // skip non-string targets
      const char* k = [(NSString*)key UTF8String];
      const char* v = [(NSString*)value UTF8String];
      if (k != nullptr && v != nullptr) {
        g_importMap[std::string(k)] = std::string(v);
      }
    }
  }
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[import-map] loaded %lu entries", (unsigned long)g_importMap.size());
  }
}

void SetVolatilePatterns(const std::vector<std::string>& patterns) {
  g_volatilePatterns = patterns;
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[import-map] volatile patterns: %lu", (unsigned long)g_volatilePatterns.size());
  }
}

// Check if a URL matches any volatile pattern (should bypass cache).
static bool IsVolatileUrl(const std::string& url) {
  for (const auto& pat : g_volatilePatterns) {
    if (url.find(pat) != std::string::npos) return true;
  }
  return false;
}

// Normalize a Vite-rewritten specifier into the canonical import-map key.
// Handles two common Vite dev-server rewrite patterns:
//   1. Prebundled deps:  "/node_modules/.vite/deps/solid-js.js?v=abc"   → "solid-js"
//                        "/node_modules/.vite/deps/@tanstack_solid-router.js" → "@tanstack/solid-router"
//   2. Explicit node_modules paths:
//        "/node_modules/@angular/core/fesm2022/core.mjs" → "@angular/core/fesm2022/core.mjs"
//        "/node_modules/tslib/tslib.es6.mjs"             → "tslib"
//
// For explicit node_modules paths we preserve non-main-entry subpaths so the
// import map's trailing-slash HTTP prefixes can keep complex package build
// outputs on HTTP. Only bare package roots and simple root-level main entries
// collapse back to the package id for vendor/exact import-map resolution.
// Returns the normalized import-map key or empty string if not a node_modules path.
static std::string NormalizeViteSpecifier(const std::string& specifier) {
  // Pattern 1: Vite prebundled deps — /node_modules/.vite/deps/<flattened-id>.js
  {
    const std::string viteDepsPrefix = "/node_modules/.vite/deps/";
    // Also handle without leading slash
    const std::string viteDepsPrefix2 = "node_modules/.vite/deps/";
    std::string prefix;
    if (specifier.compare(0, viteDepsPrefix.size(), viteDepsPrefix) == 0)
      prefix = viteDepsPrefix;
    else if (specifier.compare(0, viteDepsPrefix2.size(), viteDepsPrefix2) == 0)
      prefix = viteDepsPrefix2;

    if (!prefix.empty()) {
      std::string id = specifier.substr(prefix.size());
      // Strip extension (.js, .mjs, .cjs) and query params
      auto qpos = id.find('?');
      if (qpos != std::string::npos) id = id.substr(0, qpos);
      auto dotpos = id.rfind('.');
      if (dotpos != std::string::npos) id = id.substr(0, dotpos);
      // Reverse esbuild flattening: first _ after @ is / (scope separator),
      // remaining __ are . and _ are / — but we only need the package root.
      // Examples: "solid-js" → "solid-js", "@tanstack_solid-router" → "@tanstack/solid-router"
      if (!id.empty() && id[0] == '@') {
        // Scoped package: find first underscore → scope/name
        auto upos = id.find('_');
        if (upos != std::string::npos) {
          id = id.substr(0, upos) + "/" + id.substr(upos + 1);
          // If there are more underscores, the rest is subpath — just keep scope/name
          auto upos2 = id.find('_', upos + 1);
          if (upos2 != std::string::npos) {
            id = id.substr(0, upos2);
          }
        }
      }
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[import-map][normalize] vite-deps: %s -> %s", specifier.c_str(), id.c_str());
      }
      return id;
    }
  }

  // Pattern 2: Resolved node_modules path — /node_modules/<pkg>/...
  {
    const std::string nmPrefix = "/node_modules/";
    const std::string nmPrefix2 = "node_modules/";
    std::string sub;
    if (specifier.compare(0, nmPrefix.size(), nmPrefix) == 0)
      sub = specifier.substr(nmPrefix.size());
    else if (specifier.compare(0, nmPrefix2.size(), nmPrefix2) == 0)
      sub = specifier.substr(nmPrefix2.size());

    if (!sub.empty() && sub[0] != '.') {
      // Skip .vite/ paths (handled above)
      if (sub.compare(0, 6, ".vite/") == 0) return "";

      std::string subNoQuery = sub;
      std::string querySuffix;
      auto subQueryPos = sub.find('?');
      if (subQueryPos != std::string::npos) {
        subNoQuery = sub.substr(0, subQueryPos);
        querySuffix = sub.substr(subQueryPos);
      }

      // Extract package name: @scope/name or name
      std::string pkgName;
      if (subNoQuery[0] == '@') {
        // Scoped: @scope/name
        auto slash1 = subNoQuery.find('/');
        if (slash1 != std::string::npos) {
          auto slash2 = subNoQuery.find('/', slash1 + 1);
          pkgName = (slash2 != std::string::npos) ? subNoQuery.substr(0, slash2) : subNoQuery;
        }
      } else {
        // Unscoped: name
        auto slash = subNoQuery.find('/');
        pkgName = (slash != std::string::npos) ? subNoQuery.substr(0, slash) : subNoQuery;
      }
      if (!pkgName.empty()) {
        std::string normalized = pkgName;
        std::string remainder;
        if (subNoQuery.size() > pkgName.size()) {
          remainder = subNoQuery.substr(pkgName.size());
          if (!remainder.empty() && remainder[0] == '/') {
            remainder.erase(0, 1);
          }
        }

        if (!remainder.empty()) {
          bool preserveSubpath = remainder.find('/') != std::string::npos;

          if (!preserveSubpath) {
            const std::string pkgBaseName = pkgName.substr(pkgName.find_last_of('/') + 1);
            std::string withoutExt = remainder;
            auto dot = withoutExt.rfind('.');
            if (dot != std::string::npos) {
              withoutExt = withoutExt.substr(0, dot);
            }
            std::string withoutPlatform = withoutExt;
            for (const auto& suffix : {std::string(".ios"), std::string(".android"), std::string(".visionos")}) {
              if (EndsWith(withoutPlatform, suffix)) {
                withoutPlatform = withoutPlatform.substr(0, withoutPlatform.size() - suffix.size());
                break;
              }
            }
            const bool isRootLevelMainEntry = withoutPlatform == "index" ||
                                              withoutPlatform == pkgBaseName ||
                                              withoutPlatform.rfind(pkgBaseName + ".", 0) == 0;
            preserveSubpath = !isRootLevelMainEntry;
          }

          if (preserveSubpath) {
            normalized = pkgName + "/" + remainder + querySuffix;
          }
        }

        if (IsScriptLoadingLogEnabled()) {
          Log(@"[import-map][normalize] node_modules: %s -> %s", specifier.c_str(), normalized.c_str());
        }
        return normalized;
      }
    }
  }

  return "";
}

// Look up a specifier in the import map. Supports both exact matches and
// prefix matches (trailing-slash entries like "solid-js/" that map subpaths).
// Returns the mapped URL or empty string if no match.
static std::string LookupImportMap(const std::string& specifier) {
  // 1. Exact match
  auto it = g_importMap.find(specifier);
  if (it != g_importMap.end()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[import-map] exact: %s -> %s", specifier.c_str(), it->second.c_str());
    }
    return it->second;
  }
  // 2. Prefix match (longest match wins)
  std::string bestKey;
  std::string bestValue;
  for (const auto& kv : g_importMap) {
    const std::string& key = kv.first;
    // Prefix entries must end with '/'
    if (key.back() != '/') continue;
    if (specifier.size() > key.size() && specifier.compare(0, key.size(), key) == 0) {
      if (key.size() > bestKey.size()) {
        bestKey = key;
        bestValue = kv.second;
      }
    }
  }
  if (!bestKey.empty()) {
    std::string remainder = specifier.substr(bestKey.size());
    std::string resolved = bestValue + remainder;
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[import-map] prefix: %s -> %s (via %s)", specifier.c_str(), resolved.c_str(), bestKey.c_str());
    }
    return resolved;
  }
  return "";
}

// Escape `s` as a single-quoted JS string literal. Returns the literal
// including the surrounding quotes so call sites can splice it directly
// into a generated source string (e.g. `"foo(" + JsStringLiteral(id) + ")"`).
// Handles backslash, single quote, the JS line terminators (\n, \r,
// U+2028, U+2029), and other ASCII control characters via `\xNN`.
static std::string JsStringLiteral(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  out.push_back('\'');
  for (size_t i = 0; i < s.size(); ) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c == '\\') { out += "\\\\"; ++i; continue; }
    if (c == '\'') { out += "\\'"; ++i; continue; }
    if (c == '\n') { out += "\\n"; ++i; continue; }
    if (c == '\r') { out += "\\r"; ++i; continue; }
    if (c == 0xE2 && i + 2 < s.size() &&
        static_cast<unsigned char>(s[i + 1]) == 0x80 &&
        (static_cast<unsigned char>(s[i + 2]) == 0xA8 ||
         static_cast<unsigned char>(s[i + 2]) == 0xA9)) {
      out += (static_cast<unsigned char>(s[i + 2]) == 0xA8) ? "\\u2028" : "\\u2029";
      i += 3;
      continue;
    }
    if (c < 0x20) {
      char buf[7];
      std::snprintf(buf, sizeof(buf), "\\x%02X", c);
      out += buf;
      ++i;
      continue;
    }
    out.push_back(static_cast<char>(c));
    ++i;
  }
  out.push_back('\'');
  return out;
}

// Helper: returns true if `name` is a valid JS identifier that can appear in
// `export const <name> = ...` without quoting. Conservative check — rejects
// anything that could cause a parse error in the generated ESM wrapper.
static bool IsValidJSIdentifier(const std::string& name) {
  if (name.empty()) return false;
  char first = name[0];
  // Must start with letter, underscore, or $
  if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') ||
        first == '_' || first == '$'))
    return false;
  for (size_t i = 1; i < name.size(); i++) {
    char c = name[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '$'))
      return false;
  }
  return true;
}

// Create an ESM wrapper that re-exports all named exports from the vendor registry.
// The vendor bootstrap (JS side) populates globalThis.__nsVendorRegistry with
// pre-bundled module namespace objects (via `import * as`). This function enumerates
// the actual property names of the vendor module and generates explicit
// `export const X = __mod['X'];` statements so V8's ESM resolution finds every
// named export (e.g. $DEVCOMP, createSignal, createRootRoute, etc.).
static v8::MaybeLocal<v8::Module> ResolveFromVendorRegistry(v8::Isolate* isolate,
                                                             v8::Local<v8::Context> context,
                                                             const std::string& vendorId) {
  // Check cache first
  auto cached = g_vendorModuleCache.find(vendorId);
  if (cached != g_vendorModuleCache.end()) {
    v8::Local<v8::Module> mod = cached->second.Get(isolate);
    if (!mod.IsEmpty() && mod->GetStatus() != v8::Module::kErrored) {
      return mod;
    }
    cached->second.Reset();
    g_vendorModuleCache.erase(cached);
  }

  // ── Step 1: Enumerate export names from the live vendor module ──────────
  // Access globalThis.__nsVendorRegistry (a Map) and call .get(vendorId)
  // to obtain the namespace object, then read its property names.
  std::vector<std::string> exportNames;

  v8::TryCatch tc(isolate);
  do {
    v8::Local<v8::Object> global = context->Global();

    // globalThis.__nsVendorRegistry
    v8::Local<v8::Value> regVal;
    if (!global->Get(context, tns::ToV8String(isolate, "__nsVendorRegistry")).ToLocal(&regVal) ||
        regVal->IsNullOrUndefined()) {
      break;
    }
    v8::Local<v8::Object> registry = regVal.As<v8::Object>();

    // registry.get(vendorId)
    v8::Local<v8::Value> getFnVal;
    if (!registry->Get(context, tns::ToV8String(isolate, "get")).ToLocal(&getFnVal) ||
        !getFnVal->IsFunction()) {
      break;
    }
    v8::Local<v8::Value> getArgs[] = { tns::ToV8String(isolate, vendorId.c_str()) };
    v8::Local<v8::Value> modVal;
    if (!getFnVal.As<v8::Function>()->Call(context, registry, 1, getArgs).ToLocal(&modVal) ||
        modVal->IsNullOrUndefined()) {
      break;
    }

    // Object.keys(mod) — enumerate own property names
    v8::Local<v8::Object> modObj = modVal.As<v8::Object>();
    v8::Local<v8::Array> keys;
    if (!modObj->GetOwnPropertyNames(context).ToLocal(&keys)) {
      break;
    }

    for (uint32_t i = 0; i < keys->Length(); i++) {
      v8::Local<v8::Value> key;
      if (!keys->Get(context, i).ToLocal(&key) || !key->IsString()) continue;
      v8::String::Utf8Value keyUtf8(isolate, key);
      if (!*keyUtf8) continue;
      std::string name(*keyUtf8);
      if (name != "default" && IsValidJSIdentifier(name)) {
        exportNames.push_back(name);
      }
    }
  } while (false);

  if (tc.HasCaught()) {
    tc.Reset(); // Non-fatal; we'll fall back to no named exports
  }

  // ── Step 2: Generate ESM wrapper with explicit named exports ────────────
  std::string moduleKey = "ns-vendor://" + vendorId;
  // Two failure modes are distinguished so the runtime error names the
  // class of problem: registry not yet populated (wrapper evaluated
  // before `installVendorBootstrap()` ran) vs. specifier absent from a
  // populated registry (vendor bundle does not ship this entry).
  // `vendorId` is escaped through `JsStringLiteral` so any character is
  // safe to embed inside the generated JS source.
  const std::string idLiteral = JsStringLiteral(vendorId);
  std::string src =
    "const __reg = globalThis.__nsVendorRegistry;\n"
    "if (!__reg || __reg.size === 0) {\n"
    "  throw new Error('ns-vendor wrapper ' + " + idLiteral +
    " + ' evaluated before __nsVendorRegistry was populated');\n"
    "}\n"
    "const __mod = __reg.get(" + idLiteral + ");\n"
    "if (!__mod) {\n"
    "  throw new Error('ns-vendor specifier ' + " + idLiteral +
    " + ' not in __nsVendorRegistry (' + __reg.size + ' entries)');\n"
    "}\n"
    "export default __mod.default !== undefined ? __mod.default : __mod;\n";

  for (const auto& name : exportNames) {
    src += "export const " + name + " = __mod[" + JsStringLiteral(name) + "];\n";
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[import-map][vendor] generating wrapper for ns-vendor://%s with %lu named exports",
        vendorId.c_str(), (unsigned long)exportNames.size());
  }

  v8::MaybeLocal<v8::Module> m = CompileModuleForResolveRegisterOnly(isolate, context, src, moduleKey);
  if (!m.IsEmpty()) {
    v8::Local<v8::Module> mod;
    if (m.ToLocal(&mod)) {
      g_vendorModuleCache[vendorId].Reset(isolate, mod);
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[import-map][vendor] resolved ns-vendor://%s", vendorId.c_str());
      }
    }
  }
  return m;
}

void CleanupImportMapGlobals() {
  g_importMap.clear();
  g_volatilePatterns.clear();
  for (auto& kv : g_vendorModuleCache) { kv.second.Reset(); }
  g_vendorModuleCache.clear();
  // Also clear fallback registries — they hold v8::Global<Module> handles that
  // would crash during static destructor cleanup if not cleared before isolate disposal.
  for (auto& kv : g_moduleFallbackRegistry) { kv.second.Reset(); }
  g_moduleFallbackRegistry.clear();
  for (auto& kv : g_moduleFallbackByRelative) { kv.second.Reset(); }
  g_moduleFallbackByRelative.clear();
}

// g_modulesInFlight is defined later in this translation unit (thread_local static); no extern needed here.

static bool IsDocumentsPath(const std::string& path);
static std::vector<std::string> DocumentsPathAliases(const std::string& path);
static std::string ExtractRelativePath(const std::string& path);
static void RejectAndClearInvalidatedModuleState(v8::Isolate* isolate,
                                                 v8::Local<v8::Context> context,
                                                 const std::string& registryKey);

// Returns the normalized iOS Documents directory (cached). Empty string if unavailable.
static const std::string& GetDocumentsDirectory() {
  static std::string s_docsDir; // normalized without trailing slash
  if (s_docsDir.empty()) {
    @autoreleasepool {
      NSString* docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      if (docsDir) {
        std::string raw = [docsDir UTF8String];
        std::string norm = NormalizePath(raw);
        // Remove trailing slash if NormalizePath produced one, to have canonical base form
        if (!norm.empty() && norm.back() == '/') {
          norm.pop_back();
        }
        s_docsDir = norm;
      }
    }
  }
  return s_docsDir;
}

void RemoveModuleFromRegistry(const std::string& canonicalPath) {
  const std::string registryKey = CanonicalizeRegistryKey(canonicalPath);
  // Defensive: never operate on an anomalous/sentinel key.
  // This covers the bare "@" anomaly and the special invalid-at stub module used by the dev HTTP loader.
  auto isSentinel = [](const std::string& s) -> bool {
    if (s == "@") return true;
    // Match any path or URL that includes the invalid-at stub filename
    return s.find("__invalid_at__.mjs") != std::string::npos;
  };
  if (isSentinel(registryKey)) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][guard-v3] ignore remove for sentinel %s", registryKey.c_str());
    }
    return;
  }

  // Classification helper for diagnostics
  auto classify = [](const std::string& s) -> const char* {
    if (s == "@") return "sentinel:@";
    if (s.find("__invalid_at__.mjs") != std::string::npos) return "sentinel:invalid_at";
    bool http = StartsWith(s, "http://") || StartsWith(s, "https://");
    if (http) {
      if (IsVolatileUrl(s)) return "http:volatile";
      if (s.find("/@ns/sfc/") != std::string::npos) return "http:sfc";
      if (s.find("/@ns/m/") != std::string::npos) return "http:m";
      return "http:other";
    }
    if (StartsWith(s, "file://")) return "file-url";
    return "path";
  };

  if (IsScriptLoadingLogEnabled()) {
    if (registryKey != canonicalPath) {
      Log(@"[resolver][remove:pre] raw=%s key=%s class=%s", canonicalPath.c_str(), registryKey.c_str(), classify(registryKey));
    } else {
      Log(@"[resolver][remove:pre] key=%s class=%s", registryKey.c_str(), classify(registryKey));
    }
  }

  size_t regPre = g_moduleRegistry.size();
  size_t fbPre = g_moduleFallbackRegistry.size();
  size_t relPre = g_moduleFallbackByRelative.size();

  auto it = g_moduleRegistry.find(registryKey);
  if (it != g_moduleRegistry.end()) {
    // Only log stale removal for non-HTTP keys to avoid noisy dev HTTP churn.
    bool isHttpKey = StartsWith(registryKey, "http://") || StartsWith(registryKey, "https://");
    if (IsScriptLoadingLogEnabled() && !isHttpKey) {
      Log(@"[resolver] removing stale module %@", [NSString stringWithUTF8String:registryKey.c_str()]);
    }
    it->second.Reset();
    g_moduleRegistry.erase(it);
  }
  else if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][remove:miss] key not found, proceed to clear fallbacks (%s)", registryKey.c_str());
  }
  // Also clear fallbacks linked to this path
  auto fb = g_moduleFallbackRegistry.find(registryKey);
  if (fb != g_moduleFallbackRegistry.end()) {
    fb->second.Reset();
    g_moduleFallbackRegistry.erase(fb);
  }
  std::string rel = ExtractRelativePath(registryKey);
  if (!rel.empty()) {
    auto fbr = g_moduleFallbackByRelative.find(rel);
    if (fbr != g_moduleFallbackByRelative.end()) {
      fbr->second.Reset();
      g_moduleFallbackByRelative.erase(fbr);
    }
  }

  if (IsScriptLoadingLogEnabled()) {
    size_t regPost = g_moduleRegistry.size();
    size_t fbPost = g_moduleFallbackRegistry.size();
    size_t relPost = g_moduleFallbackByRelative.size();
    Log(@"[resolver][remove:post] reg %lu→%lu fb %lu→%lu rel %lu→%lu",
        (unsigned long)regPre, (unsigned long)regPost,
        (unsigned long)fbPre, (unsigned long)fbPost,
        (unsigned long)relPre, (unsigned long)relPost);
  }
}

std::vector<std::string> GetLoadedModuleUrls() {
  std::vector<std::string> urls;
  urls.reserve(g_moduleRegistry.size());

  for (const auto& entry : g_moduleRegistry) {
    const std::string& key = entry.first;
    if (key.empty()) continue;
    if (StartsWith(key, "blob:") || key.find("://") != std::string::npos) {
      urls.push_back(key);
    }
  }

  std::sort(urls.begin(), urls.end());
  urls.erase(std::unique(urls.begin(), urls.end()), urls.end());
  return urls;
}

void InvalidateModules(v8::Isolate* isolate, v8::Local<v8::Context> context,
                       const std::vector<std::string>& urls) {
  if (urls.empty()) return;

  std::unordered_set<std::string> seen;
  std::vector<std::string> uniqueUrls;
  uniqueUrls.reserve(urls.size());

  for (const auto& url : urls) {
    if (url.empty()) continue;
    std::string registryKey = CanonicalizeRegistryKey(url);
    if (registryKey.empty()) continue;
    if (!seen.insert(registryKey).second) continue;
    uniqueUrls.push_back(registryKey);
  }

  const bool logScriptLoading = IsScriptLoadingLogEnabled();
  size_t hits = 0, misses = 0;
  for (const auto& url : uniqueUrls) {
    bool present = g_moduleRegistry.find(url) != g_moduleRegistry.end();
    if (present) {
      hits++;
    } else {
      misses++;
    }
    if (logScriptLoading) {
      Log(@"[ns-hmr][ios-invalidate] %s key=%s",
          present ? "HIT " : "MISS",
          url.c_str());
    }

    RejectAndClearInvalidatedModuleState(isolate, context, url);
    RemoveModuleFromRegistry(url);
  }

  // Drop stale HTTP bodies from the speculative-prefetch cache for
  // every URL we just invalidated. Without this, the next
  // `HttpFetchText` for an evicted URL would happily return a stale
  // body the previous wave (or kickstart) left in the cache, and V8
  // would compile that stale source — producing the "1 cycle behind"
  // lag for `.ts` edits with many transitive importers (e.g.
  // constants files). The registry eviction above alone is necessary
  // but not sufficient: V8 calls into the loader for any module no
  // longer in the registry, and the loader's first stop is
  // `g_prefetchCache`. Both caches must be cleared for the next
  // compile to see fresh source.
  EvictHttpModulePrefetchCacheUrls(uniqueUrls);

  if (logScriptLoading) {
    Log(@"[ns-hmr][ios-invalidate] summary unique=%lu hits=%lu misses=%lu (registry now=%lu)",
        (unsigned long)uniqueUrls.size(),
        (unsigned long)hits,
        (unsigned long)misses,
        (unsigned long)g_moduleRegistry.size());
  }
}

void UpdateModuleFallback(v8::Isolate* isolate, const std::string& canonicalPath,
                          v8::Local<v8::Module> module) {
  auto fallbackIt = g_moduleFallbackRegistry.find(canonicalPath);
  if (fallbackIt != g_moduleFallbackRegistry.end()) {
    fallbackIt->second.Reset();
  }
  if (!module.IsEmpty()) {
    g_moduleFallbackRegistry[canonicalPath].Reset(isolate, module);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver] fallback updated for %s from evaluated module",
          canonicalPath.c_str());
    }

    std::string relative = ExtractRelativePath(canonicalPath);
    if (!relative.empty()) {
      auto relativeIt = g_moduleFallbackByRelative.find(relative);
      if (relativeIt != g_moduleFallbackByRelative.end()) {
        relativeIt->second.Reset();
      }
      g_moduleFallbackByRelative[relative].Reset(isolate, module);
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver] fallback relative updated for %s", relative.c_str());
      }
    }

    if (IsDocumentsPath(canonicalPath)) {
      for (const std::string& appAlias : DocumentsPathAliases(canonicalPath)) {
        auto aliasIt = g_moduleFallbackRegistry.find(appAlias);
        if (aliasIt != g_moduleFallbackRegistry.end()) {
          aliasIt->second.Reset();
        }
        g_moduleFallbackRegistry[appAlias].Reset(isolate, module);
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver] fallback alias updated for %s (alias of %s)", appAlias.c_str(),
              canonicalPath.c_str());
        }

        std::string aliasRelative = ExtractRelativePath(appAlias);
        if (!aliasRelative.empty()) {
          auto aliasRelativeIt = g_moduleFallbackByRelative.find(aliasRelative);
          if (aliasRelativeIt != g_moduleFallbackByRelative.end()) {
            aliasRelativeIt->second.Reset();
          }
          g_moduleFallbackByRelative[aliasRelative].Reset(isolate, module);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] fallback relative updated for %s (alias of %s)",
                aliasRelative.c_str(), canonicalPath.c_str());
          }
        }
      }
    }
  }
}

// Track active resolution stack to detect and short-circuit self-recursive module loads
static thread_local std::vector<std::string> g_moduleResolutionStack;
static thread_local std::unordered_map<std::string, size_t> g_moduleReentryCounts;
static thread_local std::unordered_map<std::string, std::unordered_set<std::string>>
  g_moduleReentryParents;
static thread_local std::unordered_map<std::string, std::string> g_modulePrimaryImporters;
static thread_local std::unordered_set<std::string> g_modulesInFlight;
static thread_local std::unordered_set<std::string> g_modulesPendingReset;
// The threshold for detecting circular dependencies during module resolution.
// 256 was chosen as a high enough value to allow deep but legitimate module graphs,
// but low enough to catch runaway recursion or infinite circular imports.
// If a module is re-entered more than this limit, module loading is aborted and
// an error is reported to prevent stack overflow or infinite loops.
static constexpr size_t kMaxModuleReentryCount = 256;
// Waiters: module path -> list of Promise resolvers waiting for completion (instantiated/evaluated or errored)
static std::unordered_map<std::string, std::vector<v8::Global<v8::Promise::Resolver>>> g_moduleWaiters;
// Dynamic HTTP import waiters: resolve to module namespace when available.
static thread_local std::unordered_map<std::string, std::vector<v8::Global<v8::Promise::Resolver>>> g_httpDynamicWaiters;

static bool IsModuleEvaluationInProgress(v8::Module::Status status) {
  return status == v8::Module::kInstantiating || status == v8::Module::kEvaluating;
}

static void ResolveResolversWithModuleNamespace(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    std::vector<v8::Global<v8::Promise::Resolver>>& resolvers,
    v8::Local<v8::Module> module, const std::string& registryKey) {
  if (resolvers.empty()) {
    return;
  }

  if (module.IsEmpty() || module->GetStatus() != v8::Module::kEvaluated) {
    v8::Local<v8::String> errMsg = tns::ToV8String(
        isolate, ("Module did not finish evaluation: " + registryKey).c_str());
    v8::Local<v8::Value> errObj = v8::Exception::Error(errMsg);
    for (auto& resGlobal : resolvers) {
      v8::Local<v8::Promise::Resolver> resolver = resGlobal.Get(isolate);
      if (!resolver.IsEmpty()) {
        resolver->Reject(context, errObj).FromMaybe(false);
      }
      resGlobal.Reset();
    }
    return;
  }

  v8::Local<v8::Value> moduleNamespace = module->GetModuleNamespace();
  for (auto& resGlobal : resolvers) {
    v8::Local<v8::Promise::Resolver> resolver = resGlobal.Get(isolate);
    if (!resolver.IsEmpty()) {
      resolver->Resolve(context, moduleNamespace).FromMaybe(false);
    }
    resGlobal.Reset();
  }
}

static void RejectResolversWithReason(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    std::vector<v8::Global<v8::Promise::Resolver>>& resolvers,
    v8::Local<v8::Value> reason) {
  (void)isolate;
  if (resolvers.empty()) {
    return;
  }

  for (auto& resGlobal : resolvers) {
    v8::Local<v8::Promise::Resolver> resolver = resGlobal.Get(isolate);
    if (!resolver.IsEmpty()) {
      resolver->Reject(context, reason).FromMaybe(false);
    }
    resGlobal.Reset();
  }
}

static bool QueueModuleWaiterIfInFlight(
    v8::Isolate* isolate, const std::string& registryKey,
    v8::Local<v8::Module> module, v8::Local<v8::Promise::Resolver> resolver) {
  if (registryKey.empty() || module.IsEmpty() ||
      !IsModuleEvaluationInProgress(module->GetStatus()) ||
      g_modulesInFlight.find(registryKey) == g_modulesInFlight.end()) {
    return false;
  }

  g_moduleWaiters[registryKey].emplace_back(isolate, resolver);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import][await] queued module waiter for %s status=%s", registryKey.c_str(),
        ModuleStatusToString(module->GetStatus()));
  }
  return true;
}

static bool QueueHttpDynamicWaiterIfInFlight(
    v8::Isolate* isolate, const std::string& registryKey,
    v8::Local<v8::Module> module, v8::Local<v8::Promise::Resolver> resolver) {
  if (registryKey.empty() || module.IsEmpty() ||
      !IsModuleEvaluationInProgress(module->GetStatus()) ||
      g_modulesInFlight.find(registryKey) == g_modulesInFlight.end()) {
    return false;
  }

  g_httpDynamicWaiters[registryKey].emplace_back(isolate, resolver);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import][http-await] queued waiter for %s status=%s",
        registryKey.c_str(), ModuleStatusToString(module->GetStatus()));
  }
  return true;
}

static void ResolveModuleWaiters(v8::Isolate* isolate,
                                 v8::Local<v8::Context> context,
                                 const std::string& registryKey,
                                 v8::Local<v8::Module> module) {
  auto waitIt = g_moduleWaiters.find(registryKey);
  if (waitIt == g_moduleWaiters.end()) {
    return;
  }

  std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
  resolvers.swap(waitIt->second);
  g_moduleWaiters.erase(waitIt);
  ResolveResolversWithModuleNamespace(isolate, context, resolvers, module, registryKey);
}

static void RejectModuleWaiters(v8::Isolate* isolate,
                                v8::Local<v8::Context> context,
                                const std::string& registryKey,
                                v8::Local<v8::Value> reason) {
  auto waitIt = g_moduleWaiters.find(registryKey);
  if (waitIt == g_moduleWaiters.end()) {
    return;
  }

  std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
  resolvers.swap(waitIt->second);
  g_moduleWaiters.erase(waitIt);
  RejectResolversWithReason(isolate, context, resolvers, reason);
}

static void ResolveHttpDynamicWaiters(v8::Isolate* isolate,
                                      v8::Local<v8::Context> context,
                                      const std::string& registryKey,
                                      v8::Local<v8::Module> module) {
  auto waitIt = g_httpDynamicWaiters.find(registryKey);
  if (waitIt != g_httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(waitIt->second);
    g_httpDynamicWaiters.erase(waitIt);
    ResolveResolversWithModuleNamespace(isolate, context, resolvers, module, registryKey);
  }

  g_modulesInFlight.erase(registryKey);
}

static void RejectHttpDynamicWaiters(v8::Isolate* isolate,
                                     v8::Local<v8::Context> context,
                                     const std::string& registryKey,
                                     v8::Local<v8::Value> reason) {
  auto waitIt = g_httpDynamicWaiters.find(registryKey);
  if (waitIt != g_httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(waitIt->second);
    g_httpDynamicWaiters.erase(waitIt);
    RejectResolversWithReason(isolate, context, resolvers, reason);
  }

  g_modulesInFlight.erase(registryKey);
}

static void RejectResolversForInvalidation(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    std::vector<v8::Global<v8::Promise::Resolver>>& resolvers,
    const std::string& registryKey) {
  if (resolvers.empty()) {
    return;
  }

  std::string message = "Module invalidated during dev reload: " + registryKey;
  v8::Local<v8::Value> error = v8::Exception::Error(tns::ToV8String(isolate, message.c_str()));
  for (auto& resolverGlobal : resolvers) {
    v8::Local<v8::Promise::Resolver> resolver = resolverGlobal.Get(isolate);
    if (!resolver.IsEmpty()) {
      resolver->Reject(context, error).FromMaybe(false);
    }
    resolverGlobal.Reset();
  }
}

static void RejectAndClearInvalidatedModuleState(v8::Isolate* isolate,
                                                 v8::Local<v8::Context> context,
                                                 const std::string& registryKey) {
  g_moduleReentryCounts.erase(registryKey);
  g_moduleReentryParents.erase(registryKey);
  g_modulePrimaryImporters.erase(registryKey);
  g_modulesInFlight.erase(registryKey);
  g_modulesPendingReset.erase(registryKey);

  auto waitIt = g_moduleWaiters.find(registryKey);
  if (waitIt != g_moduleWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(waitIt->second);
    g_moduleWaiters.erase(waitIt);
    RejectResolversForInvalidation(isolate, context, resolvers, registryKey);
  }

  auto dynamicWaitIt = g_httpDynamicWaiters.find(registryKey);
  if (dynamicWaitIt != g_httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(dynamicWaitIt->second);
    g_httpDynamicWaiters.erase(dynamicWaitIt);
    RejectResolversForInvalidation(isolate, context, resolvers, registryKey);
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][invalidate-state] cleared in-flight state for %s",
        registryKey.c_str());
  }
}

// Bulk await state + callbacks (non-capturing for V8 function compatibility)
struct BulkWaitState {
  size_t remaining;
  bool rejected;
  v8::Global<v8::Promise::Resolver> master;
};

// Clear waiter maps that hold v8::Global<Promise::Resolver> handles.
// Called from CleanupModuleWaiters() which is invoked by the Runtime destructor.
static bool IsDocumentsPath(const std::string& path) {
  if (path.empty()) return false;
  const std::string& docs = GetDocumentsDirectory();
  if (docs.empty()) {
    // Fallback heuristic (legacy) if we cannot resolve the real Documents dir.
    return path.find("/Documents/") != std::string::npos || path.find("\\Documents\\") != std::string::npos;
  }
  std::string normalizedInput = NormalizePath(path);
  // Fast exact match
  if (normalizedInput == docs) return true;
  // Compare with prefix docs + '/'
  std::string docsPrefix = docs + "/";
  if (normalizedInput.rfind(docsPrefix, 0) == 0) return true;
  return false;
}

static std::vector<std::string> DocumentsPathAliases(const std::string& path) {
  const std::string marker = "/Documents/";
  size_t pos = path.find(marker);
  if (pos == std::string::npos) {
    return {};
  }

  std::string relative = path.substr(pos + marker.size());
  if (relative.empty()) {
    return {};
  }

  std::vector<std::string> candidates;
  auto tryPush = [&candidates](const std::string& p) {
    if (!p.empty()) {
      std::string normalized = NormalizePath(p);
      if (std::find(candidates.begin(), candidates.end(), normalized) == candidates.end()) {
        candidates.push_back(normalized);
      }
    }
  };

  tryPush(RuntimeConfig.ApplicationPath + "/" + relative);
  tryPush(RuntimeConfig.ApplicationPath + "/app/" + relative);

  return candidates;
}

static std::string ExtractRelativePath(const std::string& path) {
  const std::string documentsMarker = "/Documents/";
  size_t docPos = path.find(documentsMarker);
  if (docPos != std::string::npos) {
    return path.substr(docPos + documentsMarker.size());
  }

  std::string appPrefix = NormalizePath(RuntimeConfig.ApplicationPath);
  if (!appPrefix.empty()) {
    // Direct prefix
    std::string directPrefix = appPrefix + "/";
    if (path.rfind(directPrefix, 0) == 0) {
      return path.substr(directPrefix.size());
    }

    // With bundled app folder (…/app/...)
    std::string appFolderPrefix = appPrefix + "/app/";
    if (path.rfind(appFolderPrefix, 0) == 0) {
      return path.substr(appFolderPrefix.size());
    }
  }

  return "";
}

static const char* ModuleStatusToString(v8::Module::Status status) {
  switch (status) {
    case v8::Module::kUninstantiated:
      return "Uninstantiated";
    case v8::Module::kInstantiating:
      return "Instantiating";
    case v8::Module::kInstantiated:
      return "Instantiated";
    case v8::Module::kEvaluating:
      return "Evaluating";
    case v8::Module::kEvaluated:
      return "Evaluated";
    case v8::Module::kErrored:
      return "Errored";
  }
  return "Unknown";
}

namespace {

struct ResolutionStackGuard {
  ResolutionStackGuard(v8::Isolate* isolate, std::vector<std::string>& stack,
                       const std::string& entry)
      : isolate_(isolate), stack_(stack), entry_(entry), active_(true) {
    stack_.push_back(entry_);
    g_moduleReentryCounts[entry_] = 0;
    g_moduleReentryParents.erase(entry_);
    if (stack_.size() > 1) {
      g_modulePrimaryImporters[entry_] = stack_[stack_.size() - 2];
    } else {
      g_modulePrimaryImporters.erase(entry_);
    }
    g_modulesInFlight.insert(entry_);
    g_modulesPendingReset.erase(entry_);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][stack] push (%lu) %s",
          static_cast<unsigned long>(stack_.size()), entry_.c_str());
      if (stack_.size() > 1) {
        Log(@"  ↳ parent: %s", stack_[stack_.size() - 2].c_str());
      }
    }
  }

  ~ResolutionStackGuard() {
    if (active_ && !stack_.empty()) {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][stack] pop (%lu) %s",
            static_cast<unsigned long>(stack_.size()), entry_.c_str());
      }
      g_moduleReentryCounts.erase(entry_);
      g_moduleReentryParents.erase(entry_);
      g_modulePrimaryImporters.erase(entry_);
      g_modulesInFlight.erase(entry_);
      // Determine final status for waiter resolution / rejection
      v8::Module::Status finalStatus = v8::Module::kErrored;
      auto regIt = g_moduleRegistry.find(entry_);
      if (regIt != g_moduleRegistry.end()) {
        v8::Local<v8::Module> m = regIt->second.Get(isolate_);
        if (!m.IsEmpty()) {
          finalStatus = m->GetStatus();
        }
      }
      bool isError = finalStatus == v8::Module::kErrored;
      auto waitIt = g_moduleWaiters.find(entry_);
      if (waitIt != g_moduleWaiters.end()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver][await] settling waiter(s) for %s status=%s",
              entry_.c_str(), ModuleStatusToString(finalStatus));
        }
        v8::Local<v8::Context> currentContext = isolate_->GetCurrentContext();
        if (isError || regIt == g_moduleRegistry.end()) {
          v8::Local<v8::String> errMsg = tns::ToV8String(
              isolate_, ("Module evaluation failed: " + entry_).c_str());
          RejectModuleWaiters(isolate_, currentContext, entry_,
                              v8::Exception::Error(errMsg));
        } else {
          v8::Local<v8::Module> resolvedModule = regIt->second.Get(isolate_);
          ResolveModuleWaiters(isolate_, currentContext, entry_, resolvedModule);
        }
      }
      stack_.pop_back();
      auto pendingIt = g_modulesPendingReset.find(entry_);
      if (pendingIt != g_modulesPendingReset.end()) {
        bool removedFromRegistry = false;
        auto it = g_moduleRegistry.find(entry_);
        if (it != g_moduleRegistry.end()) {
          v8::Local<v8::Module> module = it->second.Get(isolate_);
          v8::Module::Status status = module.IsEmpty() ? v8::Module::kErrored : module->GetStatus();
          if (status != v8::Module::kEvaluated && status != v8::Module::kErrored) {
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[resolver] dropping incomplete module after unwind %s (status=%s)",
                  entry_.c_str(), ModuleStatusToString(status));
            }
            RemoveModuleFromRegistry(entry_);
            removedFromRegistry = true;
          } else if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] module %s marked for reset completed evaluation (status=%s) – keeping for next importer",
                entry_.c_str(), ModuleStatusToString(status));
          }
        } else if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver] pending reset module %s already removed from registry", entry_.c_str());
        }

        g_modulesPendingReset.erase(pendingIt);
        if (!removedFromRegistry && IsScriptLoadingLogEnabled()) {
          Log(@"[resolver] cleared pending reset flag for %s", entry_.c_str());
        }
      }

      auto fallbackIt = g_moduleFallbackRegistry.find(entry_);
      auto activeIt = g_moduleRegistry.find(entry_);
      v8::Local<v8::Module> activeModule;
      v8::Module::Status activeStatus = v8::Module::kErrored;
      bool hasActiveModule = false;
      if (activeIt != g_moduleRegistry.end()) {
        activeModule = activeIt->second.Get(isolate_);
        activeStatus = activeModule.IsEmpty() ? v8::Module::kErrored : activeModule->GetStatus();
        hasActiveModule = true;
      }

      if (hasActiveModule) {
        if (activeStatus == v8::Module::kEvaluated) {
          g_moduleFallbackRegistry[entry_].Reset(isolate_, activeModule);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] updated fallback module for %s after successful evaluation",
                entry_.c_str());
          }
        } else if (activeStatus == v8::Module::kErrored && fallbackIt != g_moduleFallbackRegistry.end()) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] retaining fallback module for %s because active evaluation errored",
                entry_.c_str());
          }
        }
      } else if (fallbackIt != g_moduleFallbackRegistry.end()) {
        v8::Local<v8::Module> fallback = fallbackIt->second.Get(isolate_);
        if (!fallback.IsEmpty()) {
          g_moduleRegistry[CanonicalizeRegistryKey(entry_)].Reset(isolate_, fallback);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] restored fallback module for %s after in-flight reload failed",
                entry_.c_str());
          }
        }
        // Keep the fallback entry so that subsequent imports still have a stable copy.
      }
    }
  }

  // Disable automatic pop if ownership gets transferred (not used currently, but keeps guard safe)
  void Release() { active_ = false; }

 private:
  v8::Isolate* isolate_;
  std::vector<std::string>& stack_;
  std::string entry_;
  bool active_;
};

}  // namespace

// Compile a `.json` file as a synthetic ES module whose default export is
// the parsed JSON value. Handles registry insertion, eager evaluation, and
// the dual debug-vs-release error reporting that the rest of
// `ResolveModuleCallback` uses.
//
// Behaviour-preserving extraction from the inline `.json` branch in
// `ResolveModuleCallback` — keeps the calling site small enough to read
// the resolver's main flow without scrolling past 70 lines of JSON-only
// concerns.
static v8::MaybeLocal<v8::Module> CompileJsonAsEsModule(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::string& absPath, const std::string& registryAbsPath,
    bool isWorker) {
  // Debug: Log JSON module handling for worker context
  if (isWorker) {
    printf("ResolveModuleCallback: Worker handling JSON module '%s'\n", absPath.c_str());
  }

  // Read file contents
  std::string jsonText = tns::ReadText(absPath);

  // Debug: Log JSON content preview for worker context
  if (isWorker) {
    std::string preview = jsonText.length() > 200 ? jsonText.substr(0, 200) + "..." : jsonText;
    printf("ResolveModuleCallback: Worker JSON content preview: %s\n", preview.c_str());
  }

  // Build a small ES module that just exports the parsed JSON as default
  std::string moduleSource = "export default " + jsonText + ";";

  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, moduleSource);
  // Build URL for stack traces
  std::string base = ReplaceAll(absPath, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;

  v8::Local<v8::String> urlString;
  if (!v8::String::NewFromUtf8(isolate, url.c_str(), v8::NewStringType::kNormal)
           .ToLocal(&urlString)) {
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - Failed to create URL string for JSON module");
      return v8::MaybeLocal<v8::Module>();
    } else {
      isolate->ThrowException(v8::Exception::Error(
          tns::ToV8String(isolate, "Failed to create URL string for JSON module")));
      return v8::MaybeLocal<v8::Module>();
    }
  }

  v8::ScriptOrigin origin(isolate, urlString, 0, 0, false, -1, v8::Local<v8::Value>(), false,
                          false, true /* is_module */);

  v8::ScriptCompiler::Source src(sourceText, origin);

  v8::Local<v8::Module> jsonModule;
  if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&jsonModule)) {
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - Failed to compile JSON module");
      return v8::MaybeLocal<v8::Module>();
    } else {
      isolate->ThrowException(
          v8::Exception::SyntaxError(tns::ToV8String(isolate, "Failed to compile JSON module")));
      return v8::MaybeLocal<v8::Module>();
    }
  }

  // No imports inside this module, so instantiate directly
  if (!jsonModule->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
    return v8::MaybeLocal<v8::Module>();
  }

  // Evaluate immediately so namespace is populated
  v8::MaybeLocal<v8::Value> evalResult = jsonModule->Evaluate(context);
  if (evalResult.IsEmpty()) {
    return v8::MaybeLocal<v8::Module>();
  }

  // Store in registry and return - with safe Global handle management
  auto it = g_moduleRegistry.find(registryAbsPath);
  if (it != g_moduleRegistry.end()) {
    // Clear the existing Global handle before replacing it
    it->second.Reset();
  }
  g_moduleRegistry[registryAbsPath].Reset(isolate, jsonModule);
  return v8::MaybeLocal<v8::Module>(jsonModule);
}

// Callback invoked by V8 to resolve `import X from 'specifier';`
v8::MaybeLocal<v8::Module> ResolveModuleCallback(v8::Local<v8::Context> context,
                                                 v8::Local<v8::String> specifier,
                                                 v8::Local<v8::FixedArray> import_assertions,
                                                 v8::Local<v8::Module> referrer) {
  v8::Isolate* isolate = context->GetIsolate();

  // 1) Turn the specifier literal into a std::string:
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const std::string rawSpec = *specUtf8 ? *specUtf8 : "";
  if (rawSpec.empty()) {
    return v8::MaybeLocal<v8::Module>();
  }

  std::string normalizedSpec = rawSpec;

  // Normalize malformed HTTP(S) schemes that sometimes appear as 'http:/host' (single slash)
  // due to upstream path joins or standardization. This ensures our HTTP loader fast-path
  // is used and avoids filesystem fallback attempts like '/app/http:/host'.
  if (normalizedSpec.rfind("http:/", 0) == 0 && normalizedSpec.rfind("http://", 0) != 0) {
    normalizedSpec.insert(5, "/"); // http:/ -> http://
  } else if (normalizedSpec.rfind("https:/", 0) == 0 && normalizedSpec.rfind("https://", 0) != 0) {
    normalizedSpec.insert(6, "/"); // https:/ -> https://
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][spec] %s", normalizedSpec.c_str());
  }

  // Normalize '@/' alias to '/src/' for static imports (mirrors client dynamic import normalization)
  if (normalizedSpec.rfind("@/", 0) == 0) {
    std::string orig = normalizedSpec;
    normalizedSpec = std::string("/src/") + normalizedSpec.substr(2);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][normalize] %@ -> %@", [NSString stringWithUTF8String:orig.c_str()], [NSString stringWithUTF8String:normalizedSpec.c_str()]);
    }
  }
  // Guard against a bare '@' spec showing up (invalid); return empty to avoid poisoning registry with '@'
  if (normalizedSpec == "@") {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][normalize] ignoring invalid '@' static spec");
    }
    return v8::MaybeLocal<v8::Module>();
  }

  const std::string& spec = normalizedSpec; // use normalized spec for the rest of the resolution logic

  // Import map resolution
  // If the import map is populated (set by __nsConfigureRuntime), check it
  // before any other resolution. This is the highest-leverage change from
  // the HMR architecture review: bare specifiers resolve through the map
  // to either vendor URLs or HTTP module URLs, eliminating the need for
  // Vite-side import rewriting.
  //
  // Specifier normalization. Vite rewrites bare specifiers to
  // resolved paths (e.g. "solid-js" → "/node_modules/.vite/deps/solid-js.js").
  // We normalize these back to bare package names so the import map can match
  // them. This ensures a SINGLE instance of every package — no matter how
  // Vite rewrites the import, the import map resolves to the canonical source.
  if (!g_importMap.empty()) {
    std::string mapped = LookupImportMap(spec);

    // If direct lookup failed, try normalizing Vite-rewritten specifiers
    // back to bare package names and look up again.
    if (mapped.empty()) {
      std::string normalized = NormalizeViteSpecifier(spec);
      if (!normalized.empty()) {
        mapped = LookupImportMap(normalized);
        if (!mapped.empty() && IsScriptLoadingLogEnabled()) {
          Log(@"[resolver][import-map] normalized: %s -> %s -> %s",
              spec.c_str(), normalized.c_str(), mapped.c_str());
        }
      }
    }

    if (!mapped.empty()) {
      if (StartsWith(mapped, "ns-vendor://")) {
        // Resolve from in-memory vendor registry (already evaluated by vendor bootstrap)
        std::string vendorId = mapped.substr(12); // strip "ns-vendor://"
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver][import-map] vendor: %s -> %s", spec.c_str(), vendorId.c_str());
        }
        return ResolveFromVendorRegistry(isolate, context, vendorId);
      }
      // Otherwise it mapped to an HTTP URL or other specifier — update spec
      // and fall through to existing resolution (HTTP fast path will pick it up)
      normalizedSpec = mapped;
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][import-map] rewrite: %s -> %s", spec.c_str(), mapped.c_str());
      }
    } else {
      // Diagnostic: bare-looking specifier (no scheme, no '/' prefix, not a
      // relative path) that the import map didn't match.
      // If we hit this path, the runtime is about to fall back
      // to filesystem resolution and almost certainly fail with
      // `Cannot find module ...` for vendor packages — surface it loudly
      // so a missing import map entry shows up in the dev terminal
      // BEFORE the more cryptic `Cannot find module` follow-on.
      bool looksBare = !spec.empty() && spec[0] != '/' && spec[0] != '.' &&
                       spec.find("://") == std::string::npos &&
                       spec.find('\\') == std::string::npos;
      if (looksBare && IsScriptLoadingLogEnabled()) {
        // Snapshot a few entry counts so we can tell at a glance whether
        // `g_importMap` is intact (typical: 200-500 entries) or empty.
        Log(@"[resolver][import-map][miss] bare='%s' importMap.size=%lu importMap.empty=%d",
            spec.c_str(),
            (unsigned long)g_importMap.size(),
            g_importMap.empty() ? 1 : 0);
      }
    }
  } else if (IsScriptLoadingLogEnabled()) {
    // Map was completely empty — distinct from "map populated but no entry".
    // This branch firing means `SetImportMap("")` was called or the map
    // was never populated at all. Either is a bug; surface it.
    bool looksBare = !spec.empty() && spec[0] != '/' && spec[0] != '.' &&
                     spec.find("://") == std::string::npos &&
                     spec.find('\\') == std::string::npos;
    if (looksBare) {
      Log(@"[resolver][import-map][empty] bare='%s' — g_importMap is EMPTY (was it ever configured? expected ~200-500 entries)", spec.c_str());
    }
  }

  // ── Early absolute-HTTP fast path ─────────────────────────────
  // If the specifier itself is an absolute HTTP(S) URL, resolve it immediately via
  // the HTTP loader and return before any filesystem candidate logic runs.
  // Security: HttpFetchText gates remote module access centrally.
  if (StartsWith(spec, "http://") || StartsWith(spec, "https://")) {
    return LoadHttpModuleForUrl(isolate, context, spec);
  }

  // Debug: Log all module resolution attempts, especially for @nativescript/core/globals
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache->isWorker) {
    if (IsScriptLoadingLogEnabled()) {
      Log("ResolveModuleCallback: Worker trying to resolve '%s'\n", spec.c_str());
    }
  }

  // 2) Find which filepath the referrer was compiled under
  std::string referrerPath;
  for (auto& kv : g_moduleRegistry) {
    v8::Local<v8::Module> registered = kv.second.Get(isolate);
    if (registered == referrer) {
      referrerPath = kv.first;
      break;
    }
  }
  // If we couldn't identify the referrer (e.g. coming from a dynamic import
  // where the embedder did not pass the compiled Module), we can still proceed
  // for absolute and application-rooted specifiers. Only bail out early when
  // the specifier is clearly relative (starts with "./" or "../") and we
  // would need the referrer's directory to resolve it.
  bool specIsRelative = !spec.empty() && spec[0] == '.';
  if (referrerPath.empty() && specIsRelative) {
    // For dynamic imports, assume the base directory is the application root
    // This handles cases where runtime.mjs calls import("./chunk.mjs")
    // but the referrer module isn't properly registered
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver] No referrer found for relative import '%s', assuming app root",
          spec.c_str());
    }
    referrerPath =
        RuntimeConfig.ApplicationPath + "/runtime.mjs";  // Default to runtime.mjs as referrer
  }

  // 3) Compute its directory
  size_t slash = referrerPath.find_last_of("/\\");
  std::string baseDir = slash == std::string::npos ? "" : referrerPath.substr(0, slash + 1);

  // If the referrer itself was compiled from an HTTP(S) URL, then any relative
  // ("./" or "../") or root-absolute ("/") specifiers should resolve against the
  // referrer's URL, not the local filesystem. Mirror browser behavior by using NSURL
  // to construct the absolute URL, then return an HTTP-loaded module immediately.
  // Security: HttpFetchText gates remote module access centrally.
  bool referrerIsHttp = (!referrerPath.empty() && (StartsWith(referrerPath, "http://") || StartsWith(referrerPath, "https://")));
  bool specIsRootAbs = !spec.empty() && spec[0] == '/';
  if (referrerIsHttp && (specIsRelative || specIsRootAbs)) {
    std::string resolvedHttp;
    @autoreleasepool {
      NSString* baseStr = [NSString stringWithUTF8String:referrerPath.c_str()];
      NSString* specStr = [NSString stringWithUTF8String:spec.c_str()];
      if (baseStr && specStr) {
        NSURL* baseURL = [NSURL URLWithString:baseStr];
        NSURL* rel = [NSURL URLWithString:specStr relativeToURL:baseURL];
        NSURL* absURL = [rel absoluteURL];
        if (absURL) {
          NSString* absStr = [absURL absoluteString];
          if (absStr) {
            resolvedHttp = std::string([absStr UTF8String] ?: "");
          }
        }
      }
    }
    if (!resolvedHttp.empty() && (StartsWith(resolvedHttp, "http://") || StartsWith(resolvedHttp, "https://"))) {
      // Security: HttpFetchText gates remote module access centrally.
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][http-rel] base=%s spec=%s -> %s", referrerPath.c_str(), spec.c_str(), resolvedHttp.c_str());
      }
      return LoadHttpModuleForUrl(isolate, context, resolvedHttp);
    }
  }

  // 4) Resolve the import specifier relative to that directory.
  //    The incoming specifier may omit the file extension (e.g. "./foo") or
  //    point to a directory.  Try to follow Node-style resolution rules for
  //    the most common cases so that we locate the actual .mjs file on disk
  //    before handing the path to LoadScript.

  // ────────────────────────────────────────────────
  // Build initial absolute path candidates
  // ────────────────────────────────────────────────

  std::vector<std::string> candidateBases;

  if (!spec.empty() && spec[0] == '.') {
    // Relative import (./ or ../)
      std::string cleanSpec = spec.rfind("./", 0) == 0 ? spec.substr(2) : spec;
      // Join baseDir and spec using NSString to collapse dot segments reliably
      @autoreleasepool {
        NSString* nsBase = [NSString stringWithUTF8String:baseDir.c_str()];
        NSString* nsRel = [NSString stringWithUTF8String:cleanSpec.c_str()];
        if (nsBase && nsRel) {
          NSString* joined = [nsBase stringByAppendingPathComponent:nsRel];
          NSString* std = [joined stringByStandardizingPath];
          if (std) {
            std::string candidate = std.UTF8String;
            candidate = NormalizePath(candidate);
            candidateBases.push_back(candidate);
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[resolver][normalize-rel] %s + %s -> %s", baseDir.c_str(), cleanSpec.c_str(), candidate.c_str());
            }
          }
        }
      }

    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver] Relative import: '%s' + '%s' -> '%s'", baseDir.c_str(), cleanSpec.c_str(),
          candidateBases.empty() ? "<none>" : candidateBases.back().c_str());
    }
  } else if (spec.rfind("file://", 0) == 0) {
    // Absolute file URL, e.g. file:///app/path/to/chunk.mjs
    std::string tail = spec.substr(7);  // strip file://
    if (tail.rfind("/", 0) != 0) {
      tail = "/" + tail;
    }
    // If starts with /app/... drop the leading /app
    const std::string appPrefix = "/app/";
    std::string tailNoApp = tail;
    if (tail.rfind(appPrefix, 0) == 0) {
      tailNoApp = tail.substr(appPrefix.size());
    }
    // Candidate that keeps /app/ prefix stripped
    std::string baseNoApp = NormalizePath(RuntimeConfig.ApplicationPath + "/" + tailNoApp);
    candidateBases.push_back(baseNoApp);

    // Also try path with original tail (includes /app/...) directly under application dir
    std::string baseWithApp = NormalizePath(RuntimeConfig.ApplicationPath + tail);
    candidateBases.push_back(baseWithApp);
  } else if (!spec.empty() && spec[0] == '~') {
    // Alias to application root using ~/path
    std::string tail = spec.size() >= 2 && spec[1] == '/' ? spec.substr(2) : spec.substr(1);
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + "/" + tail);
    candidateBases.push_back(base);

    // Also try ApplicationPath/app for projects that bundle JS under an app folder
    std::string baseApp = NormalizePath(RuntimeConfig.ApplicationPath + "/app/" + tail);
    if (baseApp != base) {
      candidateBases.push_back(baseApp);
    }

    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][tilde] spec=%s base=%s appBase=%s",
          spec.c_str(), base.c_str(), baseApp.c_str());
    }

    // Debug: Log tilde resolution for worker context
    if (cache->isWorker) {
      if (IsScriptLoadingLogEnabled()) {
        Log("ResolveModuleCallback: Worker resolving tilde path '%s' -> '%s'\n", spec.c_str(),
             base.c_str());
      }
    }
  } else if (!spec.empty() && spec[0] == '/') {
    // Absolute path within the bundle (e.g., /app/..., /src/...)
    // Resolve against the application directory and try both with and without the '/app' prefix.
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + spec);
    candidateBases.push_back(base);

    const std::string appPrefix = "/app/";
    if (spec.rfind(appPrefix, 0) == 0) {
      std::string tailNoApp = spec.substr(appPrefix.size() - 1); // keep leading '/'
      // spec starts with '/app/...', so tailNoApp becomes '/...'
      std::string baseNoApp = NormalizePath(RuntimeConfig.ApplicationPath + tailNoApp);
      if (baseNoApp != base) {
        candidateBases.push_back(baseNoApp);
      }
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][abs] spec=%s base=%s baseNoApp=%s",
            spec.c_str(), base.c_str(), baseNoApp.c_str());
      }
    } else if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][abs] spec=%s base=%s", spec.c_str(), base.c_str());
    }
  } else {
    // Bare specifier – resolve relative to the application root directory
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + "/" + spec);
    candidateBases.push_back(base);

    // Additional heuristic: bundlers often encode path separators as underscores in
    // chunk IDs (e.g. "src_app_components_foo_bar_ts.mjs").  Try converting
    // those underscores back to slashes and look for that file as well.
    std::string withSlashes = spec;
    std::replace(withSlashes.begin(), withSlashes.end(), '_', '/');
    std::string baseSlashes = NormalizePath(RuntimeConfig.ApplicationPath + "/" + withSlashes);
    if (baseSlashes != base) {
      candidateBases.push_back(baseSlashes);
    }
  }

  // We'll iterate these bases and attempt to resolve to an actual file
  std::string absPath;

  // If the specifier is an HTTP(S) URL, fetch via HTTP loader and return
  // Security: HttpFetchText gates remote module access centrally.
  if (StartsWith(spec, "http://") || StartsWith(spec, "https://")) {
    return LoadHttpModuleForUrl(isolate, context, spec);
  }

  // Utility: returns true iff `p` exists AND is a regular file (not directory)
  auto isFile = [](const std::string& p) -> bool {
    std::string normalized = NormalizePath(p);
    struct stat st;
    if (stat(normalized.c_str(), &st) != 0) {
      return false;
    }
    return (st.st_mode & S_IFMT) == S_IFREG;
  };

  // Helper to append extension if missing
  auto withExt = [](const std::string& p, const std::string& ext) -> std::string {
    if (p.size() >= ext.size() && p.compare(p.size() - ext.size(), ext.size(), ext) == 0) {
      return p;
    }
    return p + ext;
  };

  //  ── Resolution attempts ───────────────────────────────────────
  // Iterate base candidates until we find a file match
  for (const std::string& baseCandidate : candidateBases) {
    absPath = NormalizePath(baseCandidate);

    // If a candidate accidentally embeds a collapsed HTTP URL like '/app/http:/host/...',
    // reconstruct the HTTP URL and resolve via the HTTP loader instead of touching the filesystem.
    // Security: HttpFetchText gates remote module access centrally.
    auto rerouteHttpIfEmbedded = [&](const std::string& p,
                                    v8::MaybeLocal<v8::Module>* moduleOut) -> bool {
      size_t pos1 = p.find("/http:/");
      size_t pos2 = p.find("/https:/");
      size_t pos = std::min(pos1 == std::string::npos ? SIZE_MAX : pos1,
                            pos2 == std::string::npos ? SIZE_MAX : pos2);
      if (pos == SIZE_MAX) return false;
      std::string tail = p.substr(pos + 1); // 'http:/...' or 'https:/...'
      if (StartsWith(tail, "http:/") && !StartsWith(tail, "http://")) {
        tail.insert(5, "/");
      } else if (StartsWith(tail, "https:/") && !StartsWith(tail, "https://")) {
        tail.insert(6, "/");
      }
      if (!(StartsWith(tail, "http://") || StartsWith(tail, "https://"))) return false;

      if (IsScriptLoadingLogEnabled()) { Log(@"[resolver][http-embedded] %s -> %s", p.c_str(), tail.c_str()); }
      if (moduleOut != nullptr) {
        *moduleOut = LoadHttpModuleForUrl(isolate, context, tail);
      }
      return true;
    };
    v8::MaybeLocal<v8::Module> embeddedHttpModule;
    if (rerouteHttpIfEmbedded(absPath, &embeddedHttpModule)) {
      return embeddedHttpModule;
    }

    bool existsNow = isFile(absPath);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver] %s -> %s", absPath.c_str(), existsNow ? "file" : "missing");
    }

    if (!existsNow) {
      // 1) Try adding .mjs, .js
      const char* exts[] = {".mjs", ".js"};
      bool found = false;
      for (const char* e : exts) {
        std::string cand = NormalizePath(withExt(absPath, e));
        if (isFile(cand)) {
          absPath = cand;
          found = true;
          break;
        }
      }
      if (!found) {
        // 2) If absPath is directory, look for index files
        const char* idxExts[] = {"/index.mjs", "/index.js"};
        for (const char* idx : idxExts) {
          std::string cand = NormalizePath(absPath + idx);
          if (isFile(cand)) {
            absPath = cand;
            found = true;
            break;
          }
        }
      }
      if (found) {
        break;
      }
    }
    if (isFile(absPath)) {
      break;  // stop at first hit
    }
  }

  // At this point, absPath is either a valid file or last attempted candidate.

  // If we still didn't resolve to an actual file, surface an exception instead
  // of letting ReadModule() assert while trying to open a directory.
  if (!isFile(absPath)) {
    // Generic dynamic fetch mirror fallback: if spec is absolute (starts with '/') and not in node_modules,
    // attempt Documents/_ns_hmr + spec (normalized) + .mjs. This does not assume any project folder names.
    if (!spec.empty() && spec[0] == '/' && spec.find("node_modules") == std::string::npos && spec.find("_ns_hmr") == std::string::npos) {
      // Generic dynamic fetch mirror fallback: only for logical app-root paths (e.g., /src, /core, /app, /utils, /components)
      // Avoid misclassifying arbitrary filesystem absolute paths.
      bool looksLogicalApp = false;
      if (!spec.empty() && spec[0] == '/' && spec.find("node_modules") == std::string::npos && spec.find("_ns_hmr") == std::string::npos) {
        if (spec.rfind("/src/", 0) == 0 || spec.rfind("/core/", 0) == 0 || spec.rfind("/app/", 0) == 0 ||
            spec.rfind("/utils/", 0) == 0 || spec.rfind("/components/", 0) == 0) {
          looksLogicalApp = true;
        }
      }
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][mirror-consider] spec=%s looksApp=%s", spec.c_str(), looksLogicalApp ? "true" : "false");
      }
      if (looksLogicalApp) {
        std::string logical = spec; // e.g. /whatever/path/file.ts
        std::string baseNoQuery = logical;
        size_t qpos = baseNoQuery.find_first_of("?#");
        if (qpos != std::string::npos) baseNoQuery = baseNoQuery.substr(0, qpos);
        // Strip a terminal .ts/.js when constructing mirror .mjs candidate
        std::string noExt = baseNoQuery;
        // Handle variable-length extensions: .ts, .js, .tsx, .jsx, .mts, .cts
        const std::vector<std::string> knownExts = {".ts", ".js", ".tsx", ".jsx", ".mts", ".cts"};
        for (const auto& ext : knownExts) {
          if (EndsWith(noExt, ext)) {
            noExt = noExt.substr(0, noExt.size() - ext.size());
            break;
          }
        }
        // Use cached Documents directory (generic dynamic fetch mirror fallback)
        const std::string& docsRootBase = GetDocumentsDirectory();
        std::string mirrorMjs;
        if (!docsRootBase.empty()) {
          mirrorMjs = docsRootBase + "/_ns_hmr" + noExt + ".mjs"; // canonical transform output location
        }
        if (isFile(mirrorMjs)) {
          absPath = mirrorMjs;
          if (IsScriptLoadingLogEnabled()) { Log(@"[resolver][mirror] generic %s -> %s", spec.c_str(), absPath.c_str()); }
        }
      }
    }
  }
  absPath = NormalizePath(absPath);
  const std::string registryAbsPath = CanonicalizeRegistryKey(absPath);

  if (!isFile(absPath)) {
    // Debug: Log resolution failure for worker context
    if (cache->isWorker) {
      printf("ResolveModuleCallback: Worker failed to resolve '%s' -> '%s'\n", spec.c_str(),
             absPath.c_str());
    }

    // Check if this is a Node.js built-in module (e.g., node:url)
    if (IsNodeBuiltinModule(spec)) {
      // Strip the "node:" prefix and create an in-memory polyfill module.
      std::string builtinName = spec.substr(5);  // Remove "node:" prefix

      // Use a virtual key for registry
      std::string key = std::string("node:") + builtinName;

      auto itExisting = g_moduleRegistry.find(key);
      if (itExisting != g_moduleRegistry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
          return v8::MaybeLocal<v8::Module>(existing);
        }
        RemoveModuleFromRegistry(key);
      }

      std::string polyfillContent;
      if (builtinName == "url") {
        // Polyfill for node:url with fileURLToPath/pathToFileURL
        polyfillContent =
            "// In-memory polyfill for node:url\n"
            "export function fileURLToPath(url) {\n"
            "  if (typeof url === 'string') {\n"
            "    if (url.startsWith('file://')) {\n"
            "      return decodeURIComponent(url.slice(7));\n"
            "    }\n"
            "    return url;\n"
            "  }\n"
            "  if (url && typeof url.href === 'string') {\n"
            "    return fileURLToPath(url.href);\n"
            "  }\n"
            "  throw new Error('Invalid URL');\n"
            "}\n"
            "\n"
            "export function pathToFileURL(path) {\n"
            "  const encoded = encodeURIComponent(path).replace(/%2F/g, '/');\n"
            "  return new URL('file://' + encoded);\n"
            "}\n";
      } else {
        // Generic polyfill for other Node.js built-in modules
        polyfillContent =
            "// In-memory polyfill for node:" + builtinName + "\n" +
            "console.warn('Node.js built-in module \\'node:" + builtinName +
            "\\' is not fully supported in NativeScript');\n" +
            "export default {};\n";
      }

      v8::MaybeLocal<v8::Module> m =
          CompileModuleForResolveRegisterOnly(isolate, context, polyfillContent, key);
      if (!m.IsEmpty()) {
        v8::Local<v8::Module> mod;
        if (m.ToLocal(&mod)) {
          return m;
        }
      }

      std::string msg = "Cannot find module " + spec + " (failed to create in-memory polyfill)";
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - Node.js polyfill creation failed: %s", msg.c_str());
        return v8::MaybeLocal<v8::Module>();
      } else {
        isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
        return v8::MaybeLocal<v8::Module>();
      }
    } else if (IsLikelyOptionalModule(spec)) {
      // Treat bare specifiers as optional modules with an in-memory placeholder ES module
      // that throws on property access. This avoids bundle writes in iOS release builds.

      std::string key = std::string("optional:") + spec;
      auto itExisting = g_moduleRegistry.find(key);
      if (itExisting != g_moduleRegistry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
          return v8::MaybeLocal<v8::Module>(existing);
        }
        RemoveModuleFromRegistry(key);
      }

        std::string placeholderContent =
            "const error = new Error(\"Module '" + spec +
            "' is not available. This is an optional module.\");\n"
            "const proxy = new Proxy({}, {\n"
            "  get: function(target, prop) { throw error; },\n"
            "  set: function(target, prop, value) { throw error; },\n"
            "  has: function(target, prop) { return false; },\n"
            "  ownKeys: function(target) { return []; },\n"
            "  getPrototypeOf: function(target) { return null; }\n"
            "});\n"
            "export default proxy;\n";

      v8::MaybeLocal<v8::Module> m =
          CompileModuleForResolveRegisterOnly(isolate, context, placeholderContent, key);
      if (!m.IsEmpty()) {
        v8::Local<v8::Module> mod;
        if (m.ToLocal(&mod)) {
          return m;
        }
      }

      std::string msg = "Cannot find module " + spec + " (failed to create in-memory optional placeholder)";
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - Optional module placeholder creation failed: %s", msg.c_str());
        return v8::MaybeLocal<v8::Module>();
      } else {
        isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
        return v8::MaybeLocal<v8::Module>();
      }
    } else {
      // Not an optional module, throw the original error
      std::string msg = "Cannot find module " + spec + " (tried " + absPath + ")";
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - Module not found: %s", msg.c_str());
        // Return empty instead of crashing in debug mode
        return v8::MaybeLocal<v8::Module>();
      } else {
        isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
        return v8::MaybeLocal<v8::Module>();
      }
    }
  }

  // Special handling for JSON imports (e.g. import data from './foo.json' assert {type:'json'})
  if (absPath.size() >= 5 && absPath.compare(absPath.size() - 5, 5, ".json") == 0) {
    return CompileJsonAsEsModule(isolate, context, absPath, registryAbsPath, cache->isWorker);
  }

  // 5) If we've already compiled that module (non-JSON case), return it
  auto it = g_moduleRegistry.find(registryAbsPath);
  if (it != g_moduleRegistry.end()) {
    v8::Local<v8::Module> existing = it->second.Get(isolate);
    v8::Module::Status status = existing.IsEmpty() ? v8::Module::kErrored : existing->GetStatus();
    bool inCurrentStack =
        std::find(g_moduleResolutionStack.begin(), g_moduleResolutionStack.end(), registryAbsPath) !=
        g_moduleResolutionStack.end();

    bool shouldReuse = !existing.IsEmpty() && status != v8::Module::kErrored;
    if (shouldReuse && (status == v8::Module::kUninstantiated || status == v8::Module::kInstantiating ||
                        status == v8::Module::kEvaluating)) {
      // If we hit an old cached module that never finished evaluating and we're not currently
      // instantiating it (no stack entry), drop it so we can rebuild cleanly.
      if (!inCurrentStack) {
        shouldReuse = false;
      }
    }

    // ───────────────────────────────────────────────────────────────
    // HMR GATING: Prevent secondary importers from touching in-flight modules.
    // We consider a module "in-flight" if it is unfinished AND a primary importer
    // has been recorded. The first importer establishing ownership is allowed.
    // Subsequent importers are gated until evaluation completes, to avoid V8
    // resolving partially-instantiated dependency graphs that can crash.
    // A developer can disable this behavior by setting `hmrAllowConcurrentModules` = true
    // in nativescript.config (package.json). In that case we fall back to prior logic.
    bool gatingDisabled = false;
    {
      id gatingFlag = Runtime::GetAppConfigValue("hmrAllowConcurrentModules");
      if (gatingFlag && [gatingFlag respondsToSelector:@selector(boolValue)]) {
        gatingDisabled = [gatingFlag boolValue];
      }
    }
    static std::atomic<size_t> g_hmrModuleGatedCount {0};

    size_t reentryCount = 0;
    bool unfinished = status == v8::Module::kUninstantiated || status == v8::Module::kInstantiating ||
            status == v8::Module::kEvaluating;
    bool moduleInFlight = g_modulesInFlight.find(registryAbsPath) != g_modulesInFlight.end();
    bool pendingReset = g_modulesPendingReset.find(registryAbsPath) != g_modulesPendingReset.end();
    bool treatAsRecursive = false;
    const std::string parentKey = referrerPath.empty() ? "<anonymous>" : referrerPath;

    if (shouldReuse && status != v8::Module::kEvaluated) {
      if (moduleInFlight) {
        auto& parentSet = g_moduleReentryParents[registryAbsPath];
        bool isSelfImport = !referrerPath.empty() && referrerPath == registryAbsPath;
        bool hasParentInfo = !parentKey.empty() && parentKey != "<anonymous>";
        bool isDynamicDocumentsModule = IsDocumentsPath(absPath);
        bool parentAlreadyRecorded = false;

        if (hasParentInfo) {
          parentAlreadyRecorded = !parentSet.insert(parentKey).second;
        } else {
          parentAlreadyRecorded = true;
        }

        auto primaryIt = g_modulePrimaryImporters.find(registryAbsPath);
        if (hasParentInfo && primaryIt == g_modulePrimaryImporters.end()) {
          g_modulePrimaryImporters[registryAbsPath] = parentKey;
          primaryIt = g_modulePrimaryImporters.find(registryAbsPath);
        }

        if (isSelfImport) {
          treatAsRecursive = true;
        } else if (isDynamicDocumentsModule && hasParentInfo && primaryIt != g_modulePrimaryImporters.end()) {
          const std::string& primaryImporter = primaryIt->second;
          if (parentKey == primaryImporter) {
            parentAlreadyRecorded = false;  // Owner re-entry is expected during evaluation.
          } else {
            // gating block—only applied for dynamic Documents modules when unfinished.
            if (!gatingDisabled && unfinished) {
              g_hmrModuleGatedCount.fetch_add(1, std::memory_order_relaxed);
              if (IsScriptLoadingLogEnabled()) {
                Log(@"[resolver] ⛔ gating unfinished module %s (status=%s) from secondary importer=%s (owner=%s) gatedCount=%lu",
                    absPath.c_str(), ModuleStatusToString(status), parentKey.c_str(), primaryImporter.c_str(), (unsigned long)g_hmrModuleGatedCount.load());
              }
              // Throw a lightweight, recognizable transient error so JS side can detect and retry.
              if (RuntimeConfig.IsDebug) {
                v8::Local<v8::String> msgStr = tns::ToV8String(isolate, ("NS_HMR_MODULE_IN_FLIGHT: " + absPath).c_str());
                v8::Local<v8::Value> errVal = v8::Exception::Error(msgStr);
                if (errVal->IsObject()) {
                  v8::Local<v8::Object> errObj = errVal.As<v8::Object>();
                  errObj->Set(isolate->GetCurrentContext(), tns::ToV8String(isolate, "__nsModulePath"), tns::ToV8String(isolate, absPath.c_str())).FromMaybe(false);
                  errObj->Set(isolate->GetCurrentContext(), tns::ToV8String(isolate, "__nsModuleStatus"), tns::ToV8String(isolate, ModuleStatusToString(status))).FromMaybe(false);
                }
                isolate->ThrowException(errVal);
              }
              // OPTIONAL: if global hook __nsRegisterHmrWaiter(path, fn) exists (JS can set it), we create
              // a callback holder now; JS may pass a function later. This keeps extension flexible without
              // hard coupling a JS API right now.
              // (Future: expose a proper C++ binding to push a resolver promise.)
              return v8::MaybeLocal<v8::Module>();
            }
            if (unfinished && IsScriptLoadingLogEnabled()) {
              Log(@"[resolver] sharing in-flight HMR module %s with requester=%s (owner=%s)",
                  absPath.c_str(), parentKey.c_str(), primaryImporter.c_str());
            }
            v8::Local<v8::Module> fallback;
            if (unfinished) {
              auto fallbackIt = g_moduleFallbackRegistry.find(registryAbsPath);
              if (fallbackIt != g_moduleFallbackRegistry.end()) {
                fallback = fallbackIt->second.Get(isolate);
              }

              std::string relative = ExtractRelativePath(absPath);
              if (fallback.IsEmpty() && !relative.empty()) {
                auto relativeIt = g_moduleFallbackByRelative.find(relative);
                if (relativeIt != g_moduleFallbackByRelative.end()) {
                  fallback = relativeIt->second.Get(isolate);
                }
              }

              if (fallback.IsEmpty()) {
                for (const std::string& alias : DocumentsPathAliases(absPath)) {
                  if (fallback.IsEmpty()) {
                    auto aliasFallbackIt = g_moduleFallbackRegistry.find(alias);
                    if (aliasFallbackIt != g_moduleFallbackRegistry.end()) {
                      fallback = aliasFallbackIt->second.Get(isolate);
                    }
                  }

                  if (fallback.IsEmpty()) {
                    std::string aliasRelative = ExtractRelativePath(alias);
                    if (!aliasRelative.empty()) {
                      auto aliasRelativeIt = g_moduleFallbackByRelative.find(aliasRelative);
                      if (aliasRelativeIt != g_moduleFallbackByRelative.end()) {
                        fallback = aliasRelativeIt->second.Get(isolate);
                      }
                    }
                  }

                  if (fallback.IsEmpty()) {
                    auto aliasRegIt = g_moduleRegistry.find(CanonicalizeRegistryKey(alias));
                    if (aliasRegIt != g_moduleRegistry.end()) {
                      v8::Local<v8::Module> aliasModule = aliasRegIt->second.Get(isolate);
                      if (!aliasModule.IsEmpty() && aliasModule->GetStatus() == v8::Module::kEvaluated) {
                        fallback = aliasModule;
                      }
                    }
                  }

                  if (!fallback.IsEmpty()) {
                    g_moduleFallbackRegistry[registryAbsPath].Reset(isolate, fallback);
                    if (!relative.empty()) {
                      g_moduleFallbackByRelative[relative].Reset(isolate, fallback);
                    }
                    break;
                  }
                }
              }
            }

            if (unfinished && !fallback.IsEmpty()) {
              if (IsScriptLoadingLogEnabled()) {
                Log(@"[resolver] returning fallback module for %s to requester=%s while owner=%s completes",
                    absPath.c_str(), parentKey.c_str(), primaryImporter.c_str());
              }
              return v8::MaybeLocal<v8::Module>(fallback);
            } else if (unfinished && IsScriptLoadingLogEnabled()) {
              Log(@"[resolver] no fallback available for %s while owner=%s evaluates – waiting on primary",
                  absPath.c_str(), primaryImporter.c_str());
            }
            parentAlreadyRecorded = false;  // Do not treat as recursion; we will refresh post-eval.
          }
        }

        if (!isDynamicDocumentsModule && (parentAlreadyRecorded || !hasParentInfo)) {
          treatAsRecursive = true;
        } else if (isDynamicDocumentsModule && !hasParentInfo) {
          treatAsRecursive = true;
        }
      }

      if (treatAsRecursive) {
        auto reentryIt = g_moduleReentryCounts.find(registryAbsPath);
        if (reentryIt != g_moduleReentryCounts.end()) {
          reentryCount = ++reentryIt->second;
        } else {
          reentryCount = ++g_moduleReentryCounts[registryAbsPath];
        }

        if (reentryCount > kMaxModuleReentryCount) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] ⚠️ module %s exceeded re-entry limit (%lu) while status=%s",
                absPath.c_str(), static_cast<unsigned long>(reentryCount), ModuleStatusToString(status));
          }
          RemoveModuleFromRegistry(absPath);
          isolate->ThrowException(v8::Exception::Error(
              tns::ToV8String(isolate,
                               ("Detected circular module dependency while loading " + absPath)
                                   .c_str())));
          return v8::MaybeLocal<v8::Module>();
        }

        if (unfinished && moduleInFlight && reentryCount > 0) {
          g_modulesPendingReset.insert(registryAbsPath);
          pendingReset = true;
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[resolver] scheduling reset for unfinished module %s (status=%s, re-entry=%lu)",
                absPath.c_str(), ModuleStatusToString(status),
                static_cast<unsigned long>(reentryCount));
          }
        }
      } else {
        auto existingCountIt = g_moduleReentryCounts.find(registryAbsPath);
        if (existingCountIt != g_moduleReentryCounts.end()) {
          reentryCount = existingCountIt->second;
        }
      }
    }
    if (shouldReuse && pendingReset) {
      if (moduleInFlight) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver] module %s awaiting reset is still in-flight; deferring drop (status=%s)",
              absPath.c_str(), ModuleStatusToString(status));
        }
      } else {
        shouldReuse = false;
        g_modulesPendingReset.erase(registryAbsPath);
        g_modulePrimaryImporters.erase(registryAbsPath);
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[resolver] dropping module awaiting reset %s (status=%s)", absPath.c_str(),
              ModuleStatusToString(status));
        }
      }
    }

    if (IsScriptLoadingLogEnabled()) {
      const char* statusStr = existing.IsEmpty() ? "<empty>" : ModuleStatusToString(status);
      Log(@"[resolver] cache hit %s (status=%s)%s", absPath.c_str(), statusStr,
          shouldReuse ? "" : " – dropping stale entry");
      if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kEvaluated && shouldReuse) {
        if (reentryCount > 0) {
          Log(@"  ↳ returning module before evaluation (status=%s, re-entry=%lu)", statusStr,
              static_cast<unsigned long>(reentryCount));
        } else {
          Log(@"  ↳ returning module before evaluation (status=%s)", statusStr);
        }
        if (moduleInFlight) {
          auto primaryIt = g_modulePrimaryImporters.find(registryAbsPath);
          const char* owner = primaryIt != g_modulePrimaryImporters.end() ? primaryIt->second.c_str() : "<unknown>";
          Log(@"  ↳ module still evaluating; primary importer=%s, requester=%s", owner,
              parentKey.c_str());
        }
      }
      if (!g_moduleResolutionStack.empty()) {
        Log(@"  ↳ current stack depth %lu", static_cast<unsigned long>(g_moduleResolutionStack.size()));
      }
    }

    if (shouldReuse) {
      if (cache->isWorker) {
        printf("ResolveModuleCallback: Worker found cached module '%s' -> '%s'\n", spec.c_str(),
               absPath.c_str());
      }
      return v8::MaybeLocal<v8::Module>(existing);
    }

    if (!existing.IsEmpty() && status == v8::Module::kEvaluated) {
      auto fallbackIt = g_moduleFallbackRegistry.find(registryAbsPath);
      if (fallbackIt != g_moduleFallbackRegistry.end()) {
        fallbackIt->second.Reset();
      }
      g_moduleFallbackRegistry[registryAbsPath].Reset(isolate, existing);
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver] cached evaluated module as fallback for %s", absPath.c_str());
      }
    }

    RemoveModuleFromRegistry(absPath);
  }

  // 6) Otherwise, compile & register it
  if (cache->isWorker) {
    printf("ResolveModuleCallback: Worker compiling new module '%s' -> '%s'\n", spec.c_str(),
           absPath.c_str());
  }

  auto cycleIt = std::find(g_moduleResolutionStack.begin(), g_moduleResolutionStack.end(), registryAbsPath);
  if (cycleIt != g_moduleResolutionStack.end()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver] Detected recursive load for %s (already in stack length %lu)",
          absPath.c_str(), static_cast<unsigned long>(g_moduleResolutionStack.size()));
      for (const auto& entry : g_moduleResolutionStack) {
        Log(@"  • %s", entry.c_str());
      }
    }

    auto existing = g_moduleRegistry.find(registryAbsPath);
    if (existing != g_moduleRegistry.end()) {
      return v8::MaybeLocal<v8::Module>(existing->second.Get(isolate));
    }

    // If we somehow hit a cycle before the module was registered, bail gracefully in debug mode
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - Returning empty module for recursive load: %s", absPath.c_str());
      return v8::MaybeLocal<v8::Module>();
    }

    isolate->ThrowException(v8::Exception::Error(
        tns::ToV8String(isolate, ("Recursive module resolution detected for " + absPath).c_str())));
    return v8::MaybeLocal<v8::Module>();
  }

  ResolutionStackGuard stackGuard(isolate, g_moduleResolutionStack, registryAbsPath);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver] → LoadScript %s", absPath.c_str());
  }
  try {
    tns::ModuleInternal::LoadScript(isolate, absPath);
  } catch (NativeScriptException& ex) {
    if (cache->isWorker) {
      printf("ResolveModuleCallback: Worker failed to compile module '%s' -> '%s'\n", spec.c_str(),
             absPath.c_str());
    }
    ex.ReThrowToV8(isolate);
    return v8::MaybeLocal<v8::Module>();
  }
  // LoadScript will have added it into g_moduleRegistry under absPath
  auto it2 = g_moduleRegistry.find(registryAbsPath);
  if (it2 == g_moduleRegistry.end()) {
    // something went wrong
    return v8::MaybeLocal<v8::Module>();
  }
  return v8::MaybeLocal<v8::Module>(it2->second.Get(isolate));
}

// ────────────────────────────────────────────────────────────────────────────
// Dynamic import() host callback
v8::MaybeLocal<v8::Promise> ImportModuleDynamicallyCallback(
    v8::Local<v8::Context> context, v8::Local<v8::ScriptOrModule> referrer,
    v8::Local<v8::String> specifier, v8::Local<v8::FixedArray> import_assertions) {
  v8::Isolate* isolate = context->GetIsolate();
  // Diagnostic: log every dynamic import attempt.
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const char* cSpec = (*specUtf8) ? *specUtf8 : "<invalid>";
  NSString* specStr = [NSString stringWithUTF8String:cSpec];
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import] → %@", specStr);
    // Also log the referrer resource when available to correlate origin of dynamic imports
    v8::Local<v8::Value> resName = referrer->GetResourceName();
    if (!resName.IsEmpty() && resName->IsString()) {
      v8::String::Utf8Value rn(isolate, resName);
      if (*rn) { Log(@"[dyn-import][referrer] %s", *rn); }
    }
  }
  // ── Early guard: intercept bare "@" immediately to avoid any downstream handling ──
  // We perform this check again here (in addition to normalization guards below) to ensure
  // no intermediate path attempts to treat "@" as a real module. This also provides a
  // distinct marker in logs to verify the new code path is active in the built binary.
  {
    v8::EscapableHandleScope scope_immediate(isolate);
    v8::Local<v8::Promise::Resolver> resolver_immediate;
    if (!v8::Promise::Resolver::New(context).ToLocal(&resolver_immediate)) {
      return v8::MaybeLocal<v8::Promise>();
    }
    if (cSpec && std::strcmp(cSpec, "@") == 0) {
      if (IsScriptLoadingLogEnabled()) {
        // Try to capture referrer and JS stack to identify the source
        NSString* refName = nil;
        v8::Local<v8::Value> resName = referrer->GetResourceName();
        if (!resName.IsEmpty() && resName->IsString()) {
          v8::String::Utf8Value rn(isolate, resName);
          if (*rn) { refName = [NSString stringWithUTF8String:*rn]; }
        }
        Log(@"[dyn-import][guard] immediate '@' stub (ref=%@)", refName ?: @"<unknown>");
        // JS stack (best-effort)
        v8::HandleScope hs2(isolate);
        v8::TryCatch tc2(isolate);
        v8::Local<v8::String> evalSrc2 = tns::ToV8String(isolate, "(function(){ try { return (new Error('__dyn_at_v2__')).stack || 'no-stack'; } catch(e){ return 'stack-failed'; } })()");
        v8::Local<v8::Script> script2;
        if (v8::Script::Compile(context, evalSrc2).ToLocal(&script2)) {
          v8::Local<v8::Value> val2;
          if (script2->Run(context).ToLocal(&val2)) {
            v8::String::Utf8Value s2(isolate, val2);
            if (*s2) { Log(@"[dyn-import][guard] '@' stack: %@", [NSString stringWithUTF8String:*s2]); }
          }
        }
      }
      const char* kEmptySrc = "export {}\n";
      std::string url = "file:///app/__invalid_at__.mjs";
      v8::MaybeLocal<v8::Module> modMaybe = CompileModuleFromSource(isolate, context, kEmptySrc, url);
      v8::Local<v8::Module> mod;
      if (modMaybe.ToLocal(&mod)) {
        g_moduleRegistry[CanonicalizeRegistryKey(url)].Reset(isolate, mod);
        if (mod->GetStatus() != v8::Module::kEvaluated) {
          if (mod->Evaluate(context).IsEmpty()) {
            resolver_immediate->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, "Evaluation failed for empty module"))).FromMaybe(false);
            return scope_immediate.Escape(resolver_immediate->GetPromise());
          }
        }
        resolver_immediate->Resolve(context, mod->GetModuleNamespace()).FromMaybe(false);
        return scope_immediate.Escape(resolver_immediate->GetPromise());
      }
      // If compilation somehow failed, still resolve with an empty object namespace
      resolver_immediate->Resolve(context, v8::Object::New(isolate)).FromMaybe(false);
      return scope_immediate.Escape(resolver_immediate->GetPromise());
    }
  }
  // Normalize spec: expand '@/'; only strip ?query/hash for non-HTTP specs so SFC HTTP keys keep version tags
  std::string rawSpec = cSpec ? std::string(cSpec) : std::string();
  std::string normalizedSpec = rawSpec;
  // remove query/hash ONLY for non-HTTP specs
  bool isHttpLike = (!normalizedSpec.empty() && (StartsWith(normalizedSpec, "http://") || StartsWith(normalizedSpec, "https://")));
  if (!isHttpLike) {
    size_t qpos = normalizedSpec.find_first_of("?#");
    if (qpos != std::string::npos) {
      normalizedSpec = normalizedSpec.substr(0, qpos);
    }
  }
  // expand '@/'
  if (normalizedSpec.rfind("@/", 0) == 0) {
    normalizedSpec = std::string("/src/") + normalizedSpec.substr(2);
  }
  // guard against collapse to '@'
  if (normalizedSpec == "@") {
    if (IsScriptLoadingLogEnabled()) { Log(@"[dyn-import][normalize] invalid '@' spec, capturing JS stack"); }
    // Attempt to capture JS stack by evaluating new Error().stack in JS context
    v8::HandleScope hs(isolate);
    v8::TryCatch tc(isolate);
    v8::Local<v8::String> evalSrc = tns::ToV8String(isolate, "(function(){ try { return (new Error('__dyn_at__')).stack || 'no-stack'; } catch(e){ return 'stack-failed'; } })()");
    v8::Local<v8::Script> script;
    if (v8::Script::Compile(context, evalSrc).ToLocal(&script)) {
      v8::Local<v8::Value> val;
      if (script->Run(context).ToLocal(&val)) {
        v8::String::Utf8Value s(isolate, val);
        if (*s) {
          NSString* stack = [NSString stringWithUTF8String:*s];
          if (IsScriptLoadingLogEnabled()) { Log(@"[dyn-import][normalize] '@' stack: %@", stack); }
        }
      }
    }
    normalizedSpec = rawSpec; // revert to raw
  }
  if (normalizedSpec != rawSpec) {
    // Rebuild V8 string only if changed
    specifier = tns::ToV8String(isolate, normalizedSpec.c_str());
    specStr = [NSString stringWithUTF8String:normalizedSpec.c_str()];
    if (IsScriptLoadingLogEnabled()) { Log(@"[dyn-import][normalize] %@ -> %@", [NSString stringWithUTF8String:rawSpec.c_str()], specStr); }
  }
  v8::EscapableHandleScope scope(isolate);

  // Create a Promise resolver we'll resolve/reject synchronously for now.
  v8::Local<v8::Promise::Resolver> resolver;
  if (!v8::Promise::Resolver::New(context).ToLocal(&resolver)) {
    // Failed to create resolver, return empty promise
    return v8::MaybeLocal<v8::Promise>();
  }

  // ── Import map resolution for dynamic import() ────────────────
  if (!g_importMap.empty() && !normalizedSpec.empty() && normalizedSpec != "@") {
    std::string mapped = LookupImportMap(normalizedSpec);
    // If direct lookup failed, try normalizing Vite-rewritten specifiers
    if (mapped.empty()) {
      std::string normalized = NormalizeViteSpecifier(normalizedSpec);
      if (!normalized.empty()) {
        mapped = LookupImportMap(normalized);
        if (!mapped.empty() && IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][import-map] normalized: %s -> %s -> %s",
              normalizedSpec.c_str(), normalized.c_str(), mapped.c_str());
        }
      }
    }
    if (!mapped.empty()) {
      if (StartsWith(mapped, "ns-vendor://")) {
        std::string vendorId = mapped.substr(12);
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][import-map] vendor: %s -> %s", normalizedSpec.c_str(), vendorId.c_str());
        }
        v8::MaybeLocal<v8::Module> vendorMod = ResolveFromVendorRegistry(isolate, context, vendorId);
        v8::Local<v8::Module> mod;
        if (vendorMod.ToLocal(&mod) && mod->GetStatus() == v8::Module::kEvaluated) {
          resolver->Resolve(context, mod->GetModuleNamespace()).FromMaybe(false);
          return scope.Escape(resolver->GetPromise());
        }
        // Fall through to normal resolution if vendor resolve failed
      } else {
        // Mapped to an HTTP URL or other specifier
        normalizedSpec = mapped;
        specifier = tns::ToV8String(isolate, normalizedSpec.c_str());
        specStr = [NSString stringWithUTF8String:normalizedSpec.c_str()];
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][import-map] rewrite: %s -> %s", rawSpec.c_str(), normalizedSpec.c_str());
        }
      }
    }
  }

  // Re-use the static resolver to locate / compile the module.
  try {
    // Defensive guard: some dev-time toolchains may emit a stray import('@') during bootstrap.
    // Treat it as a no-op module to avoid surfacing a hard failure while continuing with real imports.
    if (!normalizedSpec.empty() && normalizedSpec == "@") {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import] ignoring invalid '@' spec (returning empty module)");
      }
      const char* kEmptySrc = "export {}\n";
      std::string url = "file:///app/__invalid_at__.mjs";
      v8::MaybeLocal<v8::Module> modMaybe = CompileModuleFromSource(isolate, context, kEmptySrc, url);
      v8::Local<v8::Module> mod;
      if (modMaybe.ToLocal(&mod)) {
        g_moduleRegistry[CanonicalizeRegistryKey(url)].Reset(isolate, mod);
        if (mod->GetStatus() != v8::Module::kEvaluated) {
          if (mod->Evaluate(context).IsEmpty()) {
            resolver->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, "Evaluation failed for empty module"))).FromMaybe(false);
            return scope.Escape(resolver->GetPromise());
          }
        }
        resolver->Resolve(context, mod->GetModuleNamespace()).FromMaybe(false);
        return scope.Escape(resolver->GetPromise());
      }
    }

    // ── Blob URL support (e.g., blob:nativescript/<uuid>) ──
    // Also useful for HMR updates where we can load a blob URL
    // We retrieve the blob content from the global BLOB_STORE via URL.InternalAccessor.getData()
    // and compile/execute it as an ES module.
    if (!normalizedSpec.empty() && StartsWith(normalizedSpec, "blob:nativescript/")) {
      const std::string blobRegistryKey = CanonicalizeRegistryKey(normalizedSpec);

      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import][blob] trying blob URL %s key=%s", normalizedSpec.c_str(),
            blobRegistryKey.c_str());
      }

      auto existingIt = g_moduleRegistry.find(blobRegistryKey);
      if (existingIt != g_moduleRegistry.end()) {
        v8::Local<v8::Module> existing = existingIt->second.Get(isolate);
        if (!existing.IsEmpty()) {
          v8::Module::Status existingStatus = existing->GetStatus();
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][blob-cache] hit %s status=%s", blobRegistryKey.c_str(),
                ModuleStatusToString(existingStatus));
          }

          if (existingStatus == v8::Module::kErrored) {
            RemoveModuleFromRegistry(blobRegistryKey);
          } else if (IsModuleEvaluationInProgress(existingStatus)) {
            g_modulesInFlight.insert(blobRegistryKey);
            g_httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[dyn-import][blob-await] queued waiter for %s status=%s",
                  blobRegistryKey.c_str(), ModuleStatusToString(existingStatus));
            }
            return scope.Escape(resolver->GetPromise());
          } else {
            resolver->Resolve(context, existing->GetModuleNamespace()).FromMaybe(false);
            return scope.Escape(resolver->GetPromise());
          }
        } else {
          RemoveModuleFromRegistry(blobRegistryKey);
        }
      }

      if (g_modulesInFlight.find(blobRegistryKey) != g_modulesInFlight.end()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] coalesce in-flight %s", blobRegistryKey.c_str());
        }
        g_httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);
        return scope.Escape(resolver->GetPromise());
      }

      g_modulesInFlight.insert(blobRegistryKey);
      g_httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);

      // Call URL.InternalAccessor.getData(url) to retrieve the blob data
      v8::TryCatch tc(isolate);
      v8::Local<v8::Object> globalObj = context->Global();

      // Get URL constructor
      v8::Local<v8::Value> urlCtorVal;
      if (!globalObj->Get(context, tns::ToV8String(isolate, "URL")).ToLocal(&urlCtorVal) || !urlCtorVal->IsFunction()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] URL constructor not found");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "URL constructor not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Object> urlCtor = urlCtorVal.As<v8::Object>();

      // Get URL.InternalAccessor
      v8::Local<v8::Value> internalAccessorVal;
      if (!urlCtor->Get(context, tns::ToV8String(isolate, "InternalAccessor")).ToLocal(&internalAccessorVal) || !internalAccessorVal->IsObject()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] URL.InternalAccessor not found");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "URL.InternalAccessor not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Object> internalAccessor = internalAccessorVal.As<v8::Object>();

      // Get URL.InternalAccessor.getData function
      v8::Local<v8::Value> getDataVal;
      if (!internalAccessor->Get(context, tns::ToV8String(isolate, "getData")).ToLocal(&getDataVal) || !getDataVal->IsFunction()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] URL.InternalAccessor.getData not found");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(
                tns::ToV8String(isolate, "URL.InternalAccessor.getData not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Function> getDataFn = getDataVal.As<v8::Function>();

      // Call getData(url)
      v8::Local<v8::Value> urlArg = tns::ToV8String(isolate, normalizedSpec.c_str());
      v8::Local<v8::Value> blobDataVal;
      if (!getDataFn->Call(context, internalAccessor, 1, &urlArg).ToLocal(&blobDataVal) || blobDataVal->IsNullOrUndefined()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] blob not found in BLOB_STORE: %s", normalizedSpec.c_str());
        }
        std::string msg = "Blob not found: " + normalizedSpec;
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
        return scope.Escape(resolver->GetPromise());
      }

      // blobDataVal should be {blob: Blob, type: string, ext: string}
      // We need to get the text from the Blob
      if (!blobDataVal->IsObject()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] blob data is not an object");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "Invalid blob data")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Object> blobData = blobDataVal.As<v8::Object>();

      // Get the actual Blob object
      v8::Local<v8::Value> blobVal;
      if (!blobData->Get(context, tns::ToV8String(isolate, "blob")).ToLocal(&blobVal) || !blobVal->IsObject()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] blob property not found");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "Blob object not found")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Object> blobObj = blobVal.As<v8::Object>();

      // Call blob.text() to get the source code as a Promise
      v8::Local<v8::Value> textFnVal;
      if (!blobObj->Get(context, tns::ToV8String(isolate, "text")).ToLocal(&textFnVal) || !textFnVal->IsFunction()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] Blob.text() not available");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "Blob.text() not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Function> textFn = textFnVal.As<v8::Function>();

      v8::Local<v8::Value> textPromiseVal;
      if (!textFn->Call(context, blobObj, 0, nullptr).ToLocal(&textPromiseVal) || !textPromiseVal->IsPromise()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] Blob.text() did not return a Promise");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "Blob.text() failed")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Promise> textPromise = textPromiseVal.As<v8::Promise>();

      // Create data structure to pass to the callbacks.
      struct BlobImportData {
        v8::Global<v8::Context> ctx;
        std::string blobUrl;
        std::string registryKey;
      };
      auto* data = new BlobImportData{
        v8::Global<v8::Context>(isolate, context),
        normalizedSpec,
        blobRegistryKey,
      };

      // Success callback: compile and execute the module.
      auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
        v8::Isolate* iso = info.GetIsolate();
        v8::HandleScope hs(iso);
        if (!info.Data()->IsExternal()) return;
        auto* d = static_cast<BlobImportData*>(info.Data().As<v8::External>()->Value());
        v8::Local<v8::Context> ctx = d->ctx.Get(iso);

        if (info.Length() < 1 || !info[0]->IsString()) {
          RejectHttpDynamicWaiters(
              iso, ctx, d->registryKey,
              v8::Exception::Error(tns::ToV8String(iso, "Blob text is not a string")));
          delete d;
          return;
        }

        v8::String::Utf8Value codeUtf8(iso, info[0]);
        std::string code = *codeUtf8 ? *codeUtf8 : "";

        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] compiling blob module, code length=%zu", code.size());
        }

        v8::MaybeLocal<v8::Module> modMaybe =
            CompileModuleForResolveRegisterOnly(iso, ctx, code, d->blobUrl);
        v8::Local<v8::Module> mod;
        if (!modMaybe.ToLocal(&mod)) {
          RejectHttpDynamicWaiters(
              iso, ctx, d->registryKey,
              v8::Exception::Error(tns::ToV8String(iso, "Failed to compile blob module")));
          delete d;
          return;
        }

        if (mod->GetStatus() == v8::Module::kUninstantiated &&
            !mod->InstantiateModule(ctx, &ResolveModuleCallback).FromMaybe(false)) {
          RemoveModuleFromRegistry(d->registryKey);
          RejectHttpDynamicWaiters(
              iso, ctx, d->registryKey,
              v8::Exception::Error(
                  tns::ToV8String(iso, "Failed to instantiate blob module")));
          delete d;
          return;
        }

        if (IsModuleEvaluationInProgress(mod->GetStatus())) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][blob] waiting on existing evaluation for %s status=%s",
                d->registryKey.c_str(), ModuleStatusToString(mod->GetStatus()));
          }
          delete d;
          return;
        }

        if (mod->GetStatus() != v8::Module::kEvaluated) {
          v8::Local<v8::Value> evalResult;
          if (!mod->Evaluate(ctx).ToLocal(&evalResult)) {
            RemoveModuleFromRegistry(d->registryKey);
            RejectHttpDynamicWaiters(
                iso, ctx, d->registryKey,
                v8::Exception::Error(
                    tns::ToV8String(iso, "Failed to evaluate blob module")));
            delete d;
            return;
          }

          if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
            struct BlobEvalData {
              std::string registryKey;
              v8::Global<v8::Context> ctx;
              v8::Global<v8::Module> mod;
            };

            auto* evalData = new BlobEvalData{
              d->registryKey,
              v8::Global<v8::Context>(iso, ctx),
              v8::Global<v8::Module>(iso, mod),
            };

            auto onEvalFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
              v8::Isolate* iso = info.GetIsolate();
              v8::HandleScope hs(iso);
              if (!info.Data()->IsExternal()) return;
              auto* d = static_cast<BlobEvalData*>(info.Data().As<v8::External>()->Value());
              v8::Local<v8::Context> ctx = d->ctx.Get(iso);
              v8::Local<v8::Module> mod = d->mod.Get(iso);
              ResolveHttpDynamicWaiters(iso, ctx, d->registryKey, mod);
              delete d;
            };

            auto onEvalRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
              v8::Isolate* iso = info.GetIsolate();
              v8::HandleScope hs(iso);
              if (!info.Data()->IsExternal()) return;
              auto* d = static_cast<BlobEvalData*>(info.Data().As<v8::External>()->Value());
              v8::Local<v8::Context> ctx = d->ctx.Get(iso);
              v8::Local<v8::Value> reason =
                  info.Length() > 0
                      ? info[0]
                      : v8::Exception::Error(
                            tns::ToV8String(iso, "Blob module evaluation failed"));
              RemoveModuleFromRegistry(d->registryKey);
              RejectHttpDynamicWaiters(iso, ctx, d->registryKey, reason);
              delete d;
            };

            v8::Local<v8::Promise> evalPromise = evalResult.As<v8::Promise>();
            v8::Local<v8::Function> onEvalFulfilledFn =
                v8::Function::New(ctx, onEvalFulfilled,
                                  v8::External::New(iso, evalData))
                    .ToLocalChecked();
            v8::Local<v8::Function> onEvalRejectedFn =
                v8::Function::New(ctx, onEvalRejected,
                                  v8::External::New(iso, evalData))
                    .ToLocalChecked();
            evalPromise->Then(ctx, onEvalFulfilledFn, onEvalRejectedFn)
                .FromMaybe(v8::Local<v8::Promise>());
            delete d;
            return;
          }
        }

        ResolveHttpDynamicWaiters(iso, ctx, d->registryKey, mod);
        delete d;
      };

      // Error callback
      auto onRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
        v8::Isolate* iso = info.GetIsolate();
        v8::HandleScope hs(iso);
        if (!info.Data()->IsExternal()) return;
        auto* d = static_cast<BlobImportData*>(info.Data().As<v8::External>()->Value());
        v8::Local<v8::Context> ctx = d->ctx.Get(iso);
        v8::Local<v8::Value> reason =
            info.Length() > 0
                ? info[0]
                : v8::Exception::Error(tns::ToV8String(iso, "Blob text() failed"));
        RejectHttpDynamicWaiters(iso, ctx, d->registryKey, reason);
        delete d;
      };

      v8::Local<v8::Function> onFulfilledFn = v8::Function::New(context, onFulfilled, v8::External::New(isolate, data)).ToLocalChecked();
      v8::Local<v8::Function> onRejectedFn = v8::Function::New(context, onRejected, v8::External::New(isolate, data)).ToLocalChecked();

      textPromise->Then(context, onFulfilledFn, onRejectedFn).FromMaybe(v8::Local<v8::Promise>());

      return scope.Escape(resolver->GetPromise());
    }

    // If spec is an HTTP(S) URL, try HTTP fetch+compile directly
    // Security: HttpFetchText gates remote module access centrally.
    if (!normalizedSpec.empty() && (StartsWith(normalizedSpec, "http://") || StartsWith(normalizedSpec, "https://"))) {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import][http-loader] trying URL %s", normalizedSpec.c_str());
      }
      std::string key = CanonicalizeHttpUrlKey(normalizedSpec);
      // Volatile pattern check: if the URL matches any configured volatile pattern,
      // evict the cached module so we always re-fetch. This replaces the hardcoded
      // /@ns/sfc/ and /@ns/asm/ checks with a configurable system.
      bool isVolatile = IsVolatileUrl(normalizedSpec);
      // Backward compatibility: if no volatile patterns configured, fall back to
      // hardcoded SFC/ASM detection
      if (!isVolatile && g_volatilePatterns.empty()) {
        bool specIsSfc = normalizedSpec.find("/@ns/sfc/") != std::string::npos;
        bool specIsAsm = normalizedSpec.find("/@ns/asm/") != std::string::npos;
        bool specHasTypeScript = normalizedSpec.find("type=script") != std::string::npos;
        bool specHasTypeTemplate = normalizedSpec.find("type=template") != std::string::npos;
        bool specHasTypeStyle = normalizedSpec.find("type=style") != std::string::npos;
        bool isSfcVariant = specIsSfc && (specHasTypeScript || specHasTypeTemplate || specHasTypeStyle);
        isVolatile = (specIsSfc && !isSfcVariant) || specIsAsm;
      }
      // Angular HMR component-update endpoint (`/@ng/component?c=<id>&t=<ts>`) is
      // inherently volatile: each save produces fresh metadata that the runtime
      // must re-fetch and re-compile so `ɵɵreplaceMetadata` sees the new
      // template instructions. The `t` parameter discriminates versions, but
      // even with `CanonicalizeHttpUrlKey` preserving it, every save would
      // otherwise leave a stale module entry behind in `g_moduleRegistry`,
      // accumulating one entry per save for the entire dev session. Marking it
      // as volatile evicts the previous entry on every re-import so the cache
      // stays bounded AND we always serve fresh metadata to
      // `ɵɵreplaceMetadata`. Without this evict, the boot-time call's
      // resolved module would shadow any subsequent fetch on a path-only
      // canonicalization regression and surface as "first save's metadata
      // permanently stuck on screen" — exactly the symptom this fixes.
      if (!isVolatile && normalizedSpec.find("/@ng/component") != std::string::npos) {
        isVolatile = true;
      }
      if (isVolatile) {
        auto ex = g_moduleRegistry.find(key);
        if (ex != g_moduleRegistry.end()) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][http-cache] drop volatile %s", key.c_str());
          }
          RemoveModuleFromRegistry(key);
        }
      }
      // Coalesce concurrent dynamic imports for the same HTTP key
      auto inflight = g_modulesInFlight.find(key) != g_modulesInFlight.end();
      if (inflight) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][http] coalesce in-flight %s", key.c_str());
        }
        g_httpDynamicWaiters[key].emplace_back(isolate, resolver);
        return scope.Escape(resolver->GetPromise());
      }
      // If module was already compiled, resolve immediately
      auto itExisting = g_moduleRegistry.find(key);
      if (itExisting != g_moduleRegistry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty()) {
          // Permanent observability: surface every HTTP dynamic-import
          // cache hit so we can verify the runtime *did* drop the entry
          // on invalidate. Filtered to angular component-shaped URLs to
          // avoid spam from vendor chunks. Verbose-gated.
          if (IsScriptLoadingLogEnabled()) {
            if (key.find("ns/m/") != std::string::npos || key.find(".component") != std::string::npos) {
              Log(@"[ns-hmr][ios-dyn-cache] HIT %s status=%s",
                  key.c_str(), ModuleStatusToString(existing->GetStatus()));
            }
            Log(@"[dyn-import][http-cache] hit %s", key.c_str());
            Log(@"  ↳ status=%s", ModuleStatusToString(existing->GetStatus()));
          }
          v8::Module::Status st = existing->GetStatus();
          if (st == v8::Module::kErrored) {
            // Stale/broken entry; drop and refetch
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[dyn-import][http-cache] dropping errored module for %s", key.c_str());
            }
            RemoveModuleFromRegistry(key);
            // fall through to fetch/compile path below
          } else if (IsModuleEvaluationInProgress(st)) {
            if (QueueHttpDynamicWaiterIfInFlight(isolate, key, existing, resolver)) {
              return scope.Escape(resolver->GetPromise());
            }

            if (IsScriptLoadingLogEnabled()) {
              Log(@"[dyn-import][http-cache] avoiding re-entrant Evaluate for %s status=%s",
                  key.c_str(), ModuleStatusToString(st));
            }
            resolver->Resolve(context, existing->GetModuleNamespace()).FromMaybe(false);
            return scope.Escape(resolver->GetPromise());
          } else {
            // Ensure dynamic import semantics: resolve only after evaluation
            if (st != v8::Module::kEvaluated) {
              // mark in-flight while we evaluate
              g_modulesInFlight.insert(key);
              if (IsScriptLoadingLogEnabled()) {
                Log(@"[dyn-import][http-cache] awaiting evaluation %s", key.c_str());
              }
              g_httpDynamicWaiters[key].emplace_back(isolate, resolver);
              if (st == v8::Module::kUninstantiated &&
                  !existing->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
                RemoveModuleFromRegistry(key);
                RejectHttpDynamicWaiters(
                    isolate, context, key,
                    v8::Exception::Error(
                        tns::ToV8String(isolate, "Instantiation failed (http-cache hit)")));
                return scope.Escape(resolver->GetPromise());
              }

              if (IsModuleEvaluationInProgress(existing->GetStatus())) {
                return scope.Escape(resolver->GetPromise());
              }

              // Trigger evaluation. If TLA returns a Promise, attach then-handlers to resolve waiters upon settle.
              v8::Local<v8::Value> evalResult;
              if (!existing->Evaluate(context).ToLocal(&evalResult)) {
                // Failed evaluation: reject all waiters and drop entry
                RemoveModuleFromRegistry(key);
                RejectHttpDynamicWaiters(
                    isolate, context, key,
                    v8::Exception::Error(
                        tns::ToV8String(isolate, "Evaluation failed (http-cache hit)")));
                return scope.Escape(resolver->GetPromise());
              }
              // If Evaluate returned a Promise (top-level await), wait until it settles before resolving waiters.
              if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
                v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
                struct EvalWaitData { std::string key; v8::Global<v8::Context> ctx; v8::Global<v8::Module> mod; };
                auto* data = new EvalWaitData{ key, v8::Global<v8::Context>(isolate, context), v8::Global<v8::Module>(isolate, existing) };
                auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
                  v8::Isolate* iso = info.GetIsolate();
                  v8::HandleScope hs(iso);
                  if (!info.Data()->IsExternal()) return;
                  auto* d = static_cast<EvalWaitData*>(info.Data().As<v8::External>()->Value());
                  v8::Local<v8::Context> ctx = d->ctx.Get(iso);
                  std::string keyLocal = d->key;
                  v8::Local<v8::Module> modLocal = d->mod.Get(iso);
                  ResolveHttpDynamicWaiters(iso, ctx, keyLocal, modLocal);
                  delete d;
                };
                auto onRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
                  v8::Isolate* iso = info.GetIsolate();
                  v8::HandleScope hs(iso);
                  if (!info.Data()->IsExternal()) return;
                  auto* d = static_cast<EvalWaitData*>(info.Data().As<v8::External>()->Value());
                  v8::Local<v8::Context> ctx = d->ctx.Get(iso);
                  std::string keyLocal = d->key;
                  v8::Local<v8::Value> reason = (info.Length() > 0) ? info[0] : v8::Exception::Error(tns::ToV8String(iso, "Evaluation failed (http-cache TLA)"));
                  if (IsScriptLoadingLogEnabled()) {
                    v8::String::Utf8Value r(iso, reason);
                    if (*r) { Log(@"[dyn-import][http-cache][tla] rejected: %s", *r); }
                  }
                  RejectHttpDynamicWaiters(iso, ctx, keyLocal, reason);
                  delete d;
                };
                v8::Local<v8::FunctionTemplate> thenFulfillTpl = v8::FunctionTemplate::New(isolate, onFulfilled, v8::External::New(isolate, data));
                v8::Local<v8::Function> thenFulfill = thenFulfillTpl->GetFunction(context).ToLocalChecked();
                v8::Local<v8::FunctionTemplate> thenRejectTpl = v8::FunctionTemplate::New(isolate, onRejected, v8::External::New(isolate, data));
                v8::Local<v8::Function> thenReject = thenRejectTpl->GetFunction(context).ToLocalChecked();
                p->Then(context, thenFulfill, thenReject).ToLocalChecked();
                return scope.Escape(resolver->GetPromise());
              }
              // Successful sync evaluation path: resolve waiters now.
              ResolveHttpDynamicWaiters(isolate, context, key, existing);
              return scope.Escape(resolver->GetPromise());
            }
            // Always resolve with namespace for cached modules; JS side will read default
            resolver->Resolve(context, existing->GetModuleNamespace()).FromMaybe(false);
            return scope.Escape(resolver->GetPromise());
          }
        }
      }
      // mark in-flight before starting network fetch
      g_modulesInFlight.insert(key);
      g_httpDynamicWaiters[key].emplace_back(isolate, resolver);
      // Permanent observability: surface fresh fetches so we can confirm
      // that post-invalidation, the next dynamic import does NOT re-use
      // the cache and DOES go to the network. Filtered to component
      // shapes to avoid vendor-chunk noise. Verbose-gated.
      if (IsScriptLoadingLogEnabled() &&
          (key.find("ns/m/") != std::string::npos || key.find(".component") != std::string::npos)) {
        Log(@"[ns-hmr][ios-dyn-cache] FRESH-FETCH %s", key.c_str());
      }
      v8::MaybeLocal<v8::Module> modMaybe = LoadHttpModuleForUrl(isolate, context, normalizedSpec);
      if (!modMaybe.IsEmpty()) {
        v8::Local<v8::Module> mod;
        if (modMaybe.ToLocal(&mod)) {
          if (mod->GetStatus() == v8::Module::kUninstantiated &&
              !mod->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
            RemoveModuleFromRegistry(key);
            RejectHttpDynamicWaiters(
                isolate, context, key,
                v8::Exception::Error(
                    tns::ToV8String(isolate, "Instantiation failed (http-loader)")));
            return scope.Escape(resolver->GetPromise());
          }

          if (IsModuleEvaluationInProgress(mod->GetStatus())) {
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[dyn-import][http-loader] waiting on existing evaluation for %s status=%s",
                  key.c_str(), ModuleStatusToString(mod->GetStatus()));
            }
            return scope.Escape(resolver->GetPromise());
          }

          // Evaluate once compiled so that namespace is valid for dynamic import resolution
          if (mod->GetStatus() != v8::Module::kEvaluated) {
            v8::Local<v8::Value> evalResult;
            if (!mod->Evaluate(context).ToLocal(&evalResult)) {
              // Remove broken registration and reject
              RemoveModuleFromRegistry(key);
              RejectHttpDynamicWaiters(
                  isolate, context, key,
                  v8::Exception::Error(
                      tns::ToV8String(isolate, "Evaluation failed (http-loader)")));
              return scope.Escape(resolver->GetPromise());
            }
            // If Evaluate returned a Promise (top-level await), wait until it settles before resolving
            if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
              v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
              struct EvalWaitData2 { std::string key; v8::Global<v8::Context> ctx; v8::Global<v8::Module> mod; };
              auto* data2 = new EvalWaitData2{ key, v8::Global<v8::Context>(isolate, context), v8::Global<v8::Module>(isolate, mod) };
              auto onFulfilled2 = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
                v8::Isolate* iso = info.GetIsolate();
                v8::HandleScope hs(iso);
                if (!info.Data()->IsExternal()) return;
                auto* d = static_cast<EvalWaitData2*>(info.Data().As<v8::External>()->Value());
                v8::Local<v8::Context> ctx = d->ctx.Get(iso);
                std::string keyLocal = d->key;
                v8::Local<v8::Module> modLocal = d->mod.Get(iso);
                ResolveHttpDynamicWaiters(iso, ctx, keyLocal, modLocal);
                delete d;
              };
              auto onRejected2 = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
                v8::Isolate* iso = info.GetIsolate();
                v8::HandleScope hs(iso);
                if (!info.Data()->IsExternal()) return;
                auto* d = static_cast<EvalWaitData2*>(info.Data().As<v8::External>()->Value());
                v8::Local<v8::Context> ctx = d->ctx.Get(iso);
                std::string keyLocal = d->key;
                v8::Local<v8::Value> reason = (info.Length() > 0) ? info[0] : v8::Exception::Error(tns::ToV8String(iso, "Evaluation failed (http-loader TLA)"));
                if (IsScriptLoadingLogEnabled()) {
                  v8::String::Utf8Value r(iso, reason);
                  if (*r) { Log(@"[dyn-import][http-loader][tla] rejected: %s", *r); }
                }
                RejectHttpDynamicWaiters(iso, ctx, keyLocal, reason);
                delete d;
              };
              v8::Local<v8::FunctionTemplate> thenFulfillTpl2 = v8::FunctionTemplate::New(isolate, onFulfilled2, v8::External::New(isolate, data2));
              v8::Local<v8::Function> thenFulfill2 = thenFulfillTpl2->GetFunction(context).ToLocalChecked();
              v8::Local<v8::FunctionTemplate> thenRejectTpl2 = v8::FunctionTemplate::New(isolate, onRejected2, v8::External::New(isolate, data2));
              v8::Local<v8::Function> thenReject2 = thenRejectTpl2->GetFunction(context).ToLocalChecked();
              p->Then(context, thenFulfill2, thenReject2).ToLocalChecked();
              return scope.Escape(resolver->GetPromise());
            }
          }
          ResolveHttpDynamicWaiters(isolate, context, key, mod);
          return scope.Escape(resolver->GetPromise());
        }
      }
      // On fetch/compile miss: clean inflight and reject queued
      RejectHttpDynamicWaiters(
          isolate, context, key,
          v8::Exception::Error(tns::ToV8String(isolate, "HTTP fetch/compile failed")));
    }

    // Attempt to resolve relative specs against the referrer's resource URL if available.
    // This reduces reliance on app-root fallback and ensures ../ segments are collapsed.
    v8::Local<v8::Module> refMod;
    v8::Local<v8::String> adjustedSpecifier = specifier;
    if (!normalizedSpec.empty() && (normalizedSpec.rfind("./", 0) == 0 || normalizedSpec.rfind("../", 0) == 0)) {
      // Try to extract a base directory from referrer->GetResourceName() which is a file:// URL
      v8::Local<v8::Value> resName = referrer->GetResourceName();
      if (!resName.IsEmpty() && resName->IsString()) {
        v8::String::Utf8Value rn(isolate, resName);
        std::string refUrl = *rn ? *rn : std::string();
        if (!refUrl.empty()) {
          std::string refPath = FileURLToPath(refUrl);
          size_t slash = refPath.find_last_of("/\\");
          std::string baseDir = slash == std::string::npos ? std::string() : refPath.substr(0, slash + 1);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][ref] url=%s base=%s spec=%s", refUrl.c_str(), baseDir.c_str(), normalizedSpec.c_str());
          }
          // Join and standardize via NSString to collapse dot-segments
          @autoreleasepool {
            NSString* nsBase = [NSString stringWithUTF8String:baseDir.c_str()];
            NSString* nsRel = [NSString stringWithUTF8String:normalizedSpec.c_str()];
            if (nsBase && nsRel) {
              NSString* joined = [nsBase stringByAppendingPathComponent:nsRel];
              NSString* std = [joined stringByStandardizingPath];
              if (std) {
                std::string fsPath = std.UTF8String;
                // Convert back to a path relative to app when applicable
                // Prefer absolute filesystem path; ResolveModuleCallback can handle it
                adjustedSpecifier = tns::ToV8String(isolate, fsPath.c_str());
                if (IsScriptLoadingLogEnabled()) {
                  Log(@"[dyn-import][normalize-rel] %s + %s -> %s", baseDir.c_str(), normalizedSpec.c_str(), fsPath.c_str());
                }
              }
            }
          }
        }
      } else {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][ref] missing resource name; cannot normalize relative spec against referrer");
        }
      }
    }

  v8::TryCatch resolveTc(isolate);
  v8::MaybeLocal<v8::Module> maybeModule =
    ResolveModuleCallback(context, adjustedSpecifier, import_assertions, refMod);
  if (IsScriptLoadingLogEnabled()) {
    // Log the adjusted specifier we sent to the resolver
    v8::String::Utf8Value adj(isolate, adjustedSpecifier);
    const char* cAdj = (*adj) ? *adj : "<invalid>";
    Log(@"[dyn-import][resolver-call] raw=%s normalized=%s adjusted=%s",
        rawSpec.c_str(), normalizedSpec.c_str(), cAdj);
  }
  v8::String::Utf8Value adjustedSpecUtf8(isolate, adjustedSpecifier);
  std::string adjustedRegistryKey =
      *adjustedSpecUtf8 ? CanonicalizeRegistryKey(*adjustedSpecUtf8) : std::string();
  if (maybeModule.IsEmpty()) {
    if (resolveTc.HasCaught()) {
      // Reject the promise with the thrown exception so callers don't hang
      resolver->Reject(context, resolveTc.Exception()).FromMaybe(false);
      return scope.Escape(resolver->GetPromise());
    } else {
      // No exception thrown (debug path); reject with a helpful error
      std::string msg = "Module resolution failed for dynamic import: ";
      msg += normalizedSpec.empty() ? "<empty>" : normalizedSpec;
      resolver->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, msg.c_str()))).FromMaybe(false);
      return scope.Escape(resolver->GetPromise());
    }
  }

    // If initial resolution failed AND looks like an application module, attempt on-demand fetch via JS bridge.
    if (maybeModule.IsEmpty()) {
      bool looksApp = false;
      if (!normalizedSpec.empty()) {
        std::string specCpp(normalizedSpec);
        // Heuristic: app modules start with /core, /src, /utils or ./ relative forms (not node_modules, not @nativescript/*)
        if (specCpp.rfind("/core/", 0) == 0 || specCpp.rfind("/src/", 0) == 0 || specCpp.rfind("/utils/", 0) == 0 || specCpp.rfind("./", 0) == 0) {
          looksApp = true;
        }
      }
      if (looksApp) {
        if (IsScriptLoadingLogEnabled()) { Log(@"[dyn-import][fetch] attempting runtime fetch for %@", specStr); }
        v8::TryCatch tc(isolate);
        // Acquire __nsHmrRequestModule
        v8::Local<v8::String> fetchKey = tns::ToV8String(isolate, "__nsHmrRequestModule");
        v8::Local<v8::Value> fetchFnVal;
        if (context->Global()->Get(context, fetchKey).ToLocal(&fetchFnVal) && fetchFnVal->IsFunction()) {
          v8::Local<v8::Function> fetchFn = fetchFnVal.As<v8::Function>();
          v8::Local<v8::Value> argv[1] = { specifier };
          v8::MaybeLocal<v8::Value> maybePromise = fetchFn->Call(context, context->Global(), 1, argv);
          v8::Local<v8::Value> promiseVal;
          if (maybePromise.ToLocal(&promiseVal) && promiseVal->IsPromise()) {
            // Chain: when JS promise resolves, retry resolution.
            v8::Local<v8::Promise> jsPromise = promiseVal.As<v8::Promise>();
            // We attach then() via microtask enqueue style: create functions capturing resolver & spec.
            struct FetchRetryData { v8::Global<v8::Promise::Resolver> resolver; v8::Global<v8::String> spec; v8::Global<v8::FixedArray> assertions; };
            auto* data = new FetchRetryData{ v8::Global<v8::Promise::Resolver>(isolate, resolver), v8::Global<v8::String>(isolate, specifier), v8::Global<v8::FixedArray>(isolate, import_assertions) };

            // Success callback
            auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
              v8::Isolate* isolateInner = info.GetIsolate();
              v8::HandleScope hs(isolateInner);
              if (!info.Data()->IsExternal()) return;
              auto* d = static_cast<FetchRetryData*>(info.Data().As<v8::External>()->Value());
              v8::Local<v8::Context> ctx = isolateInner->GetCurrentContext();
              v8::Local<v8::Promise::Resolver> res = d->resolver.Get(isolateInner);
              v8::Local<v8::String> specLocal = d->spec.Get(isolateInner);
              v8::Local<v8::FixedArray> assertionsLocal = d->assertions.Get(isolateInner);
              v8::Local<v8::Module> refMod; // empty
              v8::MaybeLocal<v8::Module> again = ResolveModuleCallback(ctx, specLocal, assertionsLocal, refMod);
              v8::Local<v8::Module> mod2;
              if (!again.ToLocal(&mod2)) {
                res->Reject(ctx, v8::Exception::Error(tns::ToV8String(isolateInner, "Module still unresolved after fetch"))).FromMaybe(false);
              } else {
                v8::String::Utf8Value specUtf8Inner(isolateInner, specLocal);
                std::string retryKey =
                    *specUtf8Inner ? CanonicalizeRegistryKey(*specUtf8Inner) : std::string();
                if (mod2->GetStatus() == v8::Module::kUninstantiated) {
                  if (!mod2->InstantiateModule(ctx, &ResolveModuleCallback).FromMaybe(false)) {
                    res->Reject(ctx, v8::Exception::Error(tns::ToV8String(isolateInner, "Instantiate failed after fetch"))).FromMaybe(false);
                    delete d; return;
                  }
                }
                if (IsModuleEvaluationInProgress(mod2->GetStatus())) {
                  if (QueueModuleWaiterIfInFlight(isolateInner, retryKey, mod2, res)) {
                    delete d;
                    return;
                  }

                  res->Resolve(ctx, mod2->GetModuleNamespace()).FromMaybe(false);
                  delete d;
                  return;
                }
                if (mod2->GetStatus() != v8::Module::kEvaluated) {
                  if (mod2->Evaluate(ctx).IsEmpty()) {
                    res->Reject(ctx, v8::Exception::Error(tns::ToV8String(isolateInner, "Evaluation failed after fetch"))).FromMaybe(false);
                    delete d; return;
                  }
                }
                res->Resolve(ctx, mod2->GetModuleNamespace()).FromMaybe(false);
              }
              delete d;
            };

            // Failure callback
            auto onRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
              v8::Isolate* isolateInner = info.GetIsolate();
              v8::HandleScope hs(isolateInner);
              if (!info.Data()->IsExternal()) return;
              auto* d = static_cast<FetchRetryData*>(info.Data().As<v8::External>()->Value());
              v8::Local<v8::Context> ctx = isolateInner->GetCurrentContext();
              v8::Local<v8::Promise::Resolver> res = d->resolver.Get(isolateInner);
              v8::Local<v8::Value> reason = info.Length() > 0 ? info[0] : v8::Exception::Error(tns::ToV8String(isolateInner, "Fetch failed"));
              res->Reject(ctx, reason).FromMaybe(false);
              delete d;
            };

            v8::Local<v8::FunctionTemplate> thenFulfillTpl = v8::FunctionTemplate::New(isolate, onFulfilled, v8::External::New(isolate, data));
            v8::Local<v8::Function> thenFulfill = thenFulfillTpl->GetFunction(context).ToLocalChecked();
            v8::Local<v8::FunctionTemplate> thenRejectTpl = v8::FunctionTemplate::New(isolate, onRejected, v8::External::New(isolate, data));
            v8::Local<v8::Function> thenReject = thenRejectTpl->GetFunction(context).ToLocalChecked();
            v8::Local<v8::Value> thenArgs[2] = { thenFulfill, thenReject };
            jsPromise->Then(context, thenArgs[0].As<v8::Function>(), thenArgs[1].As<v8::Function>()).ToLocalChecked();
            return scope.Escape(resolver->GetPromise());
          }
        }
        // If no bridge or not a promise we fall through to normal failure path.
      }
    }

    v8::Local<v8::Module> module = maybeModule.ToLocalChecked();

    // If not yet instantiated/evaluated, do it now
    if (module->GetStatus() == v8::Module::kUninstantiated) {
      // Capture detailed V8 exception info if instantiation fails
      v8::TryCatch ictc(isolate);
      if (!module->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import] ✗ instantiate failed %@", specStr);
        }
        // Include the spec and V8 exception message (when available) for improved diagnostics upstream
        std::string msg = std::string("Failed to instantiate module: ") + std::string([specStr UTF8String]);
        if (ictc.HasCaught()) {
          std::string exStr = tns::ToString(isolate, ictc.Exception());
          if (!exStr.empty()) {
            msg.append(" — ");
            msg.append(exStr);
          }
        }
        resolver
            ->Reject(context,
                     v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())))
            .Check();
        return scope.Escape(resolver->GetPromise());
      }
    }

    if (IsModuleEvaluationInProgress(module->GetStatus())) {
      if (QueueModuleWaiterIfInFlight(isolate, adjustedRegistryKey, module, resolver)) {
        return scope.Escape(resolver->GetPromise());
      }

      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import] avoiding re-entrant Evaluate for %s status=%s",
            adjustedRegistryKey.empty() ? rawSpec.c_str() : adjustedRegistryKey.c_str(),
            ModuleStatusToString(module->GetStatus()));
      }
      resolver->Resolve(context, module->GetModuleNamespace()).Check();
      return scope.Escape(resolver->GetPromise());
    }

    if (module->GetStatus() != v8::Module::kEvaluated) {
      v8::Local<v8::Value> evalResult;
      if (!module->Evaluate(context).ToLocal(&evalResult)) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import] ✗ evaluation failed %@", specStr);
        }
        // Include the spec in the error message for improved diagnostics upstream
        std::string msg = std::string("Evaluation failed for module: ") + std::string([specStr UTF8String]);
        v8::Local<v8::Value> ex = v8::Exception::Error(tns::ToV8String(isolate, msg.c_str()));
        resolver->Reject(context, ex).Check();
        return scope.Escape(resolver->GetPromise());
      }
      // If top-level await returns a Promise, resolve only after it settles
      if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
        v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
        struct DynEvalData { v8::Global<v8::Context> ctx; v8::Global<v8::Module> mod; v8::Global<v8::Promise::Resolver> res; };
        auto* d = new DynEvalData{ v8::Global<v8::Context>(isolate, context), v8::Global<v8::Module>(isolate, module), v8::Global<v8::Promise::Resolver>(isolate, resolver) };
        auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
          v8::Isolate* iso = info.GetIsolate();
          v8::HandleScope hs(iso);
          if (!info.Data()->IsExternal()) return;
          auto* d = static_cast<DynEvalData*>(info.Data().As<v8::External>()->Value());
          v8::Local<v8::Context> ctx = d->ctx.Get(iso);
          v8::Local<v8::Module> modLocal = d->mod.Get(iso);
          v8::Local<v8::Promise::Resolver> res = d->res.Get(iso);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][tla] fulfilled, resolving namespace");
          }
          if (!res.IsEmpty()) res->Resolve(ctx, modLocal->GetModuleNamespace()).FromMaybe(false);
          delete d;
        };
        auto onRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
          v8::Isolate* iso = info.GetIsolate();
          v8::HandleScope hs(iso);
          if (!info.Data()->IsExternal()) return;
          auto* d = static_cast<DynEvalData*>(info.Data().As<v8::External>()->Value());
          v8::Local<v8::Context> ctx = d->ctx.Get(iso);
          v8::Local<v8::Promise::Resolver> res = d->res.Get(iso);
          v8::Local<v8::Value> reason = (info.Length() > 0) ? info[0] : v8::Exception::Error(tns::ToV8String(iso, "Evaluation failed (TLA)"));
          if (IsScriptLoadingLogEnabled()) {
            v8::String::Utf8Value r(iso, reason);
            if (*r) { Log(@"[dyn-import][tla] rejected: %s", *r); }
          }
          if (!res.IsEmpty()) res->Reject(ctx, reason).FromMaybe(false);
          delete d;
        };
        v8::Local<v8::FunctionTemplate> fulfillTpl = v8::FunctionTemplate::New(isolate, onFulfilled, v8::External::New(isolate, d));
        v8::Local<v8::Function> fulfill = fulfillTpl->GetFunction(context).ToLocalChecked();
        v8::Local<v8::FunctionTemplate> rejectTpl = v8::FunctionTemplate::New(isolate, onRejected, v8::External::New(isolate, d));
        v8::Local<v8::Function> reject = rejectTpl->GetFunction(context).ToLocalChecked();
        p->Then(context, fulfill, reject).ToLocalChecked();
        return scope.Escape(resolver->GetPromise());
      }
    }

    // Special handling for bundler chunks: check if this is a bundler chunk and install it
    v8::Local<v8::Value> namespaceObj = module->GetModuleNamespace();
    if (namespaceObj->IsObject()) {
      v8::Local<v8::Object> nsObj = namespaceObj.As<v8::Object>();

      // Check if this is a webpack chunk (has __webpack_ids__ export)
      v8::Local<v8::String> webpackIdsKey = tns::ToV8String(isolate, "__webpack_ids__");
      v8::Local<v8::Value> webpackIds;
      if (nsObj->Get(context, webpackIdsKey).ToLocal(&webpackIds) && !webpackIds->IsUndefined()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import] Detected webpack chunk %@", specStr);
        }
        // This is a webpack chunk, get the webpack runtime from the runtime module
        try {
          // Import the runtime module to get __webpack_require__
          // For import assertions, we need to pass an empty FixedArray
          // Use the empty fixed array from the isolate's roots
          v8::Local<v8::FixedArray> empty_assertions = v8::Local<v8::FixedArray>();
          v8::MaybeLocal<v8::Module> maybeRuntimeModule =
          ResolveModuleCallback(context, tns::ToV8String(isolate, "file:///app/runtime.mjs"),
                                    empty_assertions, v8::Local<v8::Module>());

          v8::Local<v8::Module> runtimeModule;
          if (maybeRuntimeModule.ToLocal(&runtimeModule)) {
            v8::Local<v8::Value> runtimeNamespace = runtimeModule->GetModuleNamespace();
            if (runtimeNamespace->IsObject()) {
              v8::Local<v8::Object> runtimeObj = runtimeNamespace.As<v8::Object>();
              v8::Local<v8::String> defaultKey = tns::ToV8String(isolate, "default");
              v8::Local<v8::Value> webpackRequire;

              if (runtimeObj->Get(context, defaultKey).ToLocal(&webpackRequire) &&
                  webpackRequire->IsObject()) {
                if (IsScriptLoadingLogEnabled()) {
                  Log(@"[dyn-import] Found runtime module default export");
                }
                v8::Local<v8::String> installKey = tns::ToV8String(isolate, "C");
                v8::Local<v8::Value> installFn;
                if (webpackRequire.As<v8::Object>()->Get(context, installKey).ToLocal(&installFn) &&
                    installFn->IsFunction()) {
                  if (IsScriptLoadingLogEnabled()) {
                    Log(@"[dyn-import] Calling webpack installChunk function");
                  }
                  // Call webpack's installChunk function with the module namespace
                  v8::Local<v8::Value> args[] = {namespaceObj};
                  v8::Local<v8::Value> result;
                  if (!installFn.As<v8::Function>()
                           ->Call(context, v8::Undefined(isolate), 1, args)
                           .ToLocal(&result)) {
                    // If the call fails, we can ignore it since this is just a helper for webpack
                    // chunks
                    if (IsScriptLoadingLogEnabled()) {
                      Log(@"[dyn-import] ✗ webpack installChunk call failed");
                    }
                  } else {
                    if (IsScriptLoadingLogEnabled()) {
                      Log(@"[dyn-import] ✓ webpack installChunk call succeeded");
                    }
                  }
                } else {
                  if (IsScriptLoadingLogEnabled()) {
                    Log(@"[dyn-import] ✗ webpack installChunk function not found");
                  }
                }
              } else {
                if (IsScriptLoadingLogEnabled()) {
                  Log(@"[dyn-import] ✗ runtime module default export not found");
                }
              }
            }
          } else {
            if (IsScriptLoadingLogEnabled()) {
              Log(@"[dyn-import] ✗ runtime module not found");
            }
          }
        } catch (...) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import] ✗ exception while accessing runtime module");
          }
        }
      }
    }

    // Final verify before resolving for non-HTTP paths too
    v8::Local<v8::Value> nsFinal = module->GetModuleNamespace();
    if (nsFinal->IsObject()) {
      v8::Local<v8::Object> o = nsFinal.As<v8::Object>();
      v8::TryCatch tc3(isolate);
      v8::Local<v8::Value> defVal;
      if (!o->Get(context, tns::ToV8String(isolate, "default")).ToLocal(&defVal)) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][verify] ns.default threw after eval (generic) %s", specStr);
        }
        resolver->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, "TDZ on default after eval (generic)"))).Check();
        return scope.Escape(resolver->GetPromise());
      }
    }
    resolver->Resolve(context, module->GetModuleNamespace()).Check();
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[dyn-import] ✓ resolved %@", specStr);
    }
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[dyn-import] ✗ native failed %@", specStr);
    }
    resolver
        ->Reject(context, v8::Exception::Error(
                              tns::ToV8String(isolate, "Native error during dynamic import")))
        .Check();
  }

  return scope.Escape(resolver->GetPromise());
}
}
