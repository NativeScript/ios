// ModuleInternalCallbacks.mm
#include "ModuleInternalCallbacks.h"
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <sys/stat.h>
#include <v8.h>
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdio>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <vector>
#include "Caches.h"
#include "EventLoop.h"
#include "Helpers.h"  // for tns::Exists
#include "HttpLoader.h"
#include "ModuleInternal.h"  // for CompileFileEsModule / EvaluateModuleGraph
#include "NativeScriptException.h"
#include "NativeScriptPlatform.h"
#include "NsBuiltinModules.h"
#include "Runtime.h"  // for GetAppConfigValue
#include "RuntimeConfig.h"

// Do NOT pull all v8 symbols into namespace here; String would clash with
// other typedefs inside the NativeScript codebase. We refer to v8 symbols
// with explicit `v8::` qualification to avoid ambiguities.

namespace tns {

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
    return url;  // not a file URL; return as-is
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
// Defined with the async graph pipeline below; called from
// QuiesceModuleLoadsForIsolate so in-flight walks can't touch a disposed
// isolate.
static void KillAsyncGraphLoadsForIsolate(v8::Isolate* isolate);

namespace {
struct AsyncGraphLoad;

// One require(esm) exports facade and the module it wraps. Held as a pair
// because identity hashes collide: lookups compare the target handle.
struct RequireFacadeEntry {
  v8::Global<v8::Module> target;
  v8::Global<v8::Module> facade;
};

// All module-loader state owned by one isolate. v8::Global handles are bound
// to the isolate that created them, so each isolate (main + every Worker)
// keeps its own set. Lives in a Caches state slot (Caches::StateFor), so it is
// destroyed with the isolate's Caches — under the teardown Locker, while the
// isolate is still alive — which lets the v8::Global members Reset safely in
// their own destructors; nothing is left to static/thread destructors (where
// __cxa_finalize_ranges-time v8::Global resets crash). Access from the
// isolate's thread only, per the slot contract.
struct ModuleLoaderState {
  ModuleHandleMap registry;  // canonical key -> compiled module

  // In-flight async graph walks; entries are weak so a finished load frees
  // itself. A pending NSURLSession completion can hold the load's shared_ptr
  // past teardown, so QuiesceModuleLoadsForIsolate must flag these dead and
  // Reset their context Globals while the isolate is still alive — the slot
  // destructor alone is not enough for them.
  std::vector<std::weak_ptr<AsyncGraphLoad>> asyncGraphLoads;

  // HTTP dynamic imports currently fetching/evaluating, for coalescing.
  robin_hood::unordered_set<std::string> modulesInFlight;

  // Dynamic HTTP import waiters: resolve to the module namespace.
  robin_hood::unordered_map<std::string, std::vector<v8::Global<v8::Promise::Resolver>>>
      httpDynamicWaiters;

  // Reverse index: v8::Module::GetIdentityHash() -> registry keys, so
  // module→key lookups (resolver referrer discovery, import.meta) are O(1)
  // instead of a scan of the whole registry. Entries can go stale when a
  // registry slot is dropped or overwritten without a hash at hand;
  // FindKeyForModule verifies each candidate against the registry and prunes
  // stale ones lazily, so staleness is tolerated, never trusted.
  robin_hood::unordered_map<int, std::vector<std::string>> keysByModuleHash;

  // require(esm) facades, keyed by the TARGET module's identity hash — same
  // bucket-plus-handle-compare shape as keysByModuleHash. Repeated require()
  // of one ES module must hand back the identical exports object, and a facade
  // must never outlive the module it re-exports (RemoveModuleFromRegistry
  // drops the entry).
  robin_hood::unordered_map<int, std::vector<RequireFacadeEntry>> requireFacadesByTargetHash;

  // Holds the facade target across that facade's InstantiateModule and nothing
  // else — the facade's resolve callback is the only reader.
  v8::Global<v8::Module> pendingFacadeTarget;
};

// This isolate's loader state, or null once teardown has begun — callers must
// bail, not recreate state.
ModuleLoaderState* ModuleLoaderStateFor(v8::Isolate* isolate) {
  return Caches::StateFor<ModuleLoaderState>(isolate);
}

// Record `key` as a candidate for `mod`'s identity hash. Call alongside every
// registry insert.
void IndexRegisteredModule(ModuleLoaderState& state, const std::string& key,
                           v8::Local<v8::Module> mod) {
  if (mod.IsEmpty()) {
    return;
  }
  auto& keys = state.keysByModuleHash[mod->GetIdentityHash()];
  if (std::find(keys.begin(), keys.end(), key) == keys.end()) {
    keys.push_back(key);
  }
}

// The registry key whose live entry is `mod`, or empty. Prunes candidates the
// registry no longer confirms.
std::string FindKeyForModule(ModuleLoaderState& state, v8::Isolate* isolate,
                             v8::Local<v8::Module> mod) {
  if (mod.IsEmpty()) {
    return std::string();
  }
  auto bucketIt = state.keysByModuleHash.find(mod->GetIdentityHash());
  if (bucketIt == state.keysByModuleHash.end()) {
    return std::string();
  }
  auto& keys = bucketIt->second;
  for (auto it = keys.begin(); it != keys.end();) {
    auto regIt = state.registry.find(*it);
    if (regIt == state.registry.end() || regIt->second.IsEmpty()) {
      it = keys.erase(it);
      continue;
    }
    if (regIt->second.Get(isolate) == mod) {
      return *it;
    }
    ++it;
  }
  if (keys.empty()) {
    state.keysByModuleHash.erase(bucketIt);
  }
  return std::string();
}
}  // namespace

std::string LookupModuleKeyForModule(v8::Isolate* isolate, v8::Local<v8::Module> mod) {
  auto* state = ModuleLoaderStateFor(isolate);
  if (state == nullptr) {
    return std::string();
  }
  return FindKeyForModule(*state, isolate, mod);
}

namespace {
// The single module request in the facade source, and the source itself. Both
// match Node's required_module_facade_source_string so the semantics (live
// bindings, enumerable re-exports, overridable __esModule) stay identical.
constexpr const char* kRequireFacadeSpecifier = "original";
constexpr const char* kRequireFacadeSource =
    "export * from 'original'; export { default } from 'original'; "
    "export const __esModule = true;";

// Resolves the facade's one request. Passed only to a facade's
// InstantiateModule, so the general resolver never sees 'original' and user
// code can never reach this slot.
v8::MaybeLocal<v8::Module> ResolveRequireFacadeTarget(v8::Local<v8::Context> context,
                                                      v8::Local<v8::String> specifier,
                                                      v8::Local<v8::FixedArray> import_attributes,
                                                      v8::Local<v8::Module> referrer) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  auto* state = ModuleLoaderStateFor(isolate);
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const std::string spec = *specUtf8 ? *specUtf8 : "";
  if (state == nullptr || state->pendingFacadeTarget.IsEmpty() || spec != kRequireFacadeSpecifier) {
    Log(@"FATAL: require(esm) facade resolve for '%s' with no pending target", spec.c_str());
    isolate->ThrowException(v8::Exception::Error(
        tns::ToV8String(isolate, "require(esm) facade could not be linked to its target module")));
    return v8::MaybeLocal<v8::Module>();
  }
  return v8::MaybeLocal<v8::Module>(state->pendingFacadeTarget.Get(isolate));
}

// Drop any facade wrapping `target`. Called as the target leaves the registry:
// a facade whose re-export source is gone would serve a dead namespace.
void DropRequireFacadesForTarget(ModuleLoaderState& state, v8::Isolate* isolate,
                                 v8::Local<v8::Module> target) {
  if (target.IsEmpty()) {
    return;
  }
  auto bucketIt = state.requireFacadesByTargetHash.find(target->GetIdentityHash());
  if (bucketIt == state.requireFacadesByTargetHash.end()) {
    return;
  }
  auto& entries = bucketIt->second;
  for (auto it = entries.begin(); it != entries.end();) {
    if (it->target.Get(isolate) == target) {
      it = entries.erase(it);
    } else {
      ++it;
    }
  }
  if (entries.empty()) {
    state.requireFacadesByTargetHash.erase(bucketIt);
  }
}
}  // namespace

v8::MaybeLocal<v8::Module> GetOrCreateRequireFacade(v8::Isolate* isolate,
                                                    v8::Local<v8::Context> context,
                                                    v8::Local<v8::Module> target,
                                                    const std::string& targetCanonicalPath) {
  if (target.IsEmpty()) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto* state = ModuleLoaderStateFor(isolate);
  if (state == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }

  auto bucketIt = state->requireFacadesByTargetHash.find(target->GetIdentityHash());
  if (bucketIt != state->requireFacadesByTargetHash.end()) {
    for (auto& entry : bucketIt->second) {
      if (entry.target.Get(isolate) == target) {
        return v8::MaybeLocal<v8::Module>(entry.facade.Get(isolate));
      }
    }
  }

  v8::EscapableHandleScope hs(isolate);
  const std::string facadeUrl = "ns:require-facade:" + targetCanonicalPath;

  v8::Local<v8::String> urlV8;
  if (!v8::String::NewFromUtf8(isolate, facadeUrl.c_str(), v8::NewStringType::kNormal)
           .ToLocal(&urlV8)) {
    return v8::MaybeLocal<v8::Module>();
  }
  v8::ScriptOrigin origin(urlV8, 0, 0, false, -1, v8::Local<v8::Value>(), false, false, true);
  v8::ScriptCompiler::Source source(tns::ToV8String(isolate, kRequireFacadeSource), origin);

  v8::TryCatch tc(isolate);
  v8::Local<v8::Module> facade;
  if (!v8::ScriptCompiler::CompileModule(isolate, &source).ToLocal(&facade)) {
    throw NativeScriptException(isolate, tc,
                                "Cannot compile the require() facade for " + targetCanonicalPath);
  }

  bool linked = false;
  {
    // The slot must be clear again whichever way instantiation ends.
    struct PendingTargetScope {
      ModuleLoaderState* state;
      ~PendingTargetScope() { state->pendingFacadeTarget.Reset(); }
    } pendingScope{state};
    state->pendingFacadeTarget.Reset(isolate, target);
    linked = facade->InstantiateModule(context, &ResolveRequireFacadeTarget).FromMaybe(false);
  }
  if (!linked) {
    throw NativeScriptException(isolate, tc,
                                "Cannot link the require() facade for " + targetCanonicalPath);
  }

  // Three re-export statements over an already-evaluated module: trivially
  // synchronous, so the strict policy's settled-promise requirement holds.
  ModuleEvaluationOptions evalOptions;
  evalOptions.policy = ModuleEvaluationPolicy::kSyncStrict;
  EvaluateModuleGraph(isolate, context, facade, facadeUrl, evalOptions);

  // The facade is deliberately absent from the registry and the identity-hash
  // index: nothing resolves to it by name, and its source has no import.meta
  // or dynamic import, so no host callback ever needs to find it.
  RequireFacadeEntry entry;
  entry.target.Reset(isolate, target);
  entry.facade.Reset(isolate, facade);
  state->requireFacadesByTargetHash[target->GetIdentityHash()].push_back(std::move(entry));

  return hs.Escape(facade);
}

void IndexModuleForIsolate(v8::Isolate* isolate, const std::string& canonicalKey,
                           v8::Local<v8::Module> mod) {
  auto* state = ModuleLoaderStateFor(isolate);
  if (state == nullptr) {
    return;
  }
  IndexRegisteredModule(*state, canonicalKey, mod);
}

