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
static v8::MaybeLocal<v8::Module> CompileJsonTextAsEsModule(v8::Isolate* isolate,
                                                            v8::Local<v8::Context> context,
                                                            const std::string& jsonText,
                                                            const std::string& registryKey,
                                                            const std::string& displayUrl);

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

// "message (line L:C)" for a caught exception, or empty. The line/column are
// the part no caller can reconstruct from a failure code.
static std::string DescribeCaughtError(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                       const v8::TryCatch& tc) {
  if (!tc.HasCaught()) {
    return std::string();
  }
  v8::Local<v8::Message> message = tc.Message();
  if (message.IsEmpty()) {
    return std::string();
  }
  v8::String::Utf8Value text(isolate, message->Get());
  std::string described = *text ? *text : "";
  int line = message->GetLineNumber(context).FromMaybe(0);
  if (line > 0) {
    described +=
        " (line " + std::to_string(line) + ":" + std::to_string(message->GetStartColumn()) + ")";
  }
  return described;
}

// Compile-only variant for use inside ResolveModuleCallback. It compiles a v8::Module and
// registers it under urlStr but does NOT instantiate or evaluate. V8 is currently instantiating
// the importer and will handle instantiation of this dependency.
//
// On compile failure the exception is left PENDING, the same contract as
// ModuleInternal::CompileFileEsModule: it names the file, line and column,
// which nothing downstream can reconstruct. A caller that cannot let it
// propagate must consume it through its own TryCatch and route the text into
// its own failure channel — never drop it.
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
  if (tns::LogCategoryEnabled(tns::LogCategory::Esm) &&
      ShouldTraceRegistryKey(urlStr, registryKey)) {
    TNS_DEBUG(Esm, "[resolver][register-resolve-only] raw=%s key=%s", urlStr.c_str(),
              registryKey.c_str());
  }

  // Checked before compiling: recompiling a key that is already registered
  // would mint a second module identity while importers hold the first.
  auto itExisting = registry.find(registryKey);
  if (itExisting != registry.end()) {
    v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
    if (!existing.IsEmpty()) {
      return hs.Escape(existing);
    }
  }

  // Length-aware conversion: module source may contain embedded NUL bytes,
  // which the char* overload would truncate.
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
      TNS_DEBUG(Esm, "[http-esm][compile][fail] %s %s", urlStr.c_str(),
                DescribeCaughtError(isolate, context, tcCompile).c_str());
      tcCompile.ReThrow();
      return v8::MaybeLocal<v8::Module>();
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

static ParsedImportMap g_importMap;

// Volatile URL patterns: URLs matching these substrings are always re-fetched
// (cache is evicted before loading). Configured by Vite at boot — the
// vocabulary is server/framework policy, so the runtime carries no
// framework-specific URL strings here.
static std::vector<std::string> g_volatilePatterns;

static bool ShouldTraceRegistryKey(const std::string& rawKey, const std::string& registryKey) {
  if (rawKey != registryKey) {
    return true;
  }

  return StartsWith(registryKey, "node:") || StartsWith(registryKey, "blob:");
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
    // Preserve non-filesystem module namespaces such as node: so
    // synthetic/in-memory modules keep their exact registry identity.
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

  if (tns::LogCategoryEnabled(tns::LogCategory::Esm) &&
      (traceEvenWithoutChange || registryKey != key)) {
    TNS_DEBUG(Esm, "[resolver][registry-key][%s] raw=%s key=%s", classification, key.c_str(),
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

  TNS_DEBUG(Esm, "[http-esm][load][begin] request=%s key=%s", requestedUrl.c_str(),
            registryKey.c_str());

  auto itExisting = registry.find(registryKey);
  if (itExisting != registry.end()) {
    v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
      TNS_DEBUG(Esm, "[http-esm][load][cache-hit] key=%s", registryKey.c_str());
      return v8::MaybeLocal<v8::Module>(existing);
    }

    TNS_DEBUG(Esm, "[http-esm][load][drop-errored] key=%s", registryKey.c_str());
    RemoveModuleFromRegistry(isolate, registryKey);
  }

  // Reaching this point means the graph walk did not discover this URL, so the
  // module is about to be fetched synchronously, blocking the JS thread for a
  // whole round trip. That is an invariant violation, not a mode — always
  // visible, in every build, so it cannot hide behind a disabled trace
  // category. The fallback itself stays: correctness first, diagnosis loud.
  Log(@"NativeScript: module graph walk missed %s — falling back to a blocking "
      @"synchronous fetch. This should not happen; please report it.",
      requestedUrl.c_str());

  ModuleFetchResult fetched;
  if (!HttpFetchModule(requestedUrl, fetched)) {
    TNS_DEBUG(Esm, "[http-esm][load][fetch-fail] request=%s key=%s status=%d", requestedUrl.c_str(),
              registryKey.c_str(), fetched.status);
    // The classifier's reason names the URL and the cause (status, MIME, or
    // transport); a generic message here would lose all of it.
    isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, fetched.failureReason)));
    return v8::MaybeLocal<v8::Module>();
  }

  if (fetched.kind == ModuleResponseKind::kJson) {
    return CompileJsonTextAsEsModule(isolate, context, fetched.body, registryKey, requestedUrl);
  }

  const std::string& body = fetched.body;
  v8::Local<v8::Module> loaded;
  {
    v8::TryCatch tcCompile(isolate);
    if (!CompileModuleForResolveRegisterOnly(isolate, context, body, registryKey)
             .ToLocal(&loaded)) {
      TNS_DEBUG(Esm, "[http-esm][load][compile-fail] request=%s key=%s bytes=%zu",
                requestedUrl.c_str(), registryKey.c_str(), body.size());
      if (tcCompile.HasCaught()) {
        // The compile error names the module, line and column; replacing it
        // with a generic "compile failed" would strictly lose information.
        tcCompile.ReThrow();
      } else {
        std::string msg = "HTTP import compile failed: " + requestedUrl;
        isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
      }
      return v8::MaybeLocal<v8::Module>();
    }
  }

  TNS_DEBUG(Esm, "[http-esm][load][ok] request=%s key=%s type=%s bytes=%zu", requestedUrl.c_str(),
            registryKey.c_str(), fetched.contentType.c_str(), body.size());

  return loaded;
}

// ── Import map helpers ──────────────────────────────────────────────────────

// Read one imports-shaped section. Every rejection names the offending key so
// a bad map is fixable from the message alone.
static bool ParseImportMapEntries(NSDictionary* source, const std::string& sectionLabel,
                                  ImportMapEntries* out, std::string* error) {
  for (id key in source) {
    if (![key isKindOfClass:[NSString class]]) {
      *error = sectionLabel + ": every key must be a string";
      return false;
    }
    const char* keyUtf8 = [(NSString*)key UTF8String];
    if (keyUtf8 == nullptr) {
      *error = sectionLabel + ": every key must be a string";
      return false;
    }
    const std::string specifier(keyUtf8);
    if (specifier.empty()) {
      *error = sectionLabel + ": a specifier key must not be empty";
      return false;
    }

    id value = [source objectForKey:key];
    if (![value isKindOfClass:[NSString class]]) {
      *error = sectionLabel + ": the target for '" + specifier + "' must be a string";
      return false;
    }
    const char* valueUtf8 = [(NSString*)value UTF8String];
    if (valueUtf8 == nullptr) {
      *error = sectionLabel + ": the target for '" + specifier + "' must be a string";
      return false;
    }
    const std::string target(valueUtf8);
    if (target.empty()) {
      *error = sectionLabel + ": the target for '" + specifier + "' must not be empty";
      return false;
    }

    // A trailing-slash key maps a whole subtree, so its target must name one
    // too — otherwise the remainder would be pasted onto a file path.
    if (specifier.back() == '/' && target.back() != '/') {
      *error = sectionLabel + ": the target for '" + specifier +
               "' must end with '/' because the specifier key does";
      return false;
    }

    (*out)[specifier] = target;
  }
  return true;
}