// Turn a value JS handed us into a real v8::Promise.
//
// A promise that reaches us from JS is usually NOT a v8::Promise: PromiseProxy
// replaces the global Promise with a Proxy whose construct trap returns
// `new Proxy(promise, ...)` so callbacks can be marshaled back to the creating
// runloop. Such a value satisfies `instanceof Promise` in JS but fails
// v8::Value::IsPromise(), so testing for a v8::Promise silently rejects
// perfectly good input. Adopt any thenable instead — Resolver::New builds on the
// intrinsic %Promise%, which the global override does not affect, and resolving
// it with a thenable adopts that thenable's state.
//
// Values produced by V8 itself (Module::Evaluate) are genuine promises and take
// the fast path.
static v8::MaybeLocal<v8::Promise> AdoptThenable(v8::Isolate* isolate,
                                                 v8::Local<v8::Context> context,
                                                 v8::Local<v8::Value> value) {
  if (value.IsEmpty()) {
    return v8::MaybeLocal<v8::Promise>();
  }
  if (value->IsPromise()) {
    return value.As<v8::Promise>();
  }
  if (!value->IsObject()) {
    return v8::MaybeLocal<v8::Promise>();
  }

  v8::Local<v8::Value> thenVal;
  if (!value.As<v8::Object>()->Get(context, tns::ToV8String(isolate, "then")).ToLocal(&thenVal) ||
      !thenVal->IsFunction()) {
    return v8::MaybeLocal<v8::Promise>();
  }

  v8::Local<v8::Promise::Resolver> adopter;
  if (!v8::Promise::Resolver::New(context).ToLocal(&adopter) ||
      adopter->Resolve(context, value).IsNothing()) {
    return v8::MaybeLocal<v8::Promise>();
  }
  return adopter->GetPromise();
}

static v8::MaybeLocal<v8::Module> CompileModuleFromSource(v8::Isolate* isolate,
                                                          v8::Local<v8::Context> context,
                                                          const std::string& code,
                                                          const std::string& urlStr) {
  v8::EscapableHandleScope hs(isolate);
  // Pass the std::string (length-aware overload), NOT code.c_str(): module
  // source may contain embedded NUL bytes and the char* path would truncate.
  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, code);
  v8::Local<v8::String> urlV8;
  if (!v8::String::NewFromUtf8(isolate, urlStr.c_str(), v8::NewStringType::kNormal)
           .ToLocal(&urlV8)) {
    return v8::MaybeLocal<v8::Module>();
  }
  v8::ScriptOrigin origin(urlV8, 0, 0, false, -1, v8::Local<v8::Value>(), false, false, true);
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
static v8::MaybeLocal<v8::Module> CompileModuleForResolveRegisterOnly(
    v8::Isolate* isolate, v8::Local<v8::Context> context, const std::string& code,
    const std::string& urlStr) {
  v8::EscapableHandleScope hs(isolate);
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto& registry = moduleState->registry;
  const std::string registryKey = CanonicalizeRegistryKey(urlStr);
  if (IsScriptLoadingLogEnabled() && ShouldTraceRegistryKey(urlStr, registryKey)) {
    Log(@"[resolver][register-resolve-only] raw=%s key=%s", urlStr.c_str(), registryKey.c_str());
  }
  // Length-aware conversion (see CompileModuleFromSource) — embedded NULs
  // in module source must not truncate the compile input.
  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, code);
  v8::Local<v8::String> urlV8;
  if (!v8::String::NewFromUtf8(isolate, urlStr.c_str(), v8::NewStringType::kNormal)
           .ToLocal(&urlV8)) {
    return v8::MaybeLocal<v8::Module>();
  }
  v8::ScriptOrigin origin(urlV8, 0, 0, false, -1, v8::Local<v8::Value>(), false, false, true);
  v8::ScriptCompiler::Source src(sourceText, origin);
  v8::Local<v8::Module> mod;
  {
    v8::TryCatch tcCompile(isolate);
    if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&mod)) {
      if (RuntimeConfig.IsDebug) {
        uint64_t h = 1469598103934665603ull;  // FNV-1a 64-bit
        for (unsigned char c : code) {
          h ^= c;
          h *= 1099511628211ull;
        }
        std::string snippet = code.substr(0, 600);
        for (char& ch : snippet) {
          if (ch == '\n' || ch == '\r') ch = ' ';
        }
        const char* classification = "unknown";
        v8::Local<v8::Message> message = tcCompile.Message();
        std::string msgStr = "";
        std::string srcLineStr = "";
        int lineNum = 0;
        int startCol = 0;
        int endCol = 0;
        if (!message.IsEmpty()) {
          v8::String::Utf8Value m8(isolate, message->Get());
          if (*m8) msgStr = *m8;
          lineNum = message->GetLineNumber(context).FromMaybe(0);
          startCol = message->GetStartColumn();
          endCol = message->GetEndColumn();
          v8::MaybeLocal<v8::String> maybeLine = message->GetSourceLine(context);
          if (!maybeLine.IsEmpty()) {
            v8::String::Utf8Value l8(isolate, maybeLine.ToLocalChecked());
            if (*l8) srcLineStr = *l8;
          }
          // Classification heuristics based on message
          if (msgStr.find("Unexpected identifier") != std::string::npos ||
              msgStr.find("Unexpected token") != std::string::npos) {
            // refine unexpected token categories
            if (msgStr.find("export") != std::string::npos &&
                code.find("export default") == std::string::npos &&
                code.find("__sfc__") != std::string::npos)
              classification = "missing-export-default";
            else
              classification = "syntax";
          } else if (msgStr.find("Cannot use import statement") != std::string::npos) {
            classification = "wrap-error";
          }
        }
        if (classification == std::string("unknown")) {
          if (code.find("export default") == std::string::npos &&
              code.find("__sfc__") != std::string::npos)
            classification = "missing-export-default";
          else if (code.find("__sfc__") != std::string::npos &&
                   code.find("export {") == std::string::npos &&
                   code.find("export ") == std::string::npos)
            classification = "no-exports";
          else if (code.find("import ") == std::string::npos &&
                   code.find("export ") == std::string::npos)
            classification = "not-module";
          else if (code.find("_openBlock") != std::string::npos &&
                   code.find("openBlock") == std::string::npos)
            classification = "underscore-helper-unmapped";
        }
        // Trim srcLineStr
        if (srcLineStr.size() > 240) srcLineStr = srcLineStr.substr(0, 240);
        Log(@"[http-esm][compile][v8-error][%s] %s line=%d col=%d..%d hash=%llx bytes=%lu msg=%s "
            @"srcLine=%s snippet=%s",
            classification, urlStr.c_str(), lineNum, startCol, endCol, (unsigned long long)h,
            (unsigned long)code.size(), msgStr.c_str(), srcLineStr.c_str(), snippet.c_str());
      }
      return v8::MaybeLocal<v8::Module>();
    }
  }
  // If an entry already exists, reuse it
  auto itExisting = registry.find(registryKey);
  if (itExisting != registry.end()) {
    v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
    if (!existing.IsEmpty()) {
      return hs.Escape(existing);
    }
  }
  registry[registryKey].Reset(isolate, mod);
  IndexRegisteredModule(*moduleState, registryKey, mod);
  return hs.Escape(mod);
}

// ────────────────────────────────────────────────────────────────────────────
// Per-isolate module registries: map absolute file paths / canonical URLs →
// compiled v8::Module handles, keyed by the owning v8::Isolate*.
//
// Why per-isolate (not process-global, not thread_local): v8::Global<T> handles
// are bound to the isolate that created them; reading their internal state from
// a different isolate is undefined behaviour. NS Workers each run a separate
// v8::Isolate on their own thread (see Worker::ConstructorCallback in
// Worker.mm) and, under HMR, fetch the SAME `/ns/m/` URLs the main thread
// already loaded — a shared map would hand the worker isolate a Module the
// main isolate compiled, and V8's linker would read the cross-isolate export
// table and emit bogus errors like:
//   SyntaxError: The requested module 'X' does not provide an export named 'Y'
// thread_local maps would avoid that only while each isolate happens to be
// pinned to a single thread; keying explicitly by v8::Isolate* stays correct
// even if an isolate is ever entered from another thread under v8::Locker.
//
// Lifetime: the state is created lazily on first access and destroyed with the
// isolate's Caches (Runtime::~Runtime → Caches::Remove, under v8::Locker,
// before isolate disposal). The Runtime destructor additionally calls
// QuiesceModuleLoadsForIsolate() first, so in-flight async graph loads whose
// completions are still queued on background NSURLSession queues observe the
// dead flag before they hop to the JS runloop.
//
// Each access site binds a local reference (e.g.
// `auto& registry = moduleState->registry;`) so existing bodies stay
// byte-for-byte the same while becoming isolate-correct. Accessors return null
// once teardown has begun.
ModuleHandleMap* ModuleRegistryFor(v8::Isolate* isolate) {
  auto* state = ModuleLoaderStateFor(isolate);
  return state == nullptr ? nullptr : &state->registry;
}

// Neutralize any in-flight async graph loads for `isolate`: their fetch
// completions check the dead flag before touching V8, and their context
// Globals are Reset here, while the isolate is still alive. The rest of the
// loader state is destroyed with the isolate's Caches.
void QuiesceModuleLoadsForIsolate(v8::Isolate* isolate) { KillAsyncGraphLoadsForIsolate(isolate); }

// ────────────────────────────────────────────────────────────────────────────
// Import map: bare specifier → resolved URL (populated by ns:module configureLoader)
// Instead of rewriting import statements in source code on the Vite side, the runtime
// resolves bare specifiers through this map to HTTP module URLs. Source code
// is served as Vite transformed it.
static robin_hood::unordered_map<std::string, std::string> g_importMap;

// Volatile URL patterns: URLs matching these substrings are always re-fetched
// (cache is evicted before loading). Configured by Vite at boot — the
// vocabulary is server/framework policy, so the runtime carries no
// framework-specific URL strings here.
static std::vector<std::string> g_volatilePatterns;

static bool ShouldTraceRegistryKey(const std::string& rawKey, const std::string& registryKey) {
  if (rawKey != registryKey) {
    return true;
  }

  return StartsWith(registryKey, "optional:") || StartsWith(registryKey, "node:") ||
         StartsWith(registryKey, "blob:");
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
    // Preserve non-filesystem module namespaces such as optional: and node:
    // so synthetic/in-memory modules keep their exact registry identity.
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
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto& registry = moduleState->registry;
  const std::string registryKey = CanonicalizeHttpUrlKey(requestedUrl);

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[http-esm][load][begin] request=%s key=%s", requestedUrl.c_str(), registryKey.c_str());
  }

  auto itExisting = registry.find(registryKey);
  if (itExisting != registry.end()) {
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
    RemoveModuleFromRegistry(isolate, registryKey);
  }

  std::string body;
  std::string contentType;
  int status = 0;
  if (!HttpFetchText(requestedUrl, body, contentType, status) || body.empty()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][load][fetch-fail] request=%s key=%s status=%d", requestedUrl.c_str(),
          registryKey.c_str(), status);
    }
    std::string msg =
        "HTTP import failed: " + requestedUrl + " (status=" + std::to_string(status) + ")";
    isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
    return v8::MaybeLocal<v8::Module>();
  }

  v8::MaybeLocal<v8::Module> loaded =
      CompileModuleForResolveRegisterOnly(isolate, context, body, registryKey);
  if (loaded.IsEmpty()) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][load][compile-fail] request=%s key=%s bytes=%zu", requestedUrl.c_str(),
          registryKey.c_str(), body.size());
    }
    std::string msg = "HTTP import compile failed: " + requestedUrl;
    isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
    return v8::MaybeLocal<v8::Module>();
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[http-esm][load][ok] request=%s key=%s type=%s bytes=%zu", requestedUrl.c_str(),
        registryKey.c_str(), contentType.c_str(), body.size());
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
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&err];
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
//                        "/node_modules/.vite/deps/@tanstack_solid-router.js" →
//                        "@tanstack/solid-router"
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
            for (const auto& suffix :
                 {std::string(".ios"), std::string(".android"), std::string(".visionos")}) {
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
          Log(@"[import-map][normalize] node_modules: %s -> %s", specifier.c_str(),
              normalized.c_str());
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
      Log(@"[import-map] prefix: %s -> %s (via %s)", specifier.c_str(), resolved.c_str(),
          bestKey.c_str());
    }
    return resolved;
  }
  return "";
}

void CleanupImportMapGlobals() {
  // Process-global import-map state (not isolate-bound). The per-isolate
  // loader state lives in a Caches state slot and is destroyed with each
  // isolate's Caches (after QuiesceModuleLoadsForIsolate in ~Runtime).
  g_importMap.clear();
  g_volatilePatterns.clear();
}

// ────────────────────────────────────────────────────────────────────────────
// Async HTTP module-graph pipeline
//
// See the contract comment in ModuleInternalCallbacks.h. Mechanically:
//
//   EnqueueUrl(root)
//     → FetchModuleBodyAsync (NSURLSession on a
//       background queue — see HttpLoader.mm)
//     → hop to the isolate's JS thread (ExecuteOnRunLoop on the runtime loop)
//     → CompileModuleForResolveRegisterOnly (registers under the canonical
//       URL key — the exact entry ResolveModuleCallback will look up)
//     → GetModuleRequests() → ResolveModuleRequestForWalk → EnqueueUrl(…)
//     → when pendingFetches drains, onComplete fires on the JS thread.
//
// Thread discipline: `visited`, `pendingFetches`, `failed`, `completed` are
// touched ONLY on the isolate's JS thread (every fetch completion hops there
// first). Only raw I/O runs off-thread. The one crossing signal is `dead`,
// an atomic set by isolate teardown so in-flight completions become no-ops
// instead of touching a disposed isolate.
//
// Failure semantics are deliberately unchanged from the synchronous loader:
// only a ROOT fetch/compile failure fails the walk (mirroring today's
// reject on LoadHttpModuleForUrl miss). A dependency failure is logged and
// left for the resolver's synchronous fallback to surface during
// instantiation — so in Stage A the walk is purely an optimization layer.

namespace {
struct AsyncGraphLoad {
  v8::Isolate* isolate = nullptr;
  v8::Global<v8::Context> context;
  std::string rootKey;                             // canonical registry key of the root URL
  robin_hood::unordered_set<std::string> visited;  // canonical keys (JS thread only)
  int pendingFetches = 0;                          // JS thread only
  bool failed = false;                             // JS thread only (root failure)
  bool completed = false;                          // JS thread only
  std::string failureMessage;
  size_t fetchedCount = 0;
  size_t compiledCount = 0;
  uint64_t startUs = 0;
  std::atomic<bool> dead{false};  // set by isolate teardown (any thread)
  std::function<void(bool ok, const std::string& errorMessage, v8::Local<v8::Context> context)>
      onComplete;

  ~AsyncGraphLoad() {
    // Runs on the JS thread on the normal path (the last reference is the
    // completion task executed there). On the teardown path the context
    // Global has already been Reset by KillAsyncGraphLoadsForIsolate, so
    // destroying it from a background thread is a no-op.
    g_asyncGraphLoadsInFlightCounter().fetch_sub(1, std::memory_order_acq_rel);
  }

  static std::atomic<int>& g_asyncGraphLoadsInFlightCounter() {
    static std::atomic<int> counter{0};
    return counter;
  }
};

// Adapter so fetch completions ride the isolate's foreground task queue
// (EventLoop::PostV8Task) like any other v8 platform task.
class FetchCompletionTask : public v8::Task {
 public:
  explicit FetchCompletionTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Run() override { fn_(); }

 private:
  std::function<void()> fn_;
};

// Registration and quiesce both run on the isolate's thread (the slot
// contract); background fetch completions only ever touch the AsyncGraphLoad
// they retain, never this list, so no lock is needed.
void RegisterAsyncGraphLoad(v8::Isolate* isolate, const std::shared_ptr<AsyncGraphLoad>& load) {
  auto* state = ModuleLoaderStateFor(isolate);
  if (state == nullptr) {
    return;
  }
  auto& loads = state->asyncGraphLoads;
  // Prune expired entries opportunistically so the vector stays small.
  loads.erase(std::remove_if(loads.begin(), loads.end(),
                             [](const std::weak_ptr<AsyncGraphLoad>& w) { return w.expired(); }),
              loads.end());
  loads.push_back(load);
}
}  // namespace

bool HasPendingAsyncModuleGraphWork() {
  return AsyncGraphLoad::g_asyncGraphLoadsInFlightCounter().load(std::memory_order_acquire) > 0;
}

// Isolate-teardown hook: mark every in-flight load owned by `isolate` dead
// (pending fetch completions become no-ops) and Reset their context Globals
// NOW, while the isolate is still alive — nothing may destroy a v8::Global
// after isolate disposal, and a pending NSURLSession completion can hold a
// load's shared_ptr past teardown, so the slot destructor alone cannot cover
// these. Called from QuiesceModuleLoadsForIsolate.
static void KillAsyncGraphLoadsForIsolate(v8::Isolate* isolate) {
  auto* state = ModuleLoaderStateFor(isolate);
  if (state == nullptr) {
    return;
  }
  for (auto& weak : state->asyncGraphLoads) {
    if (auto load = weak.lock()) {
      load->dead.store(true, std::memory_order_release);
      load->context.Reset();
    }
  }
  state->asyncGraphLoads.clear();
}

// Resolve one static module request to an absolute HTTP(S) URL using the
// SAME logic ResolveModuleCallback applies, in the same order: malformed
// scheme repair → import map (direct, then Vite-normalized) → absolute
// HTTP passthrough → relative/root-absolute resolution against an HTTP
// referrer. Returns empty for everything the walk should NOT touch (local
// files, tilde paths, unmapped bare specifiers, node: builtins without an
// import-map entry) — those stay on the resolver's lazy synchronous path.
static std::string ResolveModuleRequestForWalk(const std::string& rawSpec,
                                               const std::string& referrerUrl) {
  if (rawSpec.empty() || rawSpec == "@") {
    return "";
  }
  std::string spec = rawSpec;
  if (spec.rfind("http:/", 0) == 0 && spec.rfind("http://", 0) != 0) {
    spec.insert(5, "/");
  } else if (spec.rfind("https:/", 0) == 0 && spec.rfind("https://", 0) != 0) {
    spec.insert(6, "/");
  }

  if (!g_importMap.empty()) {
    std::string mapped = LookupImportMap(spec);
    if (mapped.empty()) {
      std::string normalized = NormalizeViteSpecifier(spec);
      if (!normalized.empty()) {
        mapped = LookupImportMap(normalized);
      }
    }
    if (!mapped.empty()) {
      spec = mapped;
    }
  }

  if (StartsWith(spec, "http://") || StartsWith(spec, "https://")) {
    return spec;
  }

  const bool specIsRelative = !spec.empty() && spec[0] == '.';
  const bool specIsRootAbs = !spec.empty() && spec[0] == '/';
  const bool referrerIsHttp =
      StartsWith(referrerUrl, "http://") || StartsWith(referrerUrl, "https://");
  if ((specIsRelative || specIsRootAbs) && referrerIsHttp) {
    std::string resolved;
    @autoreleasepool {
      NSString* baseStr = [NSString stringWithUTF8String:referrerUrl.c_str()];
      NSString* specStr = [NSString stringWithUTF8String:spec.c_str()];
      if (baseStr && specStr) {
        NSURL* baseURL = [NSURL URLWithString:baseStr];
        NSURL* rel = [NSURL URLWithString:specStr relativeToURL:baseURL];
        NSURL* absURL = [rel absoluteURL];
        if (absURL) {
          NSString* absStr = [absURL absoluteString];
          if (absStr) {
            resolved = std::string([absStr UTF8String] ?: "");
          }
        }
      }
    }
    if (StartsWith(resolved, "http://") || StartsWith(resolved, "https://")) {
      return resolved;
    }
  }

  return "";
}

static void AsyncGraphEnqueueUrl(const std::shared_ptr<AsyncGraphLoad>& load,
                                 const std::string& url);

// Walk `mod`'s static module requests and enqueue every HTTP-resolvable
// dependency. JS thread only; `moduleUrl` is the canonical URL the module
// was registered under (the referrer for relative resolution).
static void AsyncGraphWalkModuleRequests(const std::shared_ptr<AsyncGraphLoad>& load,
                                         v8::Local<v8::Context> context, v8::Local<v8::Module> mod,
                                         const std::string& moduleUrl) {
  v8::Isolate* isolate = load->isolate;
  v8::Local<v8::FixedArray> requests = mod->GetModuleRequests();
  const int length = requests->Length();
  for (int i = 0; i < length; i++) {
    v8::Local<v8::ModuleRequest> request = requests->Get(i).As<v8::ModuleRequest>();
    if (request.IsEmpty()) {
      continue;
    }
    v8::Local<v8::String> specV8 = request->GetSpecifier();
    v8::String::Utf8Value specUtf8(isolate, specV8);
    if (!*specUtf8) {
      continue;
    }
    std::string resolved = ResolveModuleRequestForWalk(*specUtf8, moduleUrl);
    if (resolved.empty()) {
      continue;
    }
    AsyncGraphEnqueueUrl(load, resolved);
  }
}

// Fire onComplete exactly once, when the frontier has drained. JS thread only.
static void AsyncGraphMaybeComplete(const std::shared_ptr<AsyncGraphLoad>& load,
                                    v8::Local<v8::Context> context) {
  if (load->completed || load->pendingFetches > 0) {
    return;
  }
  load->completed = true;
  if (IsScriptLoadingLogEnabled()) {
    const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t ms = endUs > load->startUs ? (endUs - load->startUs) / 1000ull : 0ull;
    Log(@"[async-graph][done] root=%s urls=%lu fetched=%lu compiled=%lu ms=%llu ok=%d",
        load->rootKey.c_str(), (unsigned long)load->visited.size(),
        (unsigned long)load->fetchedCount, (unsigned long)load->compiledCount,
        (unsigned long long)ms, load->failed ? 0 : 1);
  }
  auto onComplete = std::move(load->onComplete);
  load->onComplete = nullptr;
  if (onComplete) {
    // The completion may run outside any V8 host callback (CFRunLoop
    // callout), where a pending exception thrown by the legacy loader's
    // debug path (isolate->ThrowException in LoadHttpModuleForUrl) has no
    // V8 frame to land in. Every failure path below already surfaces the
    // error through promise rejection, so swallow anything left pending.
    v8::TryCatch tc(load->isolate);
    onComplete(!load->failed, load->failureMessage, context);
  }
}