// Parse without touching the live map. On any failure `error` explains what is
// wrong and `out` is meaningless — the caller keeps whatever it already had.
static bool ParseImportMap(const std::string& json, ParsedImportMap* out, std::string* error) {
  @autoreleasepool {
    NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
    if (data == nil || data.length == 0) {
      *error = "an import map must be a non-empty JSON object";
      return false;
    }
    NSError* parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&parseError];
    if (parsed == nil) {
      NSString* detail = parseError.localizedDescription ?: @"invalid JSON";
      *error = std::string("an import map must be valid JSON: ") + ([detail UTF8String] ?: "");
      return false;
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) {
      *error = "an import map must be a JSON object";
      return false;
    }

    NSDictionary* top = (NSDictionary*)parsed;
    for (id section in top) {
      if (![section isKindOfClass:[NSString class]] ||
          (![(NSString*)section isEqualToString:@"imports"] &&
           ![(NSString*)section isEqualToString:@"scopes"])) {
        const char* name =
            [section isKindOfClass:[NSString class]] ? [(NSString*)section UTF8String] : "";
        *error = std::string("unsupported import-map section '") + (name ? name : "") +
                 "'; only \"imports\" and \"scopes\" are supported";
        return false;
      }
    }

    id imports = [top objectForKey:@"imports"];
    if (imports != nil) {
      if (![imports isKindOfClass:[NSDictionary class]]) {
        *error = "the \"imports\" section must be an object";
        return false;
      }
      if (!ParseImportMapEntries((NSDictionary*)imports, "imports", &out->imports, error)) {
        return false;
      }
    }

    id scopes = [top objectForKey:@"scopes"];
    if (scopes != nil) {
      if (![scopes isKindOfClass:[NSDictionary class]]) {
        *error = "the \"scopes\" section must be an object";
        return false;
      }
      for (id scopeKey in (NSDictionary*)scopes) {
        if (![scopeKey isKindOfClass:[NSString class]]) {
          *error = "scopes: every scope key must be a string";
          return false;
        }
        const char* scopeUtf8 = [(NSString*)scopeKey UTF8String];
        const std::string scopePrefix(scopeUtf8 ? scopeUtf8 : "");
        if (scopePrefix.empty()) {
          *error = "scopes: a scope key must not be empty";
          return false;
        }
        id scopeMap = [(NSDictionary*)scopes objectForKey:scopeKey];
        if (![scopeMap isKindOfClass:[NSDictionary class]]) {
          *error = "scopes: the map for scope '" + scopePrefix + "' must be an object";
          return false;
        }
        ImportMapEntries entries;
        if (!ParseImportMapEntries((NSDictionary*)scopeMap, "scope '" + scopePrefix + "'", &entries,
                                   error)) {
          return false;
        }
        out->scopes.emplace_back(scopePrefix, std::move(entries));
      }
    }
  }

  // Most specific first: a longer prefix is the more specific scope, and the
  // key comparison keeps the order deterministic for equal-length prefixes.
  std::sort(out->scopes.begin(), out->scopes.end(),
            [](const std::pair<std::string, ImportMapEntries>& a,
               const std::pair<std::string, ImportMapEntries>& b) {
              if (a.first.size() != b.first.size()) {
                return a.first.size() > b.first.size();
              }
              return a.first > b.first;
            });
  return true;
}

bool SetImportMap(const std::string& json, std::string* error) {
  // Parse-validate-swap: the live vocabulary is replaced only once a complete
  // map has been built, so a rejected update leaves resolution exactly as it
  // was rather than silently emptying it.
  ParsedImportMap parsedMap;
  std::string localError;
  if (!ParseImportMap(json, &parsedMap, error != nullptr ? error : &localError)) {
    return false;
  }
  g_importMap = std::move(parsedMap);
  TNS_DEBUG(Esm, "[import-map] loaded %lu entries, %lu scopes",
            (unsigned long)g_importMap.imports.size(), (unsigned long)g_importMap.scopes.size());
  return true;
}

void SetVolatilePatterns(const std::vector<std::string>& patterns) {
  g_volatilePatterns = patterns;
  TNS_DEBUG(Esm, "[import-map] volatile patterns: %lu", (unsigned long)g_volatilePatterns.size());
}

// Check if a URL matches any volatile pattern (should bypass cache).
static bool IsVolatileUrl(const std::string& url) {
  for (const auto& pat : g_volatilePatterns) {
    if (url.find(pat) != std::string::npos) return true;
  }
  return false;
}

// Look up a specifier in ONE import-map section: exact match first, then the
// longest trailing-slash prefix entry, whose remainder is appended to the
// target. Returns empty when the section has no answer.
static std::string LookupInEntries(const ImportMapEntries& entries, const std::string& specifier) {
  auto it = entries.find(specifier);
  if (it != entries.end()) {
    TNS_DEBUG(Esm, "[import-map] exact: %s -> %s", specifier.c_str(), it->second.c_str());
    return it->second;
  }

  std::string bestKey;
  std::string bestValue;
  for (const auto& kv : entries) {
    const std::string& key = kv.first;
    if (key.back() != '/') {
      continue;  // only trailing-slash entries map subtrees
    }
    if (specifier.size() > key.size() && specifier.compare(0, key.size(), key) == 0) {
      if (key.size() > bestKey.size()) {
        bestKey = key;
        bestValue = kv.second;
      }
    }
  }
  if (bestKey.empty()) {
    return "";
  }
  std::string resolved = bestValue + specifier.substr(bestKey.size());
  TNS_DEBUG(Esm, "[import-map] prefix: %s -> %s (via %s)", specifier.c_str(), resolved.c_str(),
            bestKey.c_str());
  return resolved;
}

// The import-map resolution cascade: the most specific applicable scope first,
// then progressively less specific ones, then the top-level imports — each
// consulted with the same per-section lookup.
//
// A scope key matches as a plain prefix of `referrerKey`, the importing
// module's canonical registry key: an absolute http(s) URL for a served
// module, or a canonical absolute path for a file. That key is this runtime's
// analogue of the web's resolved referrer URL, which is what scope prefixes
// match there. Ending a scope key with '/' keeps it on a directory boundary,
// exactly as on the web.
static std::string LookupImportMap(const std::string& specifier, const std::string& referrerKey) {
  for (const auto& scope : g_importMap.scopes) {
    const std::string& prefix = scope.first;
    if (referrerKey.size() < prefix.size() || referrerKey.compare(0, prefix.size(), prefix) != 0) {
      continue;
    }
    std::string mapped = LookupInEntries(scope.second, specifier);
    if (!mapped.empty()) {
      TNS_DEBUG(Esm, "[import-map] scope '%s' matched referrer %s", prefix.c_str(),
                referrerKey.c_str());
      return mapped;
    }
  }
  return LookupInEntries(g_importMap.imports, specifier);
}