// A fetched body arrived on the isolate's JS thread: compile + register it,
// then walk its requests. Runs outside any V8 scope (CFRunLoop callout), so
// it enters the isolate the same way other cross-thread callbacks do.
static void AsyncGraphOnFetchCompleted(const std::shared_ptr<AsyncGraphLoad>& load,
                                       const std::string& url, bool ok, int status,
                                       const std::shared_ptr<std::string>& body) {
  if (load->dead.load(std::memory_order_acquire)) {
    return;
  }
  v8::Isolate* isolate = load->isolate;
  if (Runtime::GetRuntime(isolate) == nullptr) {
    // Isolate torn down between scheduling and execution.
    return;
  }

  v8::Locker locker(isolate);
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  v8::Local<v8::Context> context = load->context.Get(isolate);
  if (context.IsEmpty()) {
    return;
  }
  v8::Context::Scope context_scope(context);

  load->pendingFetches--;

  const std::string key = CanonicalizeHttpUrlKey(url);
  const bool isRoot = (key == load->rootKey);

  if (!load->failed) {
    if (!ok) {
      if (isRoot) {
        load->failed = true;
        load->failureMessage =
            "HTTP import failed: " + url + " (status=" + std::to_string(status) + ")";
      } else if (IsScriptLoadingLogEnabled()) {
        Log(@"[async-graph][dep-fetch-fail] %s status=%d (left to sync resolver)", url.c_str(),
            status);
      }
    } else {
      load->fetchedCount++;
      v8::MaybeLocal<v8::Module> maybeMod =
          CompileModuleForResolveRegisterOnly(isolate, context, *body, key);
      v8::Local<v8::Module> mod;
      if (!maybeMod.ToLocal(&mod)) {
        if (isRoot) {
          load->failed = true;
          load->failureMessage = "HTTP import compile failed: " + url;
        } else if (IsScriptLoadingLogEnabled()) {
          Log(@"[async-graph][dep-compile-fail] %s (left to sync resolver)", url.c_str());
        }
      } else {
        load->compiledCount++;
        AsyncGraphWalkModuleRequests(load, context, mod, key);
      }
    }
  }

  AsyncGraphMaybeComplete(load, context);
  // Promise jobs produced by onComplete (waiter resolution, TLA chains) run
  // now — mirrors how the sync loader's boot pump drains microtasks.
  isolate->PerformMicrotaskCheckpoint();
}

// Enqueue one URL into the walk frontier. JS thread only.
static void AsyncGraphEnqueueUrl(const std::shared_ptr<AsyncGraphLoad>& load,
                                 const std::string& url) {
  const std::string key = CanonicalizeHttpUrlKey(url);
  if (!load->visited.insert(key).second) {
    return;
  }

  v8::Isolate* isolate = load->isolate;
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& registry = moduleState->registry;
  auto it = registry.find(key);
  if (it != registry.end()) {
    v8::Local<v8::Module> existing = it->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
      if (existing->GetStatus() == v8::Module::kUninstantiated) {
        // Compiled but never linked (an earlier partial walk): its own
        // requests may not be registered yet — keep walking through it
        // without re-fetching.
        v8::Local<v8::Context> context = load->context.Get(isolate);
        if (!context.IsEmpty()) {
          AsyncGraphWalkModuleRequests(load, context, existing, key);
        }
      }
      return;  // instantiated/evaluated → its closure is already resolved
    }
    // Errored entry: drop and refetch, mirroring LoadHttpModuleForUrl.
    RemoveModuleFromRegistry(isolate, key);
  }

  load->pendingFetches++;
  std::shared_ptr<AsyncGraphLoad> loadRef = load;
  FetchModuleBodyAsync(url, [loadRef, url](bool ok, int status, std::string body) {
    // Arbitrary thread. Hop to the isolate's home thread as a nestable v8
    // foreground task — thread-independent delivery, so an import() issued
    // from a background thread still lands on the isolate's own event loop,
    // and the boot pump's RunNestableV8Tasks can drain it with JS frames on
    // the stack. If the isolate died in between, drop everything — the
    // context Global was already Reset by the teardown hook, which runs
    // before the event loop shuts down, so a post dropped on this thread
    // destroys only inert state.
    if (loadRef->dead.load(std::memory_order_acquire)) {
      return;
    }
    auto* platform = NativeScriptPlatform::Instance();
    std::shared_ptr<EventLoop> loop =
        platform != nullptr ? platform->LookupEventLoop(loadRef->isolate) : nullptr;
    if (loop == nullptr) {
      return;
    }
    auto bodyPtr = std::make_shared<std::string>(std::move(body));
    loop->PostV8Task(std::make_unique<FetchCompletionTask>([loadRef, url, ok, status, bodyPtr]() {
                       AsyncGraphOnFetchCompleted(loadRef, url, ok, status, bodyPtr);
                     }),
                     /*nestable=*/true, /*delaySeconds=*/0);
  });
}

void StartAsyncHttpModuleGraphLoad(
    v8::Isolate* isolate, v8::Local<v8::Context> context, const std::string& rootUrl,
    std::function<void(bool ok, const std::string& errorMessage, v8::Local<v8::Context> context)>
        onComplete) {
  auto load = std::make_shared<AsyncGraphLoad>();
  load->isolate = isolate;
  load->context.Reset(isolate, context);
  load->rootKey = CanonicalizeHttpUrlKey(rootUrl);
  load->startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
  load->onComplete = std::move(onComplete);

  AsyncGraphLoad::g_asyncGraphLoadsInFlightCounter().fetch_add(1, std::memory_order_acq_rel);
  RegisterAsyncGraphLoad(isolate, load);

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[async-graph][start] root=%s key=%s", rootUrl.c_str(), load->rootKey.c_str());
  }

  AsyncGraphEnqueueUrl(load, rootUrl);
  // Root already registered (or nothing fetchable): complete inline.
  AsyncGraphMaybeComplete(load, context);
}

bool RunAsyncHttpModuleGraphLoadPumped(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                       const std::string& rootUrl, double timeoutSeconds) {
  if (timeoutSeconds <= 0.0) {
    timeoutSeconds = 60.0;
  }
  auto done = std::make_shared<bool>(false);
  StartAsyncHttpModuleGraphLoad(isolate, context, rootUrl,
                                [done](bool /*ok*/, const std::string& /*errorMessage*/,
                                       v8::Local<v8::Context>) { *done = true; });

  // Manual pump ("until either all is settled or UIApplicationMain is
  // called"). Fetch completions are nestable v8 foreground tasks on the
  // isolate's event loop, drained directly; the short RunInMode slice stays
  // as the idle-wait and still services any other runloop-delivered work the
  // walk indirectly depends on. If UIApplicationMain takes over later, its
  // runloop services the remainder instead.
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> eventLoop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds;
  while (!*done && CFAbsoluteTimeGetCurrent() < deadline) {
    if (eventLoop != nullptr) {
      eventLoop->RunNestableV8Tasks();
    }
    if (*done) {
      break;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
  }
  if (!*done && IsScriptLoadingLogEnabled()) {
    Log(@"[async-graph][pumped][timeout] root=%s after %.1fs (sync loader takes over)",
        rootUrl.c_str(), timeoutSeconds);
  }
  return *done;
}

static void RejectAndClearInvalidatedModuleState(v8::Isolate* isolate,
                                                 v8::Local<v8::Context> context,
                                                 const std::string& registryKey);

void RemoveModuleFromRegistry(v8::Isolate* isolate, const std::string& canonicalPath) {
  if (isolate == nullptr) {
    return;
  }
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& registry = moduleState->registry;
  const std::string registryKey = CanonicalizeRegistryKey(canonicalPath);
  // Defensive: never operate on an anomalous/sentinel key.
  // This covers the bare "@" anomaly and the special invalid-at stub module used by the dev HTTP
  // loader.
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
      Log(@"[resolver][remove:pre] raw=%s key=%s class=%s", canonicalPath.c_str(),
          registryKey.c_str(), classify(registryKey));
    } else {
      Log(@"[resolver][remove:pre] key=%s class=%s", registryKey.c_str(), classify(registryKey));
    }
  }

  size_t regPre = registry.size();

  auto it = registry.find(registryKey);
  if (it != registry.end()) {
    // Only log stale removal for non-HTTP keys to avoid noisy dev HTTP churn.
    bool isHttpKey = StartsWith(registryKey, "http://") || StartsWith(registryKey, "https://");
    if (IsScriptLoadingLogEnabled() && !isHttpKey) {
      Log(@"[resolver] removing stale module %@",
          [NSString stringWithUTF8String:registryKey.c_str()]);
    }
    v8::Local<v8::Module> doomed = it->second.Get(isolate);
    if (!doomed.IsEmpty()) {
      DropRequireFacadesForTarget(*moduleState, isolate, doomed);
      auto bucketIt = moduleState->keysByModuleHash.find(doomed->GetIdentityHash());
      if (bucketIt != moduleState->keysByModuleHash.end()) {
        auto& keys = bucketIt->second;
        keys.erase(std::remove(keys.begin(), keys.end(), registryKey), keys.end());
        if (keys.empty()) {
          moduleState->keysByModuleHash.erase(bucketIt);
        }
      }
    }
    it->second.Reset();
    registry.erase(it);
  } else if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][remove:miss] key not found, proceed to clear fallbacks (%s)",
        registryKey.c_str());
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][remove:post] reg %lu→%lu", (unsigned long)regPre,
        (unsigned long)registry.size());
  }
}

std::vector<std::string> GetLoadedModuleUrls() {
  std::vector<std::string> urls;
  // Read-only registry introspection for the current isolate (HMR runs this on
  // the isolate's own JS thread).
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  if (isolate == nullptr) {
    return urls;
  }
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return urls;
  }
  auto& registry = moduleState->registry;
  urls.reserve(registry.size());

  for (const auto& entry : registry) {
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
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& registry = moduleState->registry;
  if (urls.empty()) return;

  robin_hood::unordered_set<std::string> seen;
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
    bool present = registry.find(url) != registry.end();
    if (present) {
      hits++;
    } else {
      misses++;
    }
    if (logScriptLoading) {
      Log(@"[ns-hmr][ios-invalidate] %s key=%s", present ? "HIT " : "MISS", url.c_str());
    }

    RejectAndClearInvalidatedModuleState(isolate, context, url);
    RemoveModuleFromRegistry(isolate, url);
  }

  // Second layer: the OS/CFNetwork HTTP cache is outside the runtime's
  // direct control and has been observed serving a previous save's body
  // even with `no-store` headers + a reload-ignoring cache policy
  // (iOS 18+/26+ Simulator). Mark every invalidated key so the NEXT
  // network fetch of that URL carries a unique `__ns_dev_nonce` query
  // param — CFNetwork sees a URL it has never cached and must go to
  // origin. The nonce is transport-only; module identity stays the
  // canonical URL.
  MarkUrlsForCacheBust(uniqueUrls);

  if (logScriptLoading) {
    Log(@"[ns-hmr][ios-invalidate] summary unique=%lu hits=%lu misses=%lu (registry now=%lu)",
        (unsigned long)uniqueUrls.size(), (unsigned long)hits, (unsigned long)misses,
        (unsigned long)registry.size());
  }
}

static bool IsModuleEvaluationInProgress(v8::Module::Status status) {
  return status == v8::Module::kInstantiating || status == v8::Module::kEvaluating;
}

static void ResolveResolversWithModuleNamespace(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    std::vector<v8::Global<v8::Promise::Resolver>>& resolvers, v8::Local<v8::Module> module,
    const std::string& registryKey) {
  if (resolvers.empty()) {
    return;
  }

  if (module.IsEmpty() || module->GetStatus() != v8::Module::kEvaluated) {
    v8::Local<v8::String> errMsg =
        tns::ToV8String(isolate, ("Module did not finish evaluation: " + registryKey).c_str());
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

static void RejectResolversWithReason(v8::Isolate* isolate, v8::Local<v8::Context> context,
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

static bool QueueHttpDynamicWaiterIfInFlight(v8::Isolate* isolate, const std::string& registryKey,
                                             v8::Local<v8::Module> module,
                                             v8::Local<v8::Promise::Resolver> resolver) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return false;
  }
  auto& modulesInFlight = moduleState->modulesInFlight;
  if (registryKey.empty() || module.IsEmpty() ||
      !IsModuleEvaluationInProgress(module->GetStatus()) ||
      modulesInFlight.find(registryKey) == modulesInFlight.end()) {
    return false;
  }

  moduleState->httpDynamicWaiters[registryKey].emplace_back(isolate, resolver);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import][http-await] queued waiter for %s status=%s", registryKey.c_str(),
        ModuleStatusToString(module->GetStatus()));
  }
  return true;
}

// Build a rejection reason that PRESERVES the underlying V8 exception text.
// InstantiateModule/Evaluate failures carry precise, actionable messages
// (e.g. "The requested module '<url>' does not provide an export named
// '<name>'"); rejecting with only a generic stage label ("Instantiation
// failed (http-loader)") swallows them and turns a one-line fix into a
// device-side debugging session. `tc` must be the TryCatch that was active
// around the failing call.
static v8::Local<v8::Value> BuildModuleFailureReason(v8::Isolate* isolate, v8::TryCatch& tc,
                                                     const char* stage,
                                                     const std::string& urlOrKey) {
  std::string message = std::string(stage) + ": " + urlOrKey;
  if (tc.HasCaught()) {
    v8::Local<v8::Message> excMessage = tc.Message();
    if (!excMessage.IsEmpty()) {
      v8::String::Utf8Value text(isolate, excMessage->Get());
      if (*text != nullptr && strlen(*text) > 0) {
        message += std::string(" — ") + *text;
      }
    } else {
      v8::Local<v8::Value> exception = tc.Exception();
      if (!exception.IsEmpty()) {
        v8::String::Utf8Value text(isolate, exception);
        if (*text != nullptr && strlen(*text) > 0) {
          message += std::string(" — ") + *text;
        }
      }
    }
  }
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import][failure] %s", message.c_str());
  }
  return v8::Exception::Error(tns::ToV8String(isolate, message.c_str()));
}

static void ResolveHttpDynamicWaiters(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                      const std::string& registryKey,
                                      v8::Local<v8::Module> module) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  auto waitIt = httpDynamicWaiters.find(registryKey);
  if (waitIt != httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(waitIt->second);
    httpDynamicWaiters.erase(waitIt);
    ResolveResolversWithModuleNamespace(isolate, context, resolvers, module, registryKey);
  }

  moduleState->modulesInFlight.erase(registryKey);
}

static void RejectHttpDynamicWaiters(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                     const std::string& registryKey, v8::Local<v8::Value> reason) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  auto waitIt = httpDynamicWaiters.find(registryKey);
  if (waitIt != httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(waitIt->second);
    httpDynamicWaiters.erase(waitIt);
    RejectResolversWithReason(isolate, context, resolvers, reason);
  }

  moduleState->modulesInFlight.erase(registryKey);
}

static void RejectResolversForInvalidation(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    std::vector<v8::Global<v8::Promise::Resolver>>& resolvers, const std::string& registryKey) {
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
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  moduleState->modulesInFlight.erase(registryKey);

  auto dynamicWaitIt = httpDynamicWaiters.find(registryKey);
  if (dynamicWaitIt != httpDynamicWaiters.end()) {
    std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
    resolvers.swap(dynamicWaitIt->second);
    httpDynamicWaiters.erase(dynamicWaitIt);
    RejectResolversForInvalidation(isolate, context, resolvers, registryKey);
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][invalidate-state] cleared in-flight state for %s", registryKey.c_str());
  }
}

// Bulk await state + callbacks (non-capturing for V8 function compatibility)
struct BulkWaitState {
  size_t remaining;
  bool rejected;
  v8::Global<v8::Promise::Resolver> master;
};

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

namespace {}  // namespace

// Compile a `.json` file as a synthetic ES module whose default export is
// the parsed JSON value. Handles registry insertion, eager evaluation, and
// the dual debug-vs-release error reporting that the rest of
// `ResolveModuleCallback` uses.
//
// Behaviour-preserving extraction from the inline `.json` branch in
// `ResolveModuleCallback` — keeps the calling site small enough to read
// the resolver's main flow without scrolling past 70 lines of JSON-only
// concerns.
static v8::MaybeLocal<v8::Module> CompileJsonAsEsModule(v8::Isolate* isolate,
                                                        v8::Local<v8::Context> context,
                                                        const std::string& absPath,
                                                        const std::string& registryAbsPath,
                                                        bool isWorker) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto& registry = moduleState->registry;

  // JSON modules are compiled eagerly to kEvaluated, so a registered entry is
  // complete and must be reused — recompiling would mint a second module
  // identity (and namespace) for the same file on every resolve.
  auto existingIt = registry.find(registryAbsPath);
  if (existingIt != registry.end()) {
    v8::Local<v8::Module> existing = existingIt->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() == v8::Module::kEvaluated) {
      return v8::MaybeLocal<v8::Module>(existing);
    }
    registry.erase(existingIt);
  }

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
    isolate->ThrowException(v8::Exception::Error(
        tns::ToV8String(isolate, "Failed to create URL string for JSON module")));
    return v8::MaybeLocal<v8::Module>();
  }

  v8::ScriptOrigin origin(urlString, 0, 0, false, -1, v8::Local<v8::Value>(), false, false,
                          true /* is_module */);

  v8::ScriptCompiler::Source src(sourceText, origin);

  v8::Local<v8::Module> jsonModule;
  if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&jsonModule)) {
    isolate->ThrowException(
        v8::Exception::SyntaxError(tns::ToV8String(isolate, "Failed to compile JSON module")));
    return v8::MaybeLocal<v8::Module>();
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
  auto it = registry.find(registryAbsPath);
  if (it != registry.end()) {
    // Clear the existing Global handle before replacing it
    it->second.Reset();
  }
  registry[registryAbsPath].Reset(isolate, jsonModule);
  IndexRegisteredModule(*moduleState, registryAbsPath, jsonModule);
  return v8::MaybeLocal<v8::Module>(jsonModule);
}