void CleanupImportMapGlobals() {
  // Process-global import-map state (not isolate-bound). The per-isolate
  // loader state lives in a Caches state slot and is destroyed with each
  // isolate's Caches (after QuiesceModuleLoadsForIsolate in ~Runtime).
  g_importMap = ParsedImportMap();
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
//     → GetModuleRequests() → ResolveSpecifierToPath → EnqueueUrl(…)
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

// ── The shared resolution seam ───────────────────────────────────────────────
//
// One module specifier resolved to something the loader can act on. Both
// ResolveModuleCallback and the graph walk go through this, so a module gets
// the same registry key whichever of them reaches it first — a divergence here
// mints two identities for one file.
//
// Pure computation: it consults the import map and the filesystem, but never
// compiles, registers, fetches, or throws.
struct ModuleResolution {
  enum class Kind {
    kUnresolved,  // nothing locatable; the caller decides how to report it
    kBuiltin,     // ns:/node: — served from the builtin registry
    kHttp,        // absolute http(s) URL
    kFile,        // absolute filesystem path, confirmed to be a regular file
  };

  Kind kind = Kind::kUnresolved;
  std::string url;        // kHttp
  std::string path;       // kFile
  std::string specifier;  // the specifier after import-map rewriting
  std::string attempted;  // kUnresolved: the last candidate tried
};

static bool IsRegularFile(const std::string& p) {
  std::string normalized = NormalizePath(p);
  struct stat st;
  if (stat(normalized.c_str(), &st) != 0) {
    return false;
  }
  return (st.st_mode & S_IFMT) == S_IFREG;
}

// Rebuild an HTTP URL a path join swallowed ('/app/http:/host/x' →
// 'http://host/x'), or empty when the path embeds none.
static std::string HttpUrlEmbeddedInPath(const std::string& p) {
  size_t pos1 = p.find("/http:/");
  size_t pos2 = p.find("/https:/");
  size_t pos = std::min(pos1 == std::string::npos ? SIZE_MAX : pos1,
                        pos2 == std::string::npos ? SIZE_MAX : pos2);
  if (pos == SIZE_MAX) {
    return "";
  }
  std::string tail = p.substr(pos + 1);
  if (StartsWith(tail, "http:/") && !StartsWith(tail, "http://")) {
    tail.insert(5, "/");
  } else if (StartsWith(tail, "https:/") && !StartsWith(tail, "https://")) {
    tail.insert(6, "/");
  }
  if (!(StartsWith(tail, "http://") || StartsWith(tail, "https://"))) {
    return "";
  }
  return tail;
}

// `referrerKey` is the registry key of the importing module — empty when the
// importer is unknown (a dynamic import with no compiled referrer).
static ModuleResolution ResolveSpecifierToPath(const std::string& rawSpec,
                                               const std::string& referrerKey) {
  ModuleResolution result;
  if (rawSpec.empty()) {
    return result;
  }

  // Builtins resolve before any path handling, so a file can never shadow one.
  if (NsBuiltinModules::IsBuiltinScheme(rawSpec)) {
    result.kind = ModuleResolution::Kind::kBuiltin;
    result.specifier = rawSpec;
    return result;
  }

  std::string spec = rawSpec;
  // Repair 'http:/host' (single slash) left by upstream path joins, so the URL
  // takes the HTTP path instead of becoming '/app/http:/host'.
  if (spec.rfind("http:/", 0) == 0 && spec.rfind("http://", 0) != 0) {
    spec.insert(5, "/");
  } else if (spec.rfind("https:/", 0) == 0 && spec.rfind("https://", 0) != 0) {
    spec.insert(6, "/");
  }

  TNS_DEBUG(Esm, "[resolver][spec] %s", spec.c_str());

  // The import map is consulted before any other resolution: bare specifiers
  // resolve through it to vendor or HTTP URLs. A client that rewrites
  // specifiers must map every form it emits — keys are matched literally.
  if (!g_importMap.empty()) {
    std::string mapped = LookupImportMap(spec, referrerKey);
    if (!mapped.empty()) {
      TNS_DEBUG(Esm, "[resolver][import-map] rewrite: %s -> %s", spec.c_str(), mapped.c_str());
      spec = mapped;
    } else if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
      // A bare-looking specifier the map didn't match is about to fall back to
      // filesystem resolution and almost certainly fail; surface the missing
      // entry before the more cryptic `Cannot find module` follow-on.
      bool looksBare = spec[0] != '/' && spec[0] != '.' && spec.find("://") == std::string::npos &&
                       spec.find('\\') == std::string::npos;
      if (looksBare) {
        TNS_DEBUG(
            Esm, "[resolver][import-map][miss] bare='%s' importMap.size=%lu importMap.empty=%d",
            spec.c_str(), (unsigned long)g_importMap.imports.size(), g_importMap.empty() ? 1 : 0);
      }
    }
  } else if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    // Map completely empty — distinct from "populated but no entry".
    bool looksBare = spec[0] != '/' && spec[0] != '.' && spec.find("://") == std::string::npos &&
                     spec.find('\\') == std::string::npos;
    if (looksBare) {
      TNS_DEBUG(Esm,
                "[resolver][import-map][empty] bare='%s' — g_importMap is EMPTY (was it ever "
                "configured? expected ~200-500 entries)",
                spec.c_str());
    }
  }

  result.specifier = spec;

  if (StartsWith(spec, "http://") || StartsWith(spec, "https://")) {
    result.kind = ModuleResolution::Kind::kHttp;
    result.url = spec;
    return result;
  }

  TNS_DEBUG(Esm, "[resolver] resolving '%s'", spec.c_str());

  const bool specIsRelative = spec[0] == '.';
  const bool specIsRootAbs = spec[0] == '/';
  size_t slash = referrerKey.find_last_of("/\\");
  std::string baseDir = slash == std::string::npos ? "" : referrerKey.substr(0, slash + 1);
  if (referrerKey.empty() && specIsRelative) {
    TNS_DEBUG(Esm,
              "[resolver] no registered referrer for relative import '%s'; resolving "
              "against app root",
              spec.c_str());
    baseDir = RuntimeConfig.ApplicationPath + "/";
  }

  // A referrer fetched over HTTP makes its relative and root-absolute imports
  // HTTP too, the way a browser resolves them.
  const bool referrerIsHttp =
      StartsWith(referrerKey, "http://") || StartsWith(referrerKey, "https://");
  if (referrerIsHttp && (specIsRelative || specIsRootAbs)) {
    std::string resolvedHttp;
    @autoreleasepool {
      NSString* baseStr = [NSString stringWithUTF8String:referrerKey.c_str()];
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
    if (StartsWith(resolvedHttp, "http://") || StartsWith(resolvedHttp, "https://")) {
      TNS_DEBUG(Esm, "[resolver][http-rel] base=%s spec=%s -> %s", referrerKey.c_str(),
                spec.c_str(), resolvedHttp.c_str());
      result.kind = ModuleResolution::Kind::kHttp;
      result.url = resolvedHttp;
      return result;
    }
  }

  // Build the filesystem candidates for this specifier shape. The specifier may
  // omit its extension or name a directory, so each candidate is probed with
  // Node-style extension and index fallbacks below.
  std::vector<std::string> candidateBases;

  if (specIsRelative) {
    std::string cleanSpec = spec.rfind("./", 0) == 0 ? spec.substr(2) : spec;
    @autoreleasepool {
      NSString* nsBase = [NSString stringWithUTF8String:baseDir.c_str()];
      NSString* nsRel = [NSString stringWithUTF8String:cleanSpec.c_str()];
      if (nsBase && nsRel) {
        NSString* joined = [nsBase stringByAppendingPathComponent:nsRel];
        NSString* standardized = [joined stringByStandardizingPath];
        if (standardized) {
          std::string candidate = NormalizePath(standardized.UTF8String);
          candidateBases.push_back(candidate);
          TNS_DEBUG(Esm, "[resolver][normalize-rel] %s + %s -> %s", baseDir.c_str(),
                    cleanSpec.c_str(), candidate.c_str());
        }
      }
    }
    TNS_DEBUG(Esm, "[resolver] Relative import: '%s' + '%s' -> '%s'", baseDir.c_str(),
              cleanSpec.c_str(), candidateBases.empty() ? "<none>" : candidateBases.back().c_str());
  } else if (spec.rfind("file://", 0) == 0) {
    std::string tail = spec.substr(7);
    if (tail.rfind("/", 0) != 0) {
      tail = "/" + tail;
    }
    const std::string appPrefix = "/app/";
    std::string tailNoApp = tail;
    if (tail.rfind(appPrefix, 0) == 0) {
      tailNoApp = tail.substr(appPrefix.size());
    }
    candidateBases.push_back(NormalizePath(RuntimeConfig.ApplicationPath + "/" + tailNoApp));
    candidateBases.push_back(NormalizePath(RuntimeConfig.ApplicationPath + tail));
  } else if (spec[0] == '~') {
    std::string tail = spec.size() >= 2 && spec[1] == '/' ? spec.substr(2) : spec.substr(1);
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + "/" + tail);
    candidateBases.push_back(base);

    // Projects that bundle JS under an app folder.
    std::string baseApp = NormalizePath(RuntimeConfig.ApplicationPath + "/app/" + tail);
    if (baseApp != base) {
      candidateBases.push_back(baseApp);
    }
    TNS_DEBUG(Esm, "[resolver][tilde] spec=%s base=%s appBase=%s", spec.c_str(), base.c_str(),
              baseApp.c_str());
  } else if (specIsRootAbs) {
    std::string base = NormalizePath(RuntimeConfig.ApplicationPath + spec);
    candidateBases.push_back(base);

    const std::string appPrefix = "/app/";
    if (spec.rfind(appPrefix, 0) == 0) {
      std::string tailNoApp = spec.substr(appPrefix.size() - 1);  // keeps the leading '/'
      std::string baseNoApp = NormalizePath(RuntimeConfig.ApplicationPath + tailNoApp);
      if (baseNoApp != base) {
        candidateBases.push_back(baseNoApp);
      }
      TNS_DEBUG(Esm, "[resolver][abs] spec=%s base=%s baseNoApp=%s", spec.c_str(), base.c_str(),
                baseNoApp.c_str());
    } else {
      TNS_DEBUG(Esm, "[resolver][abs] spec=%s base=%s", spec.c_str(), base.c_str());
    }
  } else {
    candidateBases.push_back(NormalizePath(RuntimeConfig.ApplicationPath + "/" + spec));
  }

  auto withExt = [](const std::string& p, const std::string& ext) -> std::string {
    if (p.size() >= ext.size() && p.compare(p.size() - ext.size(), ext.size(), ext) == 0) {
      return p;
    }
    return p + ext;
  };

  std::string absPath;
  for (const std::string& baseCandidate : candidateBases) {
    absPath = NormalizePath(baseCandidate);

    std::string embedded = HttpUrlEmbeddedInPath(absPath);
    if (!embedded.empty()) {
      TNS_DEBUG(Esm, "[resolver][http-embedded] %s -> %s", absPath.c_str(), embedded.c_str());
      result.kind = ModuleResolution::Kind::kHttp;
      result.url = embedded;
      return result;
    }

    bool existsNow = IsRegularFile(absPath);
    TNS_DEBUG(Esm, "[resolver] %s -> %s", absPath.c_str(), existsNow ? "file" : "missing");

    if (!existsNow) {
      bool found = false;
      for (const char* ext : {".mjs", ".js"}) {
        std::string cand = NormalizePath(withExt(absPath, ext));
        if (IsRegularFile(cand)) {
          absPath = cand;
          found = true;
          break;
        }
      }
      if (!found) {
        for (const char* idx : {"/index.mjs", "/index.js"}) {
          std::string cand = NormalizePath(absPath + idx);
          if (IsRegularFile(cand)) {
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
    if (IsRegularFile(absPath)) {
      break;
    }
  }

  absPath = NormalizePath(absPath);
  result.attempted = absPath;
  if (IsRegularFile(absPath)) {
    result.kind = ModuleResolution::Kind::kFile;
    result.path = absPath;
  }
  return result;
}

static void AsyncGraphEnqueue(const std::shared_ptr<AsyncGraphLoad>& load,
                              const ModuleResolution& resolution);

// Walk `mod`'s static module requests and enqueue every edge the walk can
// resolve. JS thread only; `moduleKey` is the registry key the module was
// registered under, which is also the referrer for relative resolution.
static void AsyncGraphWalkModuleRequests(const std::shared_ptr<AsyncGraphLoad>& load,
                                         v8::Local<v8::Context> context, v8::Local<v8::Module> mod,
                                         const std::string& moduleKey) {
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
    // Builtins are served by the resolver from the builtin registry, and an
    // unresolved specifier (typically a bare name with no import-map entry)
    // stays on the resolver's lazy path — where it either resolves later or
    // fails with the resolver's own message. An unmapped bare specifier's
    // subtree is therefore not discovered here; any HTTP edge inside it is
    // pathological and lands on the synchronous anomaly guard.
    const ModuleResolution resolution = ResolveSpecifierToPath(*specUtf8, moduleKey);
    if (resolution.kind == ModuleResolution::Kind::kBuiltin ||
        resolution.kind == ModuleResolution::Kind::kUnresolved) {
      continue;
    }
    AsyncGraphEnqueue(load, resolution);
  }
}

// Fire onComplete exactly once, when the frontier has drained. JS thread only.
static void AsyncGraphMaybeComplete(const std::shared_ptr<AsyncGraphLoad>& load,
                                    v8::Local<v8::Context> context) {
  if (load->completed || load->pendingFetches > 0) {
    return;
  }
  load->completed = true;
  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t ms = endUs > load->startUs ? (endUs - load->startUs) / 1000ull : 0ull;
    TNS_DEBUG(Esm, "[async-graph][done] root=%s urls=%lu fetched=%lu compiled=%lu ms=%llu ok=%d",
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
                                       const std::string& url,
                                       const std::shared_ptr<ModuleFetchResult>& fetched) {
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
    if (!fetched->ok) {
      if (isRoot) {
        load->failed = true;
        load->failureMessage = fetched->failureReason;
      } else {
        TNS_DEBUG(Esm, "[graph][dep-fetch-fail] %s (left to sync resolver)",
                  fetched->failureReason.c_str());
      }
    } else if (fetched->kind == ModuleResponseKind::kJson) {
      // JSON compiles, instantiates and evaluates in one step and carries no
      // module requests, so there is nothing further to walk from here.
      load->fetchedCount++;
      v8::TryCatch tcJson(isolate);
      if (CompileJsonTextAsEsModule(isolate, context, fetched->body, key, url).IsEmpty()) {
        std::string reason = DescribeCaughtError(isolate, context, tcJson);
        if (isRoot) {
          load->failed = true;
          load->failureMessage = "JSON module failed to compile: " + url;
          if (!reason.empty()) {
            load->failureMessage += " — " + reason;
          }
        } else {
          TNS_DEBUG(Esm, "[graph][dep-json-fail] %s %s (left to sync resolver)", url.c_str(),
                    reason.c_str());
        }
      } else {
        load->compiledCount++;
      }
    } else {
      load->fetchedCount++;
      v8::Local<v8::Module> mod;
      bool compiled = false;
      std::string compileError;
      {
        // This callback runs on to completion and a microtask checkpoint, so a
        // compile exception must be consumed here rather than left pending;
        // its text goes into the load's own failure channel instead.
        v8::TryCatch tcCompile(isolate);
        compiled =
            CompileModuleForResolveRegisterOnly(isolate, context, fetched->body, key).ToLocal(&mod);
        if (!compiled) {
          compileError = DescribeCaughtError(isolate, context, tcCompile);
        }
      }
      if (!compiled) {
        if (isRoot) {
          load->failed = true;
          load->failureMessage = "HTTP import compile failed: " + url;
          if (!compileError.empty()) {
            load->failureMessage += " — " + compileError;
          }
        } else {
          TNS_DEBUG(Esm, "[async-graph][dep-compile-fail] %s %s (left to sync resolver)",
                    url.c_str(), compileError.c_str());
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

// A local edge: read + compile + register it inline, then keep walking. No
// thread hop — the bytes are already on disk, and a hop would only reorder
// discovery. A compile failure is deliberately swallowed here: the walk is a
// discovery optimization, and the resolver (or LoadESModule, for the root)
// owns the error message for a module that will not compile. Leaving it
// unregistered is exactly what makes those paths run and report.
static void AsyncGraphCompileLocalModule(const std::shared_ptr<AsyncGraphLoad>& load,
                                         v8::Local<v8::Context> context, const std::string& path,
                                         const std::string& key) {
  v8::Isolate* isolate = load->isolate;
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }

  v8::Local<v8::Module> mod;
  {
    v8::TryCatch tcCompile(isolate);
    bool compiled = false;
    try {
      compiled = tns::ModuleInternal::CompileFileEsModule(isolate, path).ToLocal(&mod);
    } catch (NativeScriptException& ex) {
      TNS_DEBUG(Esm, "[graph][local-compile-fail] %s %s (left to the resolver)", path.c_str(),
                ex.getMessage().c_str());
      return;
    }
    if (!compiled) {
      TNS_DEBUG(Esm, "[graph][local-compile-fail] %s %s (left to the resolver)", path.c_str(),
                DescribeCaughtError(isolate, context, tcCompile).c_str());
      return;
    }
  }

  moduleState->registry[key].Reset(isolate, mod);
  IndexRegisteredModule(*moduleState, key, mod);
  load->compiledCount++;
  AsyncGraphWalkModuleRequests(load, context, mod, key);
}

// Enqueue one resolved edge into the walk frontier. JS thread only.
static void AsyncGraphEnqueue(const std::shared_ptr<AsyncGraphLoad>& load,
                              const ModuleResolution& resolution) {
  const bool isHttp = resolution.kind == ModuleResolution::Kind::kHttp;
  const std::string& target = isHttp ? resolution.url : resolution.path;
  // One keying function for both schemes: it dispatches to the HTTP canonical
  // key for URLs and to the normalized path otherwise, so the walk registers
  // every module under the exact key the resolver will look up.
  const std::string key = CanonicalizeRegistryKey(target);
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
    // Errored entry: drop and reload, mirroring LoadHttpModuleForUrl.
    RemoveModuleFromRegistry(isolate, key);
  }

  if (!isHttp) {
    // JSON carries no module requests, and it compiles through a different
    // path; there is nothing for the walk to discover in it.
    if (target.size() >= 5 && target.compare(target.size() - 5, 5, ".json") == 0) {
      return;
    }
    v8::Local<v8::Context> context = load->context.Get(isolate);
    if (!context.IsEmpty()) {
      AsyncGraphCompileLocalModule(load, context, target, key);
    }
    return;
  }

  load->pendingFetches++;
  std::shared_ptr<AsyncGraphLoad> loadRef = load;
  const std::string url = target;
  FetchModuleBodyAsync(url, [loadRef, url](ModuleFetchResult result) {
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
    auto resultPtr = std::make_shared<ModuleFetchResult>(std::move(result));
    loop->PostV8Task(std::make_unique<FetchCompletionTask>([loadRef, url, resultPtr]() {
                       AsyncGraphOnFetchCompleted(loadRef, url, resultPtr);
                     }),
                     /*nestable=*/true, /*delaySeconds=*/0);
  });
}

// Classify a walk root. The root arrives already resolved — an absolute URL
// from the HTTP loader, or a canonical path from LoadESModule — so it needs
// only scheme dispatch, not the full specifier resolution.
static ModuleResolution ResolutionForRoot(const std::string& root) {
  ModuleResolution resolution;
  resolution.specifier = root;
  if (StartsWith(root, "http://") || StartsWith(root, "https://")) {
    resolution.kind = ModuleResolution::Kind::kHttp;
    resolution.url = root;
  } else if (IsRegularFile(root)) {
    resolution.kind = ModuleResolution::Kind::kFile;
    resolution.path = root;
  }
  // Anything else stays kUnresolved: there is nothing to walk, and the
  // caller's own load path reports why.
  return resolution;
}

void StartModuleGraphLoad(
    v8::Isolate* isolate, v8::Local<v8::Context> context, const std::string& root,
    std::function<void(bool ok, const std::string& errorMessage, v8::Local<v8::Context> context)>
        onComplete) {
  auto load = std::make_shared<AsyncGraphLoad>();
  load->isolate = isolate;
  load->context.Reset(isolate, context);
  load->rootKey = CanonicalizeRegistryKey(root);
  load->startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
  load->onComplete = std::move(onComplete);

  AsyncGraphLoad::g_asyncGraphLoadsInFlightCounter().fetch_add(1, std::memory_order_acq_rel);
  RegisterAsyncGraphLoad(isolate, load);

  TNS_DEBUG(Esm, "[graph][start] root=%s key=%s", root.c_str(), load->rootKey.c_str());

  const ModuleResolution rootResolution = ResolutionForRoot(root);
  if (rootResolution.kind != ModuleResolution::Kind::kUnresolved) {
    AsyncGraphEnqueue(load, rootResolution);
  }
  // Nothing left pending (a disk-only graph finishes entirely here): complete
  // inline, so the pumped runner below never enters its wait loop.
  AsyncGraphMaybeComplete(load, context);
}

bool RunModuleGraphLoadPumped(v8::Isolate* isolate, v8::Local<v8::Context> context,
                              const std::string& root, double timeoutSeconds) {
  if (timeoutSeconds <= 0.0) {
    timeoutSeconds = 60.0;
  }
  auto done = std::make_shared<bool>(false);
  StartModuleGraphLoad(isolate, context, root,
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
  if (!*done) {
    TNS_DEBUG(Esm, "[graph][pumped][timeout] root=%s after %.1fs (sync loader takes over)",
              root.c_str(), timeoutSeconds);
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

  // Classification helper for diagnostics
  auto classify = [](const std::string& s) -> const char* {
    bool http = StartsWith(s, "http://") || StartsWith(s, "https://");
    if (http) {
      return IsVolatileUrl(s) ? "http:volatile" : "http:other";
    }
    if (StartsWith(s, "file://")) return "file-url";
    return "path";
  };

  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    if (registryKey != canonicalPath) {
      TNS_DEBUG(Esm, "[resolver][remove:pre] raw=%s key=%s class=%s", canonicalPath.c_str(),
                registryKey.c_str(), classify(registryKey));
    } else {
      TNS_DEBUG(Esm, "[resolver][remove:pre] key=%s class=%s", registryKey.c_str(),
                classify(registryKey));
    }
  }

  size_t regPre = registry.size();

  auto it = registry.find(registryKey);
  if (it != registry.end()) {
    // Only log stale removal for non-HTTP keys to avoid noisy dev HTTP churn.
    bool isHttpKey = StartsWith(registryKey, "http://") || StartsWith(registryKey, "https://");
    if (tns::LogCategoryEnabled(tns::LogCategory::Esm) && !isHttpKey) {
      TNS_DEBUG(Esm, "[resolver] removing stale module %s", registryKey.c_str());
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
  } else if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    TNS_DEBUG(Esm, "[resolver][remove:miss] key not found, proceed to clear fallbacks (%s)",
              registryKey.c_str());
  }

  TNS_DEBUG(Esm, "[resolver][remove:post] reg %lu→%lu", (unsigned long)regPre,
            (unsigned long)registry.size());
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

  const bool traceRegistry = tns::LogCategoryEnabled(tns::LogCategory::Registry);
  size_t hits = 0, misses = 0;
  for (const auto& url : uniqueUrls) {
    bool present = registry.find(url) != registry.end();
    if (present) {
      hits++;
    } else {
      misses++;
    }
    if (traceRegistry) {
      TNS_DEBUG(Registry, "invalidate %s key=%s", present ? "HIT " : "MISS", url.c_str());
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

  if (traceRegistry) {
    TNS_DEBUG(Registry, "invalidate summary unique=%lu hits=%lu misses=%lu (registry now=%lu)",
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
  TNS_DEBUG(Esm, "[dyn-import][http-await] queued waiter for %s status=%s", registryKey.c_str(),
            ModuleStatusToString(module->GetStatus()));
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
  TNS_DEBUG(Esm, "[dyn-import][failure] %s", message.c_str());
  return v8::Exception::Error(tns::ToV8String(isolate, message.c_str()));
}

static void ResolveHttpDynamicWaiters(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                      const std::string& registryKey,
                                      v8::Local<v8::Module> module) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  // Settling a promise can run its reactions immediately: with the default
  // microtask policy, a Resolve/Reject issued from a plain platform task (no
  // JS on the stack) drains the queue as the API call unwinds. A reaction that
  // re-imports this URL would then see stale routing state and park on a
  // waiter list that was just flushed — a promise nothing would ever settle.
  // So every piece of state that can route a new import onto the waiter list
  // is cleared FIRST; a re-entrant import then takes the registry-hit path.
  std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  auto waitIt = httpDynamicWaiters.find(registryKey);
  if (waitIt != httpDynamicWaiters.end()) {
    resolvers.swap(waitIt->second);
    httpDynamicWaiters.erase(waitIt);
  }
  moduleState->modulesInFlight.erase(registryKey);

  ResolveResolversWithModuleNamespace(isolate, context, resolvers, module, registryKey);
}

static void RejectHttpDynamicWaiters(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                     const std::string& registryKey, v8::Local<v8::Value> reason) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return;
  }
  // Cleared before rejecting, for the same reason as the resolve path: a
  // rejection handler that retries this URL must not join a flushed waiter
  // list.
  std::vector<v8::Global<v8::Promise::Resolver>> resolvers;
  auto& httpDynamicWaiters = moduleState->httpDynamicWaiters;
  auto waitIt = httpDynamicWaiters.find(registryKey);
  if (waitIt != httpDynamicWaiters.end()) {
    resolvers.swap(waitIt->second);
    httpDynamicWaiters.erase(waitIt);
  }
  moduleState->modulesInFlight.erase(registryKey);

  RejectResolversWithReason(isolate, context, resolvers, reason);
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

  TNS_DEBUG(Esm, "[resolver][invalidate-state] cleared in-flight state for %s",
            registryKey.c_str());
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
// Wrap JSON source as an ES module with the object as its default export.
// Shared by the filesystem path and the HTTP path so a served JSON module and
// an imported .json file behave identically; `displayUrl` only names the
// module in stack traces.
static v8::MaybeLocal<v8::Module> CompileJsonTextAsEsModule(v8::Isolate* isolate,
                                                            v8::Local<v8::Context> context,
                                                            const std::string& jsonText,
                                                            const std::string& registryKey,
                                                            const std::string& displayUrl) {
  auto* moduleState = ModuleLoaderStateFor(isolate);
  if (moduleState == nullptr) {
    return v8::MaybeLocal<v8::Module>();
  }
  auto& registry = moduleState->registry;
  const std::string& registryAbsPath = registryKey;

  // JSON modules are compiled eagerly to kEvaluated, so a registered entry is
  // complete and must be reused — recompiling would mint a second module
  // identity (and namespace) for the same source on every resolve.
  auto existingIt = registry.find(registryAbsPath);
  if (existingIt != registry.end()) {
    v8::Local<v8::Module> existing = existingIt->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() == v8::Module::kEvaluated) {
      return v8::MaybeLocal<v8::Module>(existing);
    }
    registry.erase(existingIt);
  }

  TNS_DEBUG(Esm, "[json] wrapping %s", displayUrl.c_str());

  std::string moduleSource = "export default " + jsonText + ";";

  v8::Local<v8::String> sourceText = tns::ToV8String(isolate, moduleSource);
  const std::string& url = displayUrl;

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

// The filesystem entry point: read the file, then share the wrap.
static v8::MaybeLocal<v8::Module> CompileJsonAsEsModule(v8::Isolate* isolate,
                                                        v8::Local<v8::Context> context,
                                                        const std::string& absPath,
                                                        const std::string& registryAbsPath) {
  const std::string jsonText = tns::ReadText(absPath);
  const std::string url = "file://" + ReplaceAll(absPath, RuntimeConfig.BaseDir, "");
  return CompileJsonTextAsEsModule(isolate, context, jsonText, registryAbsPath, url);
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

  v8::String::Utf8Value specUtf8(isolate, specifier);
  const std::string rawSpec = *specUtf8 ? *specUtf8 : "";
  if (rawSpec.empty()) {
    return v8::MaybeLocal<v8::Module>();
  }

  const std::string referrerPath = FindKeyForModule(*moduleState, isolate, referrer);
  const ModuleResolution resolution = ResolveSpecifierToPath(rawSpec, referrerPath);

  switch (resolution.kind) {
    case ModuleResolution::Kind::kBuiltin: {
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
    case ModuleResolution::Kind::kHttp:
      // Security: HttpFetchModule gates remote module access centrally.
      return LoadHttpModuleForUrl(isolate, context, resolution.url);
    case ModuleResolution::Kind::kUnresolved: {
      // Surfaced as an exception rather than left to ReadModule(), which would
      // abort the process trying to open a directory.
      std::string msg =
          "Cannot find module '" + resolution.specifier + "' (tried " + resolution.attempted + ")";
      isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
      return v8::MaybeLocal<v8::Module>();
    }
    case ModuleResolution::Kind::kFile:
      break;
  }

  const std::string& absPath = resolution.path;
  const std::string registryAbsPath = CanonicalizeRegistryKey(absPath);

  // JSON imports (import data from './foo.json' with { type: 'json' }).
  if (absPath.size() >= 5 && absPath.compare(absPath.size() - 5, 5, ".json") == 0) {
    return CompileJsonAsEsModule(isolate, context, absPath, registryAbsPath);
  }

  // Reuse any live, non-errored registry entry. The resolver never evaluates,
  // so an unfinished entry (kUninstantiated / kInstantiating / kEvaluating)
  // simply rejoins the graph V8 is currently linking — that is how import
  // cycles terminate, the same way Node/Blink break them with the module-map
  // self-insert.
  auto it = registry.find(registryAbsPath);
  if (it != registry.end()) {
    v8::Local<v8::Module> existing = it->second.Get(isolate);
    if (!existing.IsEmpty() && existing->GetStatus() != v8::Module::kErrored) {
      TNS_DEBUG(Esm, "[resolver] cache hit %s (status=%s)", absPath.c_str(),
                ModuleStatusToString(existing->GetStatus()));
      return v8::MaybeLocal<v8::Module>(existing);
    }
    RemoveModuleFromRegistry(isolate, absPath);
  }

  // Compile + register only — never instantiate or evaluate here. V8 is
  // instantiating the importer and continues the graph walk by resolving this
  // module's own requests next; evaluating inside the resolver would run
  // dependencies in resolver order instead of the spec's evaluation order.
  TNS_DEBUG(Esm, "[resolver] → compile-register %s", absPath.c_str());
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
  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    auto* moduleState = ModuleLoaderStateFor(isolate);
    if (moduleState != nullptr && moduleState->registry.find(key) == moduleState->registry.end()) {
      // The async walk was expected to have registered the root; falling
      // back to the synchronous loader here means the walk missed it.
      TNS_DEBUG(Esm, "[async-graph][fallback-sync-load] root missed walk: %s", key.c_str());
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
        TNS_DEBUG(Esm, "[dyn-import][http-loader] waiting on existing evaluation for %s status=%s",
                  key.c_str(), ModuleStatusToString(mod->GetStatus()));
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
            if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
              v8::String::Utf8Value r(iso, reason);
              if (*r) {
                TNS_DEBUG(Esm, "[dyn-import][http-loader][tla] rejected: %s", *r);
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
  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    TNS_DEBUG(Esm, "[dyn-import] → %s", cSpec);
    // Also log the referrer resource when available to correlate origin of dynamic imports
    v8::Local<v8::Value> resName = resource_name;
    if (!resName.IsEmpty() && resName->IsString()) {
      v8::String::Utf8Value rn(isolate, resName);
      if (*rn) {
        TNS_DEBUG(Esm, "[dyn-import][referrer] %s", *rn);
      }
    }
  }
  // Normalize spec: only strip ?query/hash for non-HTTP specs so SFC HTTP keys keep
  // version tags
  std::string rawSpec = cSpec ? std::string(cSpec) : std::string();

  // Builtin modules never reach the loader below; the namespace comes straight
  // from the realm's synthetic module.
  if (NsBuiltinModules::IsBuiltinScheme(rawSpec)) {
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
    TNS_DEBUG(Esm, "[dyn-import][normalize] %s -> %s", rawSpec.c_str(), normalizedSpec.c_str());
  }
  v8::EscapableHandleScope scope(isolate);

  // Create a Promise resolver we'll resolve/reject synchronously for now.
  v8::Local<v8::Promise::Resolver> resolver;
  if (!v8::Promise::Resolver::New(context).ToLocal(&resolver)) {
    // Failed to create resolver, return empty promise
    return v8::MaybeLocal<v8::Promise>();
  }

  // ── Import map resolution for dynamic import() ────────────────
  // Same scoped lookup the resolver and the walk use. The referrer key comes
  // from the host-supplied resource name, canonicalized the way the registry
  // keys it, so a scope matches an import() exactly as it matches a static
  // import from the same module.
  if (!g_importMap.empty() && !normalizedSpec.empty()) {
    std::string dynamicReferrerKey;
    if (!resource_name.IsEmpty() && resource_name->IsString()) {
      v8::String::Utf8Value resourceUtf8(isolate, resource_name);
      if (*resourceUtf8) {
        dynamicReferrerKey = CanonicalizeRegistryKey(*resourceUtf8);
      }
    }
    std::string mapped = LookupImportMap(normalizedSpec, dynamicReferrerKey);
    if (!mapped.empty()) {
      // Mapped to an HTTP URL or other specifier
      normalizedSpec = mapped;
      specifier = tns::ToV8String(isolate, normalizedSpec.c_str());
      specStr = [NSString stringWithUTF8String:normalizedSpec.c_str()];
      TNS_DEBUG(Esm, "[dyn-import][import-map] rewrite: %s -> %s", rawSpec.c_str(),
                normalizedSpec.c_str());
    }
  }

  // Re-use the static resolver to locate / compile the module.
  try {
    // ── Blob URL support (e.g., blob:nativescript/<uuid>) ──
    // Also useful for HMR updates where we can load a blob URL
    // We retrieve the blob content from the global BLOB_STORE via URL.InternalAccessor.getData()
    // and compile/execute it as an ES module.
    if (!normalizedSpec.empty() && StartsWith(normalizedSpec, "blob:nativescript/")) {
      const std::string blobRegistryKey = CanonicalizeRegistryKey(normalizedSpec);

      TNS_DEBUG(Esm, "[dyn-import][blob] trying blob URL %s key=%s", normalizedSpec.c_str(),
                blobRegistryKey.c_str());

      auto existingIt = registry.find(blobRegistryKey);
      if (existingIt != registry.end()) {
        v8::Local<v8::Module> existing = existingIt->second.Get(isolate);
        if (!existing.IsEmpty()) {
          v8::Module::Status existingStatus = existing->GetStatus();
          TNS_DEBUG(Esm, "[dyn-import][blob-cache] hit %s status=%s", blobRegistryKey.c_str(),
                    ModuleStatusToString(existingStatus));

          if (existingStatus == v8::Module::kErrored) {
            RemoveModuleFromRegistry(isolate, blobRegistryKey);
          } else if (IsModuleEvaluationInProgress(existingStatus)) {
            modulesInFlight.insert(blobRegistryKey);
            httpDynamicWaiters[blobRegistryKey].emplace_back(isolate, resolver);
            TNS_DEBUG(Esm, "[dyn-import][blob-await] queued waiter for %s status=%s",
                      blobRegistryKey.c_str(), ModuleStatusToString(existingStatus));
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
        TNS_DEBUG(Esm, "[dyn-import][blob] coalesce in-flight %s", blobRegistryKey.c_str());
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
        TNS_DEBUG(Esm, "[dyn-import][blob] URL constructor not found");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] URL.InternalAccessor not found");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] URL.InternalAccessor.getData not found");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] blob not found in BLOB_STORE: %s",
                  normalizedSpec.c_str());
        std::string msg = "Blob not found: " + normalizedSpec;
        RejectHttpDynamicWaiters(isolate, context, blobRegistryKey,
                                 v8::Exception::Error(tns::ToV8String(isolate, msg.c_str())));
        return scope.Escape(resolver->GetPromise());
      }

      // blobDataVal should be {blob: Blob, type: string, ext: string}
      // We need to get the text from the Blob
      if (!blobDataVal->IsObject()) {
        TNS_DEBUG(Esm, "[dyn-import][blob] blob data is not an object");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] blob property not found");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] Blob.text() not available");
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
        TNS_DEBUG(Esm, "[dyn-import][blob] %s", textFailure.c_str());
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

        TNS_DEBUG(Esm, "[dyn-import][blob] compiling blob module, code length=%zu", code.size());

        v8::Local<v8::Module> mod;
        bool compiled = false;
        std::string compileError;
        {
          // A pending exception would escape this callback into V8's promise
          // machinery; the waiters are this path's failure channel.
          v8::TryCatch tcCompile(iso);
          compiled = CompileModuleForResolveRegisterOnly(iso, ctx, code, d->blobUrl).ToLocal(&mod);
          if (!compiled) {
            compileError = DescribeCaughtError(iso, ctx, tcCompile);
          }
        }
        if (!compiled) {
          std::string msg = "Failed to compile blob module";
          if (!compileError.empty()) {
            msg += ": " + compileError;
          }
          RejectHttpDynamicWaiters(iso, ctx, d->registryKey,
                                   v8::Exception::Error(tns::ToV8String(iso, msg)));
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
          TNS_DEBUG(Esm, "[dyn-import][blob] waiting on existing evaluation for %s status=%s",
                    d->registryKey.c_str(), ModuleStatusToString(mod->GetStatus()));
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
    // Security: HttpFetchModule gates remote module access centrally.
    if (!normalizedSpec.empty() &&
        (StartsWith(normalizedSpec, "http://") || StartsWith(normalizedSpec, "https://"))) {
      TNS_DEBUG(Esm, "[dyn-import][http-loader] trying URL %s", normalizedSpec.c_str());
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
          TNS_DEBUG(Esm, "[dyn-import][http-cache] drop volatile %s", key.c_str());
          RemoveModuleFromRegistry(isolate, key);
        }
      }
      // Coalesce concurrent dynamic imports for the same HTTP key
      auto inflight = modulesInFlight.find(key) != modulesInFlight.end();
      if (inflight) {
        TNS_DEBUG(Esm, "[dyn-import][http] coalesce in-flight %s", key.c_str());
        httpDynamicWaiters[key].emplace_back(isolate, resolver);
        return scope.Escape(resolver->GetPromise());
      }
      // If module was already compiled, resolve immediately
      auto itExisting = registry.find(key);
      if (itExisting != registry.end()) {
        v8::Local<v8::Module> existing = itExisting->second.Get(isolate);
        if (!existing.IsEmpty()) {
          // Verifies that an invalidation really did drop the entry.
          TNS_DEBUG(Registry, "dyn-cache HIT %s status=%s", key.c_str(),
                    ModuleStatusToString(existing->GetStatus()));
          if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
            TNS_DEBUG(Esm, "[dyn-import][http-cache] hit %s", key.c_str());
            TNS_DEBUG(Esm, "  ↳ status=%s", ModuleStatusToString(existing->GetStatus()));
          }
          v8::Module::Status st = existing->GetStatus();
          if (st == v8::Module::kErrored) {
            // Stale/broken entry; drop and refetch
            TNS_DEBUG(Esm, "[dyn-import][http-cache] dropping errored module for %s", key.c_str());
            RemoveModuleFromRegistry(isolate, key);
            // fall through to fetch/compile path below
          } else if (IsModuleEvaluationInProgress(st)) {
            if (QueueHttpDynamicWaiterIfInFlight(isolate, key, existing, resolver)) {
              return scope.Escape(resolver->GetPromise());
            }

            TNS_DEBUG(Esm, "[dyn-import][http-cache] avoiding re-entrant Evaluate for %s status=%s",
                      key.c_str(), ModuleStatusToString(st));
            resolver->Resolve(context, existing->GetModuleNamespace()).FromMaybe(false);
            return scope.Escape(resolver->GetPromise());
          } else {
            // Ensure dynamic import semantics: resolve only after evaluation
            if (st != v8::Module::kEvaluated) {
              // mark in-flight while we evaluate
              modulesInFlight.insert(key);
              TNS_DEBUG(Esm, "[dyn-import][http-cache] awaiting evaluation %s", key.c_str());
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
                  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
                    v8::String::Utf8Value r(iso, reason);
                    if (*r) {
                      TNS_DEBUG(Esm, "[dyn-import][http-cache][tla] rejected: %s", *r);
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
      // Confirms that after an invalidation the next dynamic import does NOT
      // reuse the cache and DOES go to the network.
      TNS_DEBUG(Registry, "dyn-cache FRESH-FETCH %s", key.c_str());
      // Async pipeline: fetch + compile the transitive closure off the JS
      // thread's critical path, then instantiate/evaluate and settle the
      // queued waiters from the walk's completion. The promise returns to JS
      // immediately — no synchronous fetch, no runloop pump.
      const std::string requestUrl = normalizedSpec;
      StartModuleGraphLoad(
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
          TNS_DEBUG(Esm, "[dyn-import][ref] url=%s base=%s spec=%s", refUrl.c_str(),
                    baseDir.c_str(), normalizedSpec.c_str());
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
                TNS_DEBUG(Esm, "[dyn-import][normalize-rel] %s + %s -> %s", baseDir.c_str(),
                          normalizedSpec.c_str(), fsPath.c_str());
              }
            }
          }
        }
      } else {
        TNS_DEBUG(Esm,
                  "[dyn-import][ref] missing resource name; cannot normalize relative spec against "
                  "referrer");
      }
    }

    // Discovery pre-pass, the same one the static path runs: a local graph can
    // reach HTTP edges, and without the walk those meet the resolver cold and
    // fetch serially, one blocking round trip each. A graph with no HTTP edges
    // settles inside the call, so a local-only dynamic import is unchanged —
    // it neither waits nor touches the runloop.
    {
      v8::String::Utf8Value adjustedUtf8(isolate, adjustedSpecifier);
      const ModuleResolution rootResolution =
          ResolveSpecifierToPath(*adjustedUtf8 ? *adjustedUtf8 : "", std::string());
      if (rootResolution.kind == ModuleResolution::Kind::kFile) {
        RunModuleGraphLoadPumped(isolate, context, rootResolution.path,
                                 tns::kModuleEvaluateDeadlineSeconds);
      }
    }

    v8::TryCatch resolveTc(isolate);
    v8::MaybeLocal<v8::Module> maybeModule =
        ResolveModuleCallback(context, adjustedSpecifier, import_assertions, refMod);
    if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
      // Log the adjusted specifier we sent to the resolver
      v8::String::Utf8Value adj(isolate, adjustedSpecifier);
      const char* cAdj = (*adj) ? *adj : "<invalid>";
      TNS_DEBUG(Esm, "[dyn-import][resolver-call] raw=%s normalized=%s adjusted=%s",
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
        TNS_DEBUG(Esm, "[dyn-import] ✗ instantiate failed %s", [specStr UTF8String]);
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
        TNS_DEBUG(Esm, "[dyn-import] ✗ evaluation failed %s", [specStr UTF8String]);
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
          TNS_DEBUG(Esm, "[dyn-import][tla] fulfilled, resolving namespace");
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
          if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
            v8::String::Utf8Value r(iso, reason);
            if (*r) {
              TNS_DEBUG(Esm, "[dyn-import][tla] rejected: %s", *r);
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
        TNS_DEBUG(Esm, "[dyn-import] Detected webpack chunk %s", [specStr UTF8String]);
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
                TNS_DEBUG(Esm, "[dyn-import] Found runtime module default export");
                v8::Local<v8::String> installKey = tns::ToV8String(isolate, "C");
                v8::Local<v8::Value> installFn;
                if (webpackRequire.As<v8::Object>()->Get(context, installKey).ToLocal(&installFn) &&
                    installFn->IsFunction()) {
                  TNS_DEBUG(Esm, "[dyn-import] Calling webpack installChunk function");
                  // Call webpack's installChunk function with the module namespace
                  v8::Local<v8::Value> args[] = {namespaceObj};
                  v8::Local<v8::Value> result;
                  if (!installFn.As<v8::Function>()
                           ->Call(context, v8::Undefined(isolate), 1, args)
                           .ToLocal(&result)) {
                    // If the call fails, we can ignore it since this is just a helper for webpack
                    // chunks
                    TNS_DEBUG(Esm, "[dyn-import] ✗ webpack installChunk call failed");
                  } else {
                    TNS_DEBUG(Esm, "[dyn-import] ✓ webpack installChunk call succeeded");
                  }
                } else {
                  TNS_DEBUG(Esm, "[dyn-import] ✗ webpack installChunk function not found");
                }
              } else {
                TNS_DEBUG(Esm, "[dyn-import] ✗ runtime module default export not found");
              }
            }
          } else {
            TNS_DEBUG(Esm, "[dyn-import] ✗ runtime module not found");
          }
        } catch (...) {
          TNS_DEBUG(Esm, "[dyn-import] ✗ exception while accessing runtime module");
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
        TNS_DEBUG(Esm, "[dyn-import][verify] ns.default threw after eval (generic) %s",
                  [specStr UTF8String]);
        resolver
            ->Reject(context, v8::Exception::Error(
                                  tns::ToV8String(isolate, "TDZ on default after eval (generic)")))
            .Check();
        return scope.Escape(resolver->GetPromise());
      }
    }
    resolver->Resolve(context, module->GetModuleNamespace()).Check();
    TNS_DEBUG(Esm, "[dyn-import] ✓ resolved %s", [specStr UTF8String]);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    TNS_DEBUG(Esm, "[dyn-import] ✗ native failed %s", [specStr UTF8String]);
    resolver
        ->Reject(context, v8::Exception::Error(
                              tns::ToV8String(isolate, "Native error during dynamic import")))
        .Check();
  }

  return scope.Escape(resolver->GetPromise());
}

// ─────────────────────────────────────────────────────────────
// The `ns:module` dev surface
//
// The runtime's dev surface is deliberately small: it exposes
// *mechanism* only (resolution config, registry eviction, registry
// introspection). All HMR *policy* — boot orchestration,
// `import.meta.hot`, full reload, CSS apply, WebSocket protocol, worker
// teardown — lives in the JS dev client (`@nativescript/vite`).
// The surface is reachable exclusively through the `ns:module` builtin
// module (require / static import / import()); there is no global.

namespace {

// Sets the function name on the v8 Function for nicer stack traces and
// attaches it as a member of the `ns:module` binding object.
void InstallDevFunction(v8::Isolate* isolate, v8::Local<v8::Context> context,
                        v8::Local<v8::Object> target, const char* name,
                        v8::FunctionCallback callback) {
  v8::Local<v8::FunctionTemplate> fnTpl = v8::FunctionTemplate::New(isolate, callback);
  v8::Local<v8::Function> fn = fnTpl->GetFunction(context).ToLocalChecked();
  fn->SetName(tns::ToV8String(isolate, name));
  target->CreateDataProperty(context, tns::ToV8String(isolate, name), fn).Check();
}

void ConfigureLoaderCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  bool traceEsm = tns::LogCategoryEnabled(tns::LogCategory::Esm);

  if (info.Length() < 1 || !info[0]->IsObject()) {
    if (traceEsm) {
      TNS_DEBUG(Esm, "[ns:module configureLoader] expected config object argument");
    }
    return;
  }

  v8::Local<v8::Object> config = info[0].As<v8::Object>();

  // Process importMap: can be a JSON string or an object with { imports: {...} }
  v8::Local<v8::String> importMapKey = tns::ToV8String(isolate, "importMap");
  v8::Local<v8::Value> importMapVal;
  if (config->Get(ctx, importMapKey).ToLocal(&importMapVal) && !importMapVal->IsUndefined()) {
    std::string jsonStr;
    if (importMapVal->IsString()) {
      v8::String::Utf8Value utf8(isolate, importMapVal);
      if (*utf8) jsonStr = *utf8;
    } else if (importMapVal->IsObject()) {
      // Serialize object to JSON string
      v8::Local<v8::Object> jsonObj = ctx->Global()
                                          ->Get(ctx, tns::ToV8String(isolate, "JSON"))
                                          .ToLocalChecked()
                                          .As<v8::Object>();
      v8::Local<v8::Function> stringify = jsonObj->Get(ctx, tns::ToV8String(isolate, "stringify"))
                                              .ToLocalChecked()
                                              .As<v8::Function>();
      v8::Local<v8::Value> args[] = {importMapVal};
      v8::Local<v8::Value> result;
      if (stringify->Call(ctx, jsonObj, 1, args).ToLocal(&result) && result->IsString()) {
        v8::String::Utf8Value utf8(isolate, result);
        if (*utf8) jsonStr = *utf8;
      }
    }
    std::string importMapError;
    if (jsonStr.empty()) {
      isolate->ThrowException(v8::Exception::TypeError(tns::ToV8String(
          isolate, "configureLoader: importMap must be an object or a JSON string")));
      return;
    }
    if (!SetImportMap(jsonStr, &importMapError)) {
      // The previous map is still installed: a rejected update changes
      // nothing, so a typo cannot empty a live session's vocabulary.
      isolate->ThrowException(
          v8::Exception::TypeError(tns::ToV8String(isolate, "configureLoader: " + importMapError)));
      return;
    }
    if (traceEsm) {
      TNS_DEBUG(Esm, "[ns:module configureLoader] import map set (%zu bytes)", jsonStr.size());
    }
  }

  // Reads `obj[key]` as an array of strings into `out`; non-string elements
  // are skipped. Returns true when the property exists and is an array.
  auto readStringArray = [&](v8::Local<v8::Object> obj, const char* key,
                             std::vector<std::string>& out) -> bool {
    v8::Local<v8::Value> val;
    if (!obj->Get(ctx, tns::ToV8String(isolate, key)).ToLocal(&val) || !val->IsArray()) {
      return false;
    }
    v8::Local<v8::Array> arr = val.As<v8::Array>();
    for (uint32_t i = 0; i < arr->Length(); i++) {
      v8::Local<v8::Value> elem;
      if (arr->Get(ctx, i).ToLocal(&elem) && elem->IsString()) {
        v8::String::Utf8Value utf8(isolate, elem);
        if (*utf8) out.push_back(*utf8);
      }
    }
    return true;
  };

  // Process volatilePatterns: array of strings
  {
    std::vector<std::string> patterns;
    if (readStringArray(config, "volatilePatterns", patterns) && !patterns.empty()) {
      SetVolatilePatterns(patterns);
      if (traceEsm) {
        TNS_DEBUG(Esm, "[ns:module configureLoader] %zu volatile patterns set", patterns.size());
      }
    }
  }

  // Process canonicalization: { stripParams, forPathPrefixes, preserveQueryFor }
  // — the URL vocabulary CanonicalizeHttpUrlKey applies (see its doc block).
  // Presence of the object marks the vocabulary as configured, replacing the
  // built-in fallback entirely (empty arrays are honored as explicit policy).
  {
    v8::Local<v8::Value> canonVal;
    if (config->Get(ctx, tns::ToV8String(isolate, "canonicalization")).ToLocal(&canonVal) &&
        canonVal->IsObject()) {
      v8::Local<v8::Object> canonObj = canonVal.As<v8::Object>();
      CanonicalizationConfig canon;
      readStringArray(canonObj, "stripParams", canon.stripParams);
      readStringArray(canonObj, "forPathPrefixes", canon.devPathPrefixes);
      readStringArray(canonObj, "preserveQueryFor", canon.preserveQueryPrefixes);
      SetCanonicalizationConfig(std::move(canon));
    }
  }
}

void InvalidateModulesCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  if (info.Length() < 1 || !info[0]->IsArray()) {
    Log(@"[ns:module invalidateModules] expected array of URL strings");
    return;
  }

  v8::Local<v8::Array> urlsArray = info[0].As<v8::Array>();
  std::vector<std::string> urls;
  urls.reserve(urlsArray->Length());
  for (uint32_t index = 0; index < urlsArray->Length(); index++) {
    v8::Local<v8::Value> value;
    if (!urlsArray->Get(ctx, index).ToLocal(&value) || !value->IsString()) {
      continue;
    }

    v8::String::Utf8Value utf8(isolate, value);
    if (*utf8) {
      urls.emplace_back(*utf8);
    }
  }

  // Permanent observability: surface every URL the runtime is asked to
  // drop, plus a sample of currently-loaded module registry keys so we
  // can correlate "asked to evict X" against "actually had X loaded as
  // Y" when canonicalization differs (e.g. http://localhost vs
  // file:// or http:// with port). Verbose-gated since per-event
  // chatter is only useful while debugging an eviction mismatch.
  if (tns::LogCategoryEnabled(tns::LogCategory::Registry)) {
    TNS_DEBUG(Registry, "invalidate called urls.count=%zu", urls.size());
    size_t shown = 0;
    for (const auto& u : urls) {
      if (shown >= 32) break;
      TNS_DEBUG(Registry, "invalidate url[%zu]=%s", shown, u.c_str());
      shown++;
    }
    if (urls.size() > shown) {
      TNS_DEBUG(Registry, "invalidate (hidden %zu more URL(s))", urls.size() - shown);
    }
  }

  tns::InvalidateModules(isolate, ctx, urls);
}

void GetLoadedModuleUrlsCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  std::vector<std::string> urls = tns::GetLoadedModuleUrls();
  v8::Local<v8::Array> result = v8::Array::New(isolate, static_cast<int>(urls.size()));

  for (uint32_t index = 0; index < urls.size(); index++) {
    result->Set(ctx, index, tns::ToV8String(isolate, urls[index].c_str())).FromMaybe(false);
  }

  info.GetReturnValue().Set(result);
}

}  // namespace

bool BuildNsModuleBinding(v8::Local<v8::Context> context, v8::Local<v8::Object> binding) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();

  InstallDevFunction(isolate, context, binding, "configureLoader", ConfigureLoaderCallback);
  InstallDevFunction(isolate, context, binding, "invalidateModules", InvalidateModulesCallback);
  InstallDevFunction(isolate, context, binding, "getLoadedModuleUrls", GetLoadedModuleUrlsCallback);

  if (!ModuleInternal::InstallCreateRequireBinding(context, binding)) {
    return false;
  }

  if (RuntimeConfig.IsDebug) {
    // Debug-only diagnostic: expose the HTTP canonical-key function to JS so
    // the test harness can pin its identity behavior across cache-busters
    // and dev-endpoint query normalization.
    auto canonicalizeCb = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
      v8::Isolate* iso = info.GetIsolate();
      if (info.Length() < 1 || !info[0]->IsString()) {
        info.GetReturnValue().SetEmptyString();
        return;
      }
      v8::String::Utf8Value u(iso, info[0]);
      std::string key = CanonicalizeHttpUrlKey(*u ? std::string(*u) : std::string());
      info.GetReturnValue().Set(tns::ToV8String(iso, key.c_str()));
    };
    v8::Local<v8::Function> fn;
    if (v8::Function::New(context, canonicalizeCb).ToLocal(&fn)) {
      fn->SetName(tns::ToV8String(isolate, "canonicalizeHttpUrlKey"));
      if (!binding
               ->CreateDataProperty(context, tns::ToV8String(isolate, "canonicalizeHttpUrlKey"), fn)
               .FromMaybe(false)) {
        return false;
      }
    }
  }

  return true;
}

}  // namespace tns