// Callback invoked by V8 to resolve `import X from 'specifier';`
v8::MaybeLocal<v8::Module> ResolveModuleCallback(v8::Local<v8::Context> context,
                                                 v8::Local<v8::String> specifier,
                                                 v8::Local<v8::FixedArray> import_assertions,
                                                 v8::Local<v8::Module> referrer) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto& registry = moduleState->registry;

  // 1) Turn the specifier literal into a std::string:
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const std::string rawSpec = *specUtf8 ? *specUtf8 : "";
  if (rawSpec.empty()) {
    return v8::MaybeLocal<v8::Module>();
  }

  // Builtin modules resolve before any path handling. Unshimmed "node:" names
  // fall through to the legacy node:url polyfill below.
  if (NsBuiltinModules::IsRegistered(rawSpec) || NsBuiltinModules::IsNsScheme(rawSpec)) {
    v8::Local<v8::Module> builtin;
    if (NsBuiltinModules::GetModule(context, rawSpec).ToLocal(&builtin)) {
      return v8::MaybeLocal<v8::Module>(builtin);
    }
    if (!NsBuiltinModules::IsRegistered(rawSpec)) {
      isolate->ThrowException(v8::Exception::Error(
          tns::ToV8String(isolate, NsBuiltinModules::NotFoundMessage(rawSpec))));
    }
    return v8::MaybeLocal<v8::Module>();
  }

  std::string normalizedSpec = rawSpec;

  // Normalize malformed HTTP(S) schemes that sometimes appear as 'http:/host' (single slash)
  // due to upstream path joins or standardization. This ensures our HTTP loader fast-path
  // is used and avoids filesystem fallback attempts like '/app/http:/host'.
  if (normalizedSpec.rfind("http:/", 0) == 0 && normalizedSpec.rfind("http://", 0) != 0) {
    normalizedSpec.insert(5, "/");  // http:/ -> http://
  } else if (normalizedSpec.rfind("https:/", 0) == 0 && normalizedSpec.rfind("https://", 0) != 0) {
    normalizedSpec.insert(6, "/");  // https:/ -> https://
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver][spec] %s", normalizedSpec.c_str());
  }

  // Guard against a bare '@' spec showing up (invalid); return empty to avoid poisoning registry
  // with '@'
  if (normalizedSpec == "@") {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][normalize] ignoring invalid '@' static spec");
    }
    return v8::MaybeLocal<v8::Module>();
  }

  const std::string& spec =
      normalizedSpec;  // use normalized spec for the rest of the resolution logic

  // Import map resolution
  // If the import map is populated (set by ns:module configureLoader), check it
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
          Log(@"[resolver][import-map] normalized: %s -> %s -> %s", spec.c_str(),
              normalized.c_str(), mapped.c_str());
        }
      }
    }

    if (!mapped.empty()) {
      // Mapped to an HTTP URL or other specifier — update spec and fall
      // through to existing resolution (HTTP fast path will pick it up)
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
            spec.c_str(), (unsigned long)g_importMap.size(), g_importMap.empty() ? 1 : 0);
      }
    }
  } else if (IsScriptLoadingLogEnabled()) {
    // Map was completely empty — distinct from "map populated but no entry".
    // This branch firing means `SetImportMap("")` was called or the map
    // was never populated at all. Either is a bug; surface it.
    bool looksBare = !spec.empty() && spec[0] != '/' && spec[0] != '.' &&
                     spec.find("://") == std::string::npos && spec.find('\\') == std::string::npos;
    if (looksBare) {
      Log(@"[resolver][import-map][empty] bare='%s' — g_importMap is EMPTY (was it ever "
          @"configured? expected ~200-500 entries)",
          spec.c_str());
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
  std::string referrerPath = FindKeyForModule(*moduleState, isolate, referrer);
  // If we couldn't identify the referrer (e.g. coming from a dynamic import
  // where the embedder did not pass the compiled Module), we can still proceed
  // for absolute and application-rooted specifiers. A clearly relative
  // specifier ("./" or "../") needs the referrer's directory; without one,
  // resolve against the application root — every registered module is in the
  // identity-hash index, so hitting this means the referrer was never
  // registered.
  bool specIsRelative = !spec.empty() && spec[0] == '.';
  size_t slash = referrerPath.find_last_of("/\\");
  std::string baseDir = slash == std::string::npos ? "" : referrerPath.substr(0, slash + 1);
  if (referrerPath.empty() && specIsRelative) {
    Log(@"[resolver] no registered referrer for relative import '%s'; resolving against app root",
        spec.c_str());
    baseDir = RuntimeConfig.ApplicationPath + "/";
  }

  // If the referrer itself was compiled from an HTTP(S) URL, then any relative
  // ("./" or "../") or root-absolute ("/") specifiers should resolve against the
  // referrer's URL, not the local filesystem. Mirror browser behavior by using NSURL
  // to construct the absolute URL, then return an HTTP-loaded module immediately.
  // Security: HttpFetchText gates remote module access centrally.
  bool referrerIsHttp = (!referrerPath.empty() && (StartsWith(referrerPath, "http://") ||
                                                   StartsWith(referrerPath, "https://")));
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
    if (!resolvedHttp.empty() &&
        (StartsWith(resolvedHttp, "http://") || StartsWith(resolvedHttp, "https://"))) {
      // Security: HttpFetchText gates remote module access centrally.
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][http-rel] base=%s spec=%s -> %s", referrerPath.c_str(), spec.c_str(),
            resolvedHttp.c_str());
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
            Log(@"[resolver][normalize-rel] %s + %s -> %s", baseDir.c_str(), cleanSpec.c_str(),
                candidate.c_str());
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
      Log(@"[resolver][tilde] spec=%s base=%s appBase=%s", spec.c_str(), base.c_str(),
          baseApp.c_str());
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
      std::string tailNoApp = spec.substr(appPrefix.size() - 1);  // keep leading '/'
      // spec starts with '/app/...', so tailNoApp becomes '/...'
      std::string baseNoApp = NormalizePath(RuntimeConfig.ApplicationPath + tailNoApp);
      if (baseNoApp != base) {
        candidateBases.push_back(baseNoApp);
      }
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][abs] spec=%s base=%s baseNoApp=%s", spec.c_str(), base.c_str(),
            baseNoApp.c_str());
      }
    } else if (IsScriptLoadingLogEnabled()) {
      Log(@"[resolver][abs] spec=%s base=%s", spec.c_str(), base.c_str());
    }
  } else {
    // Bare specifier – resolve relative to the application root directory
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + "/" + spec);
    candidateBases.push_back(base);
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
      std::string tail = p.substr(pos + 1);  // 'http:/...' or 'https:/...'
      if (StartsWith(tail, "http:/") && !StartsWith(tail, "http://")) {
        tail.insert(5, "/");
      } else if (StartsWith(tail, "https:/") && !StartsWith(tail, "https://")) {
        tail.insert(6, "/");
      }
      if (!(StartsWith(tail, "http://") || StartsWith(tail, "https://"))) return false;

      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver][http-embedded] %s -> %s", p.c_str(), tail.c_str());
      }
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

      auto itExisting = registry.find(key);
      if (itExisting != registry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
          return v8::MaybeLocal<v8::Module>(existing);
        }
        RemoveModuleFromRegistry(isolate, key);
      }

      std::string polyfillContent;
      if (builtinName == "url") {
        // Polyfill for node:url with fileURLToPath/pathToFileURL
        polyfillContent = "// In-memory polyfill for node:url\n"
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
        isolate->ThrowException(v8::Exception::Error(
            tns::ToV8String(isolate, NsBuiltinModules::NotFoundMessage(spec))));
        return v8::MaybeLocal<v8::Module>();
      }

      v8::MaybeLocal<v8::Module> m =
          CompileModuleForResolveRegisterOnly(isolate, context, polyfillContent, key);
      if (!m.IsEmpty()) {
        v8::Local<v8::Module> mod;
        if (m.ToLocal(&mod)) {
          return m;
        }
      }

      std::string msg = "Cannot find module '" + spec + "' (failed to create in-memory polyfill)";
      isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
      return v8::MaybeLocal<v8::Module>();
    } else {
      std::string msg = "Cannot find module '" + spec + "' (tried " + absPath + ")";
      isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
      return v8::MaybeLocal<v8::Module>();
    }
  }

  // Special handling for JSON imports (e.g. import data from './foo.json' assert {type:'json'})
  if (absPath.size() >= 5 && absPath.compare(absPath.size() - 5, 5, ".json") == 0) {
    return CompileJsonAsEsModule(isolate, context, absPath, registryAbsPath, cache->isWorker);
  }

  // 5) Reuse any live, non-errored registry entry. The resolver never
  // evaluates, so an unfinished entry (kUninstantiated / kInstantiating /
  // kEvaluating) simply rejoins the graph V8 is currently linking — that is
  // how import cycles terminate, the same way Node/Blink break them with the
  // module-map self-insert.
  auto it = registry.find(registryAbsPath);
  if (it != registry.end()) {
    v8::Local<v8::Module> existing = it->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[resolver] cache hit %s (status=%s)", absPath.c_str(),
            ModuleStatusToString(existing->GetStatus()));
      }
      return v8::MaybeLocal<v8::Module>(existing);
    }
    RemoveModuleFromRegistry(isolate, absPath);
  }

  // 6) Compile + register only — never instantiate or evaluate here. V8 is
  // instantiating the importer and continues the graph walk by resolving this
  // module's own requests next; evaluating inside the resolver would run
  // dependencies in resolver order instead of the spec's evaluation order.
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[resolver] → compile-register %s", absPath.c_str());
  }
  try {
    v8::Local<v8::Module> mod;
    if (!tns::ModuleInternal::CompileFileEsModule(isolate, absPath).ToLocal(&mod)) {
      // The compile exception is pending on the isolate; V8 fails the
      // importer's instantiation with it.
      return v8::MaybeLocal<v8::Module>();
    }
    registry[registryAbsPath].Reset(isolate, mod);
    IndexRegisteredModule(*moduleState, registryAbsPath, mod);
    return v8::MaybeLocal<v8::Module>(mod);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    return v8::MaybeLocal<v8::Module>();
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Completion tail for an HTTP dynamic import whose graph was loaded by the
// async pipeline (or that needs the legacy in-line load as a fallback).
// Assumes the caller has already marked `key` in-flight and queued at least
// one waiter in httpDynamicWaiters — every exit path below settles those
// waiters. `requestUrl` is the normalized (pre-canonicalization) request.
//
// When the phase-1 walk succeeded, LoadHttpModuleForUrl is a registry hit
// and InstantiateModule's resolver runs as a pure lookup; any URL the walk
// missed degrades to the legacy synchronous fetch inside the resolver.
static void FinishHttpDynamicImport(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                    const std::string& key, const std::string& requestUrl) {
  if (IsScriptLoadingLogEnabled()) {
    auto* moduleState = ModuleLoaderStateFor(isolate);
    if (moduleState != nullptr && moduleState->registry.find(key) == moduleState->registry.end()) {
      // The async walk was expected to have registered the root; falling
      // back to the synchronous loader here means the walk missed it.
      Log(@"[async-graph][fallback-sync-load] root missed walk: %s", key.c_str());
    }
  }
  v8::MaybeLocal<v8::Module> modMaybe = LoadHttpModuleForUrl(isolate, context, requestUrl);
  if (!modMaybe.IsEmpty()) {
    v8::Local<v8::Module> mod;
    if (modMaybe.ToLocal(&mod)) {
      if (mod->GetStatus() == v8::Module::kUninstantiated) {
        v8::TryCatch tcInstantiate(isolate);
        if (!mod->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
          RemoveModuleFromRegistry(isolate, key);
          RejectHttpDynamicWaiters(
              isolate, context, key,
              BuildModuleFailureReason(isolate, tcInstantiate, "Instantiation failed (http-loader)",
                                       requestUrl));
          return;
        }
      }

      if (IsModuleEvaluationInProgress(mod->GetStatus())) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][http-loader] waiting on existing evaluation for %s status=%s",
              key.c_str(), ModuleStatusToString(mod->GetStatus()));
        }
        return;
      }

      // Evaluate once compiled so that namespace is valid for dynamic import resolution
      if (mod->GetStatus() != v8::Module::kEvaluated) {
        v8::Local<v8::Value> evalResult;
        {
          v8::TryCatch tcEvaluate(isolate);
          if (!mod->Evaluate(context).ToLocal(&evalResult)) {
            // Remove broken registration and reject
            RemoveModuleFromRegistry(isolate, key);
            RejectHttpDynamicWaiters(
                isolate, context, key,
                BuildModuleFailureReason(isolate, tcEvaluate, "Evaluation failed (http-loader)",
                                         requestUrl));
            return;
          }
        }
        // If Evaluate returned a Promise (top-level await), wait until it settles before
        // resolving
        if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
          v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
          struct EvalWaitData2 {
            std::string key;
            v8::Global<v8::Context> ctx;
            v8::Global<v8::Module> mod;
          };
          auto* data2 = new EvalWaitData2{key, v8::Global<v8::Context>(isolate, context),
                                          v8::Global<v8::Module>(isolate, mod)};
          auto onFulfilled2 = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
            v8::Isolate* iso = info.GetIsolate();
            v8::HandleScope hs(iso);
            if (!info.Data()->IsExternal()) return;
            auto* d = static_cast<EvalWaitData2*>(
                info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
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
            auto* d = static_cast<EvalWaitData2*>(
                info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
            v8::Local<v8::Context> ctx = d->ctx.Get(iso);
            std::string keyLocal = d->key;
            v8::Local<v8::Value> reason = (info.Length() > 0)
                                              ? info[0]
                                              : v8::Exception::Error(tns::ToV8String(
                                                    iso, "Evaluation failed (http-loader TLA)"));
            if (IsScriptLoadingLogEnabled()) {
              v8::String::Utf8Value r(iso, reason);
              if (*r) {
                Log(@"[dyn-import][http-loader][tla] rejected: %s", *r);
              }
            }
            RejectHttpDynamicWaiters(iso, ctx, keyLocal, reason);
            delete d;
          };
          v8::Local<v8::FunctionTemplate> thenFulfillTpl2 = v8::FunctionTemplate::New(
              isolate, onFulfilled2,
              v8::External::New(isolate, data2, v8::kExternalPointerTypeTagDefault));
          v8::Local<v8::Function> thenFulfill2 =
              thenFulfillTpl2->GetFunction(context).ToLocalChecked();
          v8::Local<v8::FunctionTemplate> thenRejectTpl2 = v8::FunctionTemplate::New(
              isolate, onRejected2,
              v8::External::New(isolate, data2, v8::kExternalPointerTypeTagDefault));
          v8::Local<v8::Function> thenReject2 =
              thenRejectTpl2->GetFunction(context).ToLocalChecked();
          p->Then(context, thenFulfill2, thenReject2).ToLocalChecked();
          return;
        }
      }
      ResolveHttpDynamicWaiters(isolate, context, key, mod);
      return;
    }
  }
  // On fetch/compile miss: clean inflight and reject queued
  RejectHttpDynamicWaiters(
      isolate, context, key,
      v8::Exception::Error(tns::ToV8String(isolate, "HTTP fetch/compile failed")));
}

// ────────────────────────────────────────────────────────────────────────────
// Dynamic import() host callback
v8::MaybeLocal<v8::Promise> ImportModuleDynamicallyCallback(
    v8::Local<v8::Context> context, v8::Local<v8::Data> host_defined_options,
    v8::Local<v8::Value> resource_name, v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Promise>();
  }
  auto& registry = moduleState->registry;
  auto& modulesInFlight = moduleState->modulesInFlight;
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  // Diagnostic: log every dynamic import attempt.
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const char* cSpec = (*specUtf8) ? *specUtf8 : "<invalid>";
  NSString* specStr = [NSString stringWithUTF8String:cSpec];
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dyn-import] → %@", specStr);
    // Also log the referrer resource when available to correlate origin of dynamic imports
    v8::Local<v8::Value> resName = resource_name;
    if (!resName.IsEmpty() && resName->IsString()) {
      v8::String::Utf8Value rn(isolate, resName);
      if (*rn) {
        Log(@"[dyn-import][referrer] %s", *rn);
      }
    }
  }
  // Normalize spec: only strip ?query/hash for non-HTTP specs so SFC HTTP keys keep
  // version tags
  std::string rawSpec = cSpec ? std::string(cSpec) : std::string();

  // Builtin modules never reach the loader below; the namespace comes straight
  // from the realm's synthetic module.
  if (NsBuiltinModules::IsRegistered(rawSpec) || NsBuiltinModules::IsNsScheme(rawSpec)) {
    v8::EscapableHandleScope builtinScope(isolate);
    v8::Local<v8::Promise::Resolver> builtinResolver;
    if (!v8::Promise::Resolver::New(context).ToLocal(&builtinResolver)) {
      return v8::MaybeLocal<v8::Promise>();
    }
    v8::TryCatch tc(isolate);
    v8::Local<v8::Module> builtin;
    if (NsBuiltinModules::GetModule(context, rawSpec).ToLocal(&builtin)) {
      builtinResolver->Resolve(context, builtin->GetModuleNamespace()).FromMaybe(false);
    } else {
      v8::Local<v8::Value> error = tc.HasCaught()
                                       ? tc.Exception()
                                       : v8::Exception::Error(tns::ToV8String(
                                             isolate, NsBuiltinModules::NotFoundMessage(rawSpec)));
      // Reject must not run with the exception still pending on the isolate.
      tc.Reset();
      builtinResolver->Reject(context, error).FromMaybe(false);
    }
    return builtinScope.Escape(builtinResolver->GetPromise());
  }

  std::string normalizedSpec = rawSpec;
  // remove query/hash ONLY for non-HTTP specs
  bool isHttpLike = (!normalizedSpec.empty() && (StartsWith(normalizedSpec, "http://") ||
                                                 StartsWith(normalizedSpec, "https://")));
  if (!isHttpLike) {
    size_t qpos = normalizedSpec.find_first_of("?#");
    if (qpos != std::string::npos) {
      normalizedSpec = normalizedSpec.substr(0, qpos);
    }
  }
  if (normalizedSpec != rawSpec) {
    // Rebuild V8 string only if changed
    specifier = tns::ToV8String(isolate, normalizedSpec.c_str());
    specStr = [NSString stringWithUTF8String:normalizedSpec.c_str()];
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[dyn-import][normalize] %@ -> %@", [NSString stringWithUTF8String:rawSpec.c_str()],
          specStr);
    }
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
          Log(@"[dyn-import][import-map] normalized: %s -> %s -> %s", normalizedSpec.c_str(),
              normalized.c_str(), mapped.c_str());
        }
      }
    }
    if (!mapped.empty()) {
      // Mapped to an HTTP URL or other specifier
      normalizedSpec = mapped;
      specifier = tns::ToV8String(isolate, normalizedSpec.c_str());
      specStr = [NSString stringWithUTF8String:normalizedSpec.c_str()];
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import][import-map] rewrite: %s -> %s", rawSpec.c_str(), normalizedSpec.c_str());
      }
    }
  }

  // Re-use the static resolver to locate / compile the module.
  try {
    // Defensive guard: some dev-time toolchains may emit a stray import('@') during bootstrap.
    // Treat it as a no-op module to avoid surfacing a hard failure while continuing with real
    // imports.
    if (!normalizedSpec.empty() && normalizedSpec == "@") {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import] ignoring invalid '@' spec (returning empty module)");
      }
      const char* kEmptySrc = "export {}\n";
      std::string url = "file:///app/__invalid_at__.mjs";
      v8::MaybeLocal<v8::Module> modMaybe =
          CompileModuleFromSource(isolate, context, kEmptySrc, url);
      v8::Local<v8::Module> mod;
      if (modMaybe.ToLocal(&mod)) {
        const std::string atStubKey = CanonicalizeRegistryKey(url);
        registry[atStubKey].Reset(isolate, mod);
        IndexRegisteredModule(*moduleState, atStubKey, mod);
        if (mod->GetStatus() != v8::Module::kEvaluated) {
          if (mod->Evaluate(context).IsEmpty()) {
            resolver
                ->Reject(context, v8::Exception::Error(tns::ToV8String(
                                      isolate, "Evaluation failed for empty module")))
                .FromMaybe(false);
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

      auto existingIt = registry.find(blobRegistryKey);
      if (existingIt != registry.end()) {
        v8::Local<v8::Module> existing = existingIt->second.Get(isolate);
        if (!existing.IsEmpty()) {
          v8::Module::Status existingStatus = existing->GetStatus();
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][blob-cache] hit %s status=%s", blobRegistryKey.c_str(),
                ModuleStatusToString(existingStatus));
          }

          if (existingStatus == v8::Module::kErrored) {
            RemoveModuleFromRegistry(isolate, blobRegistryKey);
          } else if (IsModuleEvaluationInProgress(existingStatus)) {
            modulesInFlight.insert(blobRegistryKey);
            httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);
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
          RemoveModuleFromRegistry(isolate, blobRegistryKey);
        }
      }

      if (modulesInFlight.find(blobRegistryKey) != modulesInFlight.end()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] coalesce in-flight %s", blobRegistryKey.c_str());
        }
        httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);
        return scope.Escape(resolver->GetPromise());
      }

      modulesInFlight.insert(blobRegistryKey);
      httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);

      // Call URL.InternalAccessor.getData(url) to retrieve the blob data
      v8::TryCatch tc(isolate);
      v8::Local<v8::Object> globalObj = context->Global();

      // Get URL constructor
      v8::Local<v8::Value> urlCtorVal;
      if (!globalObj->Get(context, tns::ToV8String(isolate, "URL")).ToLocal(&urlCtorVal) ||
          !urlCtorVal->IsFunction()) {
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
      if (!urlCtor->Get(context, tns::ToV8String(isolate, "InternalAccessor"))
               .ToLocal(&internalAccessorVal) ||
          !internalAccessorVal->IsObject()) {
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
      if (!internalAccessor->Get(context, tns::ToV8String(isolate, "getData"))
               .ToLocal(&getDataVal) ||
          !getDataVal->IsFunction()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] URL.InternalAccessor.getData not found");
        }
        RejectHttpDynamicWaiters(isolate, context, blobRegistryKey,
                                 v8::Exception::Error(tns::ToV8String(
                                     isolate, "URL.InternalAccessor.getData not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Function> getDataFn = getDataVal.As<v8::Function>();

      // Call getData(url)
      v8::Local<v8::Value> urlArg = tns::ToV8String(isolate, normalizedSpec.c_str());
      v8::Local<v8::Value> blobDataVal;
      if (!getDataFn->Call(context, internalAccessor, 1, &urlArg).ToLocal(&blobDataVal) ||
          blobDataVal->IsNullOrUndefined()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] blob not found in BLOB_STORE: %s", normalizedSpec.c_str());
        }
        std::string msg = "Blob not found: " + normalizedSpec;
        RejectHttpDynamicWaiters(isolate, context, blobRegistryKey,
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
      if (!blobData->Get(context, tns::ToV8String(isolate, "blob")).ToLocal(&blobVal) ||
          !blobVal->IsObject()) {
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
      if (!blobObj->Get(context, tns::ToV8String(isolate, "text")).ToLocal(&textFnVal) ||
          !textFnVal->IsFunction()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] Blob.text() not available");
        }
        RejectHttpDynamicWaiters(
            isolate, context, blobRegistryKey,
            v8::Exception::Error(tns::ToV8String(isolate, "Blob.text() not available")));
        return scope.Escape(resolver->GetPromise());
      }
      v8::Local<v8::Function> textFn = textFnVal.As<v8::Function>();

      // Keep the two failure modes distinct — a throw out of text() and a
      // return value that isn't awaitable — and carry the thrown value's text
      // into the rejection. Collapsing both into one opaque message loses the
      // only evidence of why a blob module would not load.
      v8::Local<v8::Value> textResultVal;
      std::string textFailure;
      {
        v8::TryCatch textTc(isolate);
        if (!textFn->Call(context, blobObj, 0, nullptr).ToLocal(&textResultVal)) {
          textFailure = "Blob.text() threw";
          if (textTc.HasCaught()) {
            v8::String::Utf8Value thrown(isolate, textTc.Exception());
            if (*thrown) {
              textFailure += std::string(": ") + *thrown;
            }
          }
        }
      }

      v8::Local<v8::Promise> textPromise;
      if (textFailure.empty() &&
          !AdoptThenable(isolate, context, textResultVal).ToLocal(&textPromise)) {
        textFailure = "Blob.text() did not return a thenable";
      }
      if (!textFailure.empty()) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][blob] %s", textFailure.c_str());
        }
        RejectHttpDynamicWaiters(isolate, context, blobRegistryKey,
                                 v8::Exception::Error(tns::ToV8String(isolate, textFailure)));
        return scope.Escape(resolver->GetPromise());
      }

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
        auto* d = static_cast<BlobImportData*>(
            info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
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
          RemoveModuleFromRegistry(iso, d->registryKey);
          RejectHttpDynamicWaiters(
              iso, ctx, d->registryKey,
              v8::Exception::Error(tns::ToV8String(iso, "Failed to instantiate blob module")));
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
            RemoveModuleFromRegistry(iso, d->registryKey);
            RejectHttpDynamicWaiters(
                iso, ctx, d->registryKey,
                v8::Exception::Error(tns::ToV8String(iso, "Failed to evaluate blob module")));
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
              auto* d = static_cast<BlobEvalData*>(
                  info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
              v8::Local<v8::Context> ctx = d->ctx.Get(iso);
              v8::Local<v8::Module> mod = d->mod.Get(iso);
              ResolveHttpDynamicWaiters(iso, ctx, d->registryKey, mod);
              delete d;
            };

            auto onEvalRejected = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
              v8::Isolate* iso = info.GetIsolate();
              v8::HandleScope hs(iso);
              if (!info.Data()->IsExternal()) return;
              auto* d = static_cast<BlobEvalData*>(
                  info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
              v8::Local<v8::Context> ctx = d->ctx.Get(iso);
              v8::Local<v8::Value> reason =
                  info.Length() > 0
                      ? info[0]
                      : v8::Exception::Error(tns::ToV8String(iso, "Blob module evaluation failed"));
              RemoveModuleFromRegistry(iso, d->registryKey);
              RejectHttpDynamicWaiters(iso, ctx, d->registryKey, reason);
              delete d;
            };

            v8::Local<v8::Promise> evalPromise = evalResult.As<v8::Promise>();
            v8::Local<v8::Function> onEvalFulfilledFn =
                v8::Function::New(
                    ctx, onEvalFulfilled,
                    v8::External::New(iso, evalData, v8::kExternalPointerTypeTagDefault))
                    .ToLocalChecked();
            v8::Local<v8::Function> onEvalRejectedFn =
                v8::Function::New(
                    ctx, onEvalRejected,
                    v8::External::New(iso, evalData, v8::kExternalPointerTypeTagDefault))
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
        auto* d = static_cast<BlobImportData*>(
            info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
        v8::Local<v8::Context> ctx = d->ctx.Get(iso);
        v8::Local<v8::Value> reason =
            info.Length() > 0 ? info[0]
                              : v8::Exception::Error(tns::ToV8String(iso, "Blob text() failed"));
        RejectHttpDynamicWaiters(iso, ctx, d->registryKey, reason);
        delete d;
      };

      v8::Local<v8::Function> onFulfilledFn =
          v8::Function::New(context, onFulfilled,
                            v8::External::New(isolate, data, v8::kExternalPointerTypeTagDefault))
              .ToLocalChecked();
      v8::Local<v8::Function> onRejectedFn =
          v8::Function::New(context, onRejected,
                            v8::External::New(isolate, data, v8::kExternalPointerTypeTagDefault))
              .ToLocalChecked();

      textPromise->Then(context, onFulfilledFn, onRejectedFn).FromMaybe(v8::Local<v8::Promise>());

      return scope.Escape(resolver->GetPromise());
    }

    // If spec is an HTTP(S) URL, try HTTP fetch+compile directly
    // Security: HttpFetchText gates remote module access centrally.
    if (!normalizedSpec.empty() &&
        (StartsWith(normalizedSpec, "http://") || StartsWith(normalizedSpec, "https://"))) {
      if (IsScriptLoadingLogEnabled()) {
        Log(@"[dyn-import][http-loader] trying URL %s", normalizedSpec.c_str());
      }
      std::string key = CanonicalizeHttpUrlKey(normalizedSpec);
      // Volatile pattern check: if the URL matches any configured volatile
      // pattern, evict the cached module so we always re-fetch. The pattern
      // list is policy and is supplied exclusively by the dev client via
      // ns:module `configureLoader({ volatilePatterns })` — the runtime
      // carries no framework or server URL vocabulary of its own. (Framework
      // strategies ship their own endpoints, e.g. Angular's `/@ng/component`
      // whose per-save `t` param would otherwise accumulate one stale
      // registry entry per save.)
      bool isVolatile = IsVolatileUrl(normalizedSpec);
      if (isVolatile) {
        auto ex = registry.find(key);
        if (ex != registry.end()) {
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][http-cache] drop volatile %s", key.c_str());
          }
          RemoveModuleFromRegistry(isolate, key);
        }
      }
      // Coalesce concurrent dynamic imports for the same HTTP key
      auto inflight = modulesInFlight.find(key) != modulesInFlight.end();
      if (inflight) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][http] coalesce in-flight %s", key.c_str());
        }
        httpDynamicWaiters[key].emplace_back(isolate, resolver);
        return scope.Escape(resolver->GetPromise());
      }
      // If module was already compiled, resolve immediately
      auto itExisting = registry.find(key);
      if (itExisting != registry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty()) {
          // Permanent observability: surface every HTTP dynamic-import
          // cache hit so we can verify the runtime *did* drop the entry
          // on invalidate. Filtered to angular component-shaped URLs to
          // avoid spam from vendor chunks. Verbose-gated.
          if (IsScriptLoadingLogEnabled()) {
            if (key.find("ns/m/") != std::string::npos ||
                key.find(".component") != std::string::npos) {
              Log(@"[ns-hmr][ios-dyn-cache] HIT %s status=%s", key.c_str(),
                  ModuleStatusToString(existing->GetStatus()));
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
            RemoveModuleFromRegistry(isolate, key);
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
              modulesInFlight.insert(key);
              if (IsScriptLoadingLogEnabled()) {
                Log(@"[dyn-import][http-cache] awaiting evaluation %s", key.c_str());
              }
              httpDynamicWaiters[key].emplace_back(isolate, resolver);
              if (st == v8::Module::kUninstantiated) {
                v8::TryCatch tcInstantiate(isolate);
                if (!existing->InstantiateModule(context, &ResolveModuleCallback)
                         .FromMaybe(false)) {
                  RemoveModuleFromRegistry(isolate, key);
                  RejectHttpDynamicWaiters(
                      isolate, context, key,
                      BuildModuleFailureReason(isolate, tcInstantiate,
                                               "Instantiation failed (http-cache hit)", key));
                  return scope.Escape(resolver->GetPromise());
                }
              }

              if (IsModuleEvaluationInProgress(existing->GetStatus())) {
                return scope.Escape(resolver->GetPromise());
              }

              // Trigger evaluation. If TLA returns a Promise, attach then-handlers to resolve
              // waiters upon settle.
              v8::Local<v8::Value> evalResult;
              {
                v8::TryCatch tcEvaluate(isolate);
                if (!existing->Evaluate(context).ToLocal(&evalResult)) {
                  // Failed evaluation: reject all waiters and drop entry
                  RemoveModuleFromRegistry(isolate, key);
                  RejectHttpDynamicWaiters(
                      isolate, context, key,
                      BuildModuleFailureReason(isolate, tcEvaluate,
                                               "Evaluation failed (http-cache hit)", key));
                  return scope.Escape(resolver->GetPromise());
                }
              }
              // If Evaluate returned a Promise (top-level await), wait until it settles before
              // resolving waiters.
              if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
                v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
                struct EvalWaitData {
                  std::string key;
                  v8::Global<v8::Context> ctx;
                  v8::Global<v8::Module> mod;
                };
                auto* data = new EvalWaitData{key, v8::Global<v8::Context>(isolate, context),
                                              v8::Global<v8::Module>(isolate, existing)};
                auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
                  v8::Isolate* iso = info.GetIsolate();
                  v8::HandleScope hs(iso);
                  if (!info.Data()->IsExternal()) return;
                  auto* d = static_cast<EvalWaitData*>(
                      info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
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
                  auto* d = static_cast<EvalWaitData*>(
                      info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
                  v8::Local<v8::Context> ctx = d->ctx.Get(iso);
                  std::string keyLocal = d->key;
                  v8::Local<v8::Value> reason =
                      (info.Length() > 0) ? info[0]
                                          : v8::Exception::Error(tns::ToV8String(
                                                iso, "Evaluation failed (http-cache TLA)"));
                  if (IsScriptLoadingLogEnabled()) {
                    v8::String::Utf8Value r(iso, reason);
                    if (*r) {
                      Log(@"[dyn-import][http-cache][tla] rejected: %s", *r);
                    }
                  }
                  RejectHttpDynamicWaiters(iso, ctx, keyLocal, reason);
                  delete d;
                };
                v8::Local<v8::FunctionTemplate> thenFulfillTpl = v8::FunctionTemplate::New(
                    isolate, onFulfilled,
                    v8::External::New(isolate, data, v8::kExternalPointerTypeTagDefault));
                v8::Local<v8::Function> thenFulfill =
                    thenFulfillTpl->GetFunction(context).ToLocalChecked();
                v8::Local<v8::FunctionTemplate> thenRejectTpl = v8::FunctionTemplate::New(
                    isolate, onRejected,
                    v8::External::New(isolate, data, v8::kExternalPointerTypeTagDefault));
                v8::Local<v8::Function> thenReject =
                    thenRejectTpl->GetFunction(context).ToLocalChecked();
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
      // mark in-flight before starting the async graph load
      modulesInFlight.insert(key);
      httpDynamicWaiters[key].emplace_back(isolate, resolver);
      // Permanent observability: surface fresh fetches so we can confirm
      // that post-invalidation, the next dynamic import does NOT re-use
      // the cache and DOES go to the network. Filtered to component
      // shapes to avoid vendor-chunk noise. Verbose-gated.
      if (IsScriptLoadingLogEnabled() &&
          (key.find("ns/m/") != std::string::npos || key.find(".component") != std::string::npos)) {
        Log(@"[ns-hmr][ios-dyn-cache] FRESH-FETCH %s", key.c_str());
      }
      // Async pipeline: fetch + compile the transitive closure off the JS
      // thread's critical path, then instantiate/evaluate and settle the
      // queued waiters from the walk's completion. The promise returns to JS
      // immediately — no synchronous fetch, no runloop pump.
      const std::string requestUrl = normalizedSpec;
      StartAsyncHttpModuleGraphLoad(
          isolate, context, requestUrl,
          [key, requestUrl, isolate](bool ok, const std::string& errorMessage,
                                     v8::Local<v8::Context> completionContext) {
            // JS thread; isolate entered and context scoped by the pipeline.
            v8::Isolate* iso = isolate;
            if (!ok) {
              RejectHttpDynamicWaiters(
                  iso, completionContext, key,
                  v8::Exception::Error(tns::ToV8String(iso, errorMessage.c_str())));
              return;
            }
            FinishHttpDynamicImport(iso, completionContext, key, requestUrl);
          });
      return scope.Escape(resolver->GetPromise());
    }

    // Attempt to resolve relative specs against the referrer's resource URL if available.
    // This reduces reliance on app-root fallback and ensures ../ segments are collapsed.
    v8::Local<v8::Module> refMod;
    v8::Local<v8::String> adjustedSpecifier = specifier;
    if (!normalizedSpec.empty() &&
        (normalizedSpec.rfind("./", 0) == 0 || normalizedSpec.rfind("../", 0) == 0)) {
      // Try to extract a base directory from resource_name, which is a file:// URL
      v8::Local<v8::Value> resName = resource_name;
      if (!resName.IsEmpty() && resName->IsString()) {
        v8::String::Utf8Value rn(isolate, resName);
        std::string refUrl = *rn ? *rn : std::string();
        if (!refUrl.empty()) {
          std::string refPath = FileURLToPath(refUrl);
          size_t slash = refPath.find_last_of("/\\");
          std::string baseDir =
              slash == std::string::npos ? std::string() : refPath.substr(0, slash + 1);
          if (IsScriptLoadingLogEnabled()) {
            Log(@"[dyn-import][ref] url=%s base=%s spec=%s", refUrl.c_str(), baseDir.c_str(),
                normalizedSpec.c_str());
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
                  Log(@"[dyn-import][normalize-rel] %s + %s -> %s", baseDir.c_str(),
                      normalizedSpec.c_str(), fsPath.c_str());
                }
              }
            }
          }
        }
      } else {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import][ref] missing resource name; cannot normalize relative spec against "
              @"referrer");
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
      Log(@"[dyn-import][resolver-call] raw=%s normalized=%s adjusted=%s", rawSpec.c_str(),
          normalizedSpec.c_str(), cAdj);
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
        resolver->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())))
            .FromMaybe(false);
        return scope.Escape(resolver->GetPromise());
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
        // Include the spec and V8 exception message (when available) for improved diagnostics
        // upstream
        std::string msg =
            std::string("Failed to instantiate module: ") + std::string([specStr UTF8String]);
        if (ictc.HasCaught()) {
          std::string exStr = tns::ToString(isolate, ictc.Exception());
          if (!exStr.empty()) {
            msg.append(" — ");
            msg.append(exStr);
          }
        }
        resolver->Reject(context, v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())))
            .Check();
        return scope.Escape(resolver->GetPromise());
      }
    }

    // A kEvaluating module (TLA in flight, or a cycle re-entry) falls through
    // deliberately: Evaluate() on an already-evaluating module returns its
    // existing top-level capability promise, so the TLA chain below coalesces
    // this import with the in-flight evaluation.
    if (module->GetStatus() != v8::Module::kEvaluated) {
      v8::Local<v8::Value> evalResult;
      if (!module->Evaluate(context).ToLocal(&evalResult)) {
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[dyn-import] ✗ evaluation failed %@", specStr);
        }
        // Include the spec in the error message for improved diagnostics upstream
        std::string msg =
            std::string("Evaluation failed for module: ") + std::string([specStr UTF8String]);
        v8::Local<v8::Value> ex = v8::Exception::Error(tns::ToV8String(isolate, msg.c_str()));
        resolver->Reject(context, ex).Check();
        return scope.Escape(resolver->GetPromise());
      }
      // If top-level await returns a Promise, resolve only after it settles
      if (!evalResult.IsEmpty() && evalResult->IsPromise()) {
        v8::Local<v8::Promise> p = evalResult.As<v8::Promise>();
        struct DynEvalData {
          v8::Global<v8::Context> ctx;
          v8::Global<v8::Module> mod;
          v8::Global<v8::Promise::Resolver> res;
        };
        auto* d = new DynEvalData{v8::Global<v8::Context>(isolate, context),
                                  v8::Global<v8::Module>(isolate, module),
                                  v8::Global<v8::Promise::Resolver>(isolate, resolver)};
        auto onFulfilled = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
          v8::Isolate* iso = info.GetIsolate();
          v8::HandleScope hs(iso);
          if (!info.Data()->IsExternal()) return;
          auto* d = static_cast<DynEvalData*>(
              info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
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
          auto* d = static_cast<DynEvalData*>(
              info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault));
          v8::Local<v8::Context> ctx = d->ctx.Get(iso);
          v8::Local<v8::Promise::Resolver> res = d->res.Get(iso);
          v8::Local<v8::Value> reason =
              (info.Length() > 0)
                  ? info[0]
                  : v8::Exception::Error(tns::ToV8String(iso, "Evaluation failed (TLA)"));
          if (IsScriptLoadingLogEnabled()) {
            v8::String::Utf8Value r(iso, reason);
            if (*r) {
              Log(@"[dyn-import][tla] rejected: %s", *r);
            }
          }
          if (!res.IsEmpty()) res->Reject(ctx, reason).FromMaybe(false);
          delete d;
        };
        v8::Local<v8::FunctionTemplate> fulfillTpl = v8::FunctionTemplate::New(
            isolate, onFulfilled,
            v8::External::New(isolate, d, v8::kExternalPointerTypeTagDefault));
        v8::Local<v8::Function> fulfill = fulfillTpl->GetFunction(context).ToLocalChecked();
        v8::Local<v8::FunctionTemplate> rejectTpl = v8::FunctionTemplate::New(
            isolate, onRejected, v8::External::New(isolate, d, v8::kExternalPointerTypeTagDefault));
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
        resolver
            ->Reject(context, v8::Exception::Error(
                                  tns::ToV8String(isolate, "TDZ on default after eval (generic)")))
            .Check();
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
}  // namespace tns
