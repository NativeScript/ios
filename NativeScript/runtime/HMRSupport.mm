#include "HMRSupport.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include "DevFlags.h"

#include <atomic>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <string>
#include <mutex>
#include "Helpers.h"
#include "ModuleInternalCallbacks.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

// Use centralized dev flags helper for logging

namespace tns {

static inline bool StartsWith(const std::string& s, const char* prefix) {
  size_t n = strlen(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
}

static inline bool EndsWith(const std::string& s, const char* suffix) {
  size_t n = strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

// Per-module hot data and callbacks. Keyed by canonical module path.
// Heap-allocated (leaky singleton) to prevent V8 crash during __cxa_finalize_ranges.
// See g_moduleRegistry comment in ModuleInternalCallbacks.mm for full rationale.
static auto* _g_hotData = new std::unordered_map<std::string, v8::Global<v8::Object>>();
static auto& g_hotData = *_g_hotData;
static auto* _g_hotAccept = new std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>>();
static auto& g_hotAccept = *_g_hotAccept;
static auto* _g_hotDispose = new std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>>();
static auto& g_hotDispose = *_g_hotDispose;
// Per-module prune callbacks (`import.meta.hot.prune(cb)`). Symmetric with
// `g_hotDispose` — separate registry because Vite spec semantics differ:
// `dispose` fires on every replacement (every HMR cycle), `prune` fires
// only when the module is removed from the dependency graph entirely.
static auto* _g_hotPrune = new std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>>();
static auto& g_hotPrune = *_g_hotPrune;

// Custom event listeners
// Keyed by event name (global, not per-module)
static std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>> g_hotEventListeners;

// Set of canonical module keys that called `import.meta.hot.decline()`.
// The HMR client checks this set before applying an update — if any update
// touches a declined key, the update converts to a full reload. No V8
// handles to clean up (just strings), so this lives in a plain set with
// its own mutex for thread safety.
static std::unordered_set<std::string> g_hotDeclined;
static std::mutex g_hotDeclinedMutex;

// Active deterministic dev-session state.
static DevSessionState g_activeDevSession;
static std::mutex g_activeDevSessionMutex;

bool GetOptionalStringProperty(v8::Isolate* isolate, v8::Local<v8::Context> context,
                               v8::Local<v8::Object> object, const char* key,
                               std::string* out) {
  if (out == nullptr) return false;

  v8::Local<v8::Value> value;
  if (!object->Get(context, tns::ToV8String(isolate, key)).ToLocal(&value) ||
      value->IsUndefined() || value->IsNull()) {
    return false;
  }

  v8::Local<v8::String> stringValue;
  if (!value->ToString(context).ToLocal(&stringValue)) {
    return false;
  }

  v8::String::Utf8Value utf8(isolate, stringValue);
  *out = *utf8 ? *utf8 : "";
  return true;
}

v8::Local<v8::Promise> CreateResolvedPromise(v8::Isolate* isolate,
                                             v8::Local<v8::Context> context) {
  v8::Local<v8::Promise::Resolver> resolver =
      v8::Promise::Resolver::New(context).ToLocalChecked();
  resolver->Resolve(context, v8::Undefined(isolate)).FromMaybe(false);
  return resolver->GetPromise();
}

v8::Local<v8::Promise> CreateRejectedPromise(v8::Local<v8::Context> context,
                                             v8::Local<v8::Value> reason) {
  v8::Local<v8::Promise::Resolver> resolver =
      v8::Promise::Resolver::New(context).ToLocalChecked();
  resolver->Reject(context, reason).FromMaybe(false);
  return resolver->GetPromise();
}

void MirrorFunctionOnGlobalThis(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                const char* name) {
  std::string src =
      "if (typeof globalThis !== 'undefined' && typeof globalThis." +
      std::string(name) +
      " !== 'function') {"
      "  Object.defineProperty(globalThis, '" + std::string(name) +
      "', { value: this." + std::string(name) +
      ", writable: true, configurable: true, enumerable: false });"
      "}";

  v8::Local<v8::Script> script;
  if (v8::Script::Compile(context, tns::ToV8String(isolate, src.c_str()))
          .ToLocal(&script)) {
    script->Run(context).FromMaybe(v8::Local<v8::Value>());
  }
}

static bool GetOptionalBooleanProperty(v8::Isolate* isolate, v8::Local<v8::Context> context,
                                       v8::Local<v8::Object> object, const char* key,
                                       bool* out) {
  if (out == nullptr) return false;

  v8::Local<v8::Value> value;
  if (!object->Get(context, tns::ToV8String(isolate, key)).ToLocal(&value) ||
      value->IsUndefined() || value->IsNull()) {
    return false;
  }

  *out = value->BooleanValue(isolate);
  return true;
}

static void SetBooleanGlobal(v8::Isolate* isolate, v8::Local<v8::Context> context,
                             const char* key, bool value) {
  context->Global()
      ->Set(context, tns::ToV8String(isolate, key), v8::Boolean::New(isolate, value))
      .FromMaybe(false);
}

static void SetStringGlobal(v8::Isolate* isolate, v8::Local<v8::Context> context,
                            const char* key, const std::string& value) {
  context->Global()
      ->Set(context, tns::ToV8String(isolate, key),
            tns::ToV8String(isolate, value.c_str()))
      .FromMaybe(false);
}

static bool IsSupportedDevSessionPlatform(const std::string& platform) {
  return platform == "ios" || platform == "visionos";
}

static bool ApplyDevRuntimeConfigDictionary(NSDictionary* payload,
                                            std::string* errorMessage) {
  if (payload == nil || ![payload isKindOfClass:[NSDictionary class]]) {
    if (errorMessage != nullptr) {
      *errorMessage = "[__nsStartDevSession] runtime config payload must be an object";
    }
    return false;
  }

  id importMapValue = [payload objectForKey:@"importMap"];
  if (importMapValue == nil || ![importMapValue isKindOfClass:[NSDictionary class]]) {
    if (errorMessage != nullptr) {
      *errorMessage = "[__nsStartDevSession] runtime config payload is missing importMap";
    }
    return false;
  }

  NSError* importMapError = nil;
  NSData* importMapData =
      [NSJSONSerialization dataWithJSONObject:importMapValue options:0 error:&importMapError];
  if (importMapData == nil || importMapError != nil) {
    if (errorMessage != nullptr) {
      NSString* detail = importMapError.localizedDescription ?: @"unknown importMap serialization error";
      *errorMessage = std::string("[__nsStartDevSession] failed to serialize importMap: ") +
                      std::string([detail UTF8String] ?: "unknown importMap serialization error");
    }
    return false;
  }

  const void* importMapBytes = [importMapData bytes];
  NSUInteger importMapLength = [importMapData length];
  if (importMapBytes == nullptr || importMapLength == 0) {
    if (errorMessage != nullptr) {
      *errorMessage = "[__nsStartDevSession] runtime config importMap was empty";
    }
    return false;
  }

  std::string importMapJson(static_cast<const char*>(importMapBytes),
                            static_cast<size_t>(importMapLength));
  SetImportMap(importMapJson);

  std::vector<std::string> patterns;
  id volatilePatternsValue = [payload objectForKey:@"volatilePatterns"];
  if ([volatilePatternsValue isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray*)volatilePatternsValue) {
      if (![value isKindOfClass:[NSString class]]) {
        continue;
      }
      const char* utf8 = [(NSString*)value UTF8String];
      if (utf8 != nullptr && utf8[0] != '\0') {
        patterns.emplace_back(utf8);
      }
    }
  }

  if (!patterns.empty()) {
    SetVolatilePatterns(patterns);
  }

  return true;
}

v8::Local<v8::Object> GetOrCreateHotData(v8::Isolate* isolate, const std::string& key) {
  auto it = g_hotData.find(key);
  if (it != g_hotData.end()) {
    if (!it->second.IsEmpty()) {
      return it->second.Get(isolate);
    }
  }
  v8::Local<v8::Object> obj = v8::Object::New(isolate);
  g_hotData[key].Reset(isolate, obj);
  return obj;
}

bool ReadDevSessionConfig(v8::Isolate* isolate, v8::Local<v8::Context> context,
                          v8::Local<v8::Object> config, DevSessionState* out,
                          std::string* errorMessage) {
  if (out == nullptr) {
    if (errorMessage != nullptr) {
      *errorMessage = "[__nsStartDevSession] output session state is required";
    }
    return false;
  }

  DevSessionState next;
  next.active = true;
  GetOptionalStringProperty(isolate, context, config, "sessionId", &next.sessionId);
  GetOptionalStringProperty(isolate, context, config, "origin", &next.origin);
  GetOptionalStringProperty(isolate, context, config, "entryUrl", &next.entryUrl);
  GetOptionalStringProperty(isolate, context, config, "clientUrl", &next.clientUrl);
  GetOptionalStringProperty(isolate, context, config, "wsUrl", &next.wsUrl);
  GetOptionalStringProperty(isolate, context, config, "platform", &next.platform);
  GetOptionalStringProperty(isolate, context, config, "runtimeConfigUrl", &next.runtimeConfigUrl);

  v8::Local<v8::Value> featuresValue;
  if (config->Get(context, tns::ToV8String(isolate, "features"))
          .ToLocal(&featuresValue) &&
      featuresValue->IsObject()) {
    v8::Local<v8::Object> features = featuresValue.As<v8::Object>();
    GetOptionalBooleanProperty(isolate, context, features, "fullReload",
                               &next.fullReload);
    GetOptionalBooleanProperty(isolate, context, features, "cssHmr",
                               &next.cssHmr);
  }

  if (next.sessionId.empty() || next.origin.empty() || next.entryUrl.empty() ||
      next.clientUrl.empty() || next.wsUrl.empty() || next.platform.empty()) {
    if (errorMessage != nullptr) {
      *errorMessage =
          "[__nsStartDevSession] sessionId, origin, clientUrl, wsUrl, entryUrl, and platform are required";
    }
    return false;
  }

  if (!IsSupportedDevSessionPlatform(next.platform)) {
    if (errorMessage != nullptr) {
      *errorMessage =
          "[__nsStartDevSession] platform must be ios or visionos";
    }
    return false;
  }

  *out = next;
  return true;
}

void ResetActiveDevSession() {
  std::lock_guard<std::mutex> lock(g_activeDevSessionMutex);
  if (IsScriptLoadingLogEnabled() && g_activeDevSession.active) {
    Log(@"[dev-session] reset active session=%s started=%s",
        g_activeDevSession.sessionId.c_str(),
        g_activeDevSession.started ? "true" : "false");
  }
  g_activeDevSession = DevSessionState();
}

DevSessionState GetActiveDevSessionSnapshot() {
  std::lock_guard<std::mutex> lock(g_activeDevSessionMutex);
  return g_activeDevSession;
}

void StoreActiveDevSession(const DevSessionState& session) {
  std::lock_guard<std::mutex> lock(g_activeDevSessionMutex);
  g_activeDevSession = session;
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-session] stored session=%s started=%s origin=%s client=%s entry=%s",
        session.sessionId.c_str(), session.started ? "true" : "false",
        session.origin.c_str(), session.clientUrl.c_str(),
        session.entryUrl.c_str());
  }
}

bool HasDevSessionChanged(const DevSessionState& previous,
                          const DevSessionState& next) {
  return !previous.active || previous.sessionId != next.sessionId ||
         previous.origin != next.origin || previous.entryUrl != next.entryUrl ||
    previous.clientUrl != next.clientUrl || previous.wsUrl != next.wsUrl ||
    previous.runtimeConfigUrl != next.runtimeConfigUrl;
}

std::vector<std::string> CollectSessionModuleUrls(const DevSessionState& session) {
  std::vector<std::string> invalidate;
  if (!session.active || session.origin.empty()) {
    return invalidate;
  }

  for (const auto& url : tns::GetLoadedModuleUrls()) {
    if (!StartsWith(url, session.origin.c_str())) continue;
    if (!session.clientUrl.empty() && url == session.clientUrl) continue;
    invalidate.push_back(url);
  }

  return invalidate;
}

bool ApplyDevRuntimeConfigFromUrl(const std::string& url,
                                  std::string* errorMessage) {
  if (url.empty()) {
    return true;
  }

  std::string body;
  std::string contentType;
  int status = 0;
  if (!HttpFetchText(url, body, contentType, status) || body.empty()) {
    if (errorMessage != nullptr) {
      *errorMessage = std::string("[__nsStartDevSession] failed to fetch runtimeConfigUrl: ") + url;
    }
    return false;
  }

  @autoreleasepool {
    NSData* jsonData = [NSData dataWithBytes:body.data() length:body.size()];
    if (jsonData == nil) {
      if (errorMessage != nullptr) {
        *errorMessage = "[__nsStartDevSession] failed to create runtime config data";
      }
      return false;
    }

    NSError* jsonError = nil;
    id payload = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&jsonError];
    if (payload == nil || ![payload isKindOfClass:[NSDictionary class]]) {
      if (errorMessage != nullptr) {
        NSString* detail = jsonError.localizedDescription ?: @"unknown runtime config parse error";
        *errorMessage = std::string("[__nsStartDevSession] failed to parse runtime config: ") +
                        std::string([detail UTF8String] ?: "unknown runtime config parse error");
      }
      return false;
    }

    if (!ApplyDevRuntimeConfigDictionary((NSDictionary*)payload, errorMessage)) {
      return false;
    }
  }

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-session] runtime config applied url=%s", url.c_str());
  }

  return true;
}

// Native-side mirror of `__NS_HMR_BOOT_COMPLETE__`. Read by the
// runloop pump in `MaybePumpJSThreadDuringBoot` so its gate is a
// single relaxed atomic load on the HMR-time hot path.
static std::atomic<bool> g_devSessionBootComplete{false};

static inline bool IsDevSessionBootComplete() {
  return g_devSessionBootComplete.load(std::memory_order_relaxed);
}

void ApplyDevSessionGlobals(v8::Isolate* isolate,
                            v8::Local<v8::Context> context,
                            const DevSessionState& session) {
  SetStringGlobal(isolate, context, "__NS_HTTP_ORIGIN__", session.origin);
  SetStringGlobal(isolate, context, "__NS_HMR_WS_URL__", session.wsUrl);
  SetBooleanGlobal(isolate, context, "__NS_HMR_BOOT_COMPLETE__", false);
  SetBooleanGlobal(isolate, context, "__NS_HMR_CLIENT_ACTIVE__", false);
  SetBooleanGlobal(isolate, context, "__NS_HMR_BROWSER_RUNTIME_CLIENT_ACTIVE__", false);
  g_devSessionBootComplete.store(false, std::memory_order_relaxed);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-session] globals applied session=%s origin=%s ws=%s bootComplete=false",
        session.sessionId.c_str(), session.origin.c_str(),
        session.wsUrl.c_str());
  }
}

void SetDevSessionBootComplete(v8::Isolate* isolate,
                               v8::Local<v8::Context> context,
                               bool value) {
  SetBooleanGlobal(isolate, context, "__NS_HMR_BOOT_COMPLETE__", value);
  g_devSessionBootComplete.store(value, std::memory_order_relaxed);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-session] __NS_HMR_BOOT_COMPLETE__=%s",
        value ? "true" : "false");
  }
}

void RegisterHotAccept(v8::Isolate* isolate, const std::string& key, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  g_hotAccept[key].emplace_back(v8::Global<v8::Function>(isolate, cb));
}

void RegisterHotDispose(v8::Isolate* isolate, const std::string& key, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  g_hotDispose[key].emplace_back(v8::Global<v8::Function>(isolate, cb));
}

void RegisterHotPrune(v8::Isolate* isolate, const std::string& key, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  g_hotPrune[key].emplace_back(v8::Global<v8::Function>(isolate, cb));
}

std::vector<v8::Local<v8::Function>> GetHotAcceptCallbacks(v8::Isolate* isolate, const std::string& key) {
  std::vector<v8::Local<v8::Function>> out;
  auto it = g_hotAccept.find(key);
  if (it != g_hotAccept.end()) {
    for (auto& gfn : it->second) {
      if (!gfn.IsEmpty()) out.push_back(gfn.Get(isolate));
    }
  }
  return out;
}

std::vector<v8::Local<v8::Function>> GetHotDisposeCallbacks(v8::Isolate* isolate, const std::string& key) {
  std::vector<v8::Local<v8::Function>> out;
  auto it = g_hotDispose.find(key);
  if (it != g_hotDispose.end()) {
    for (auto& gfn : it->second) {
      if (!gfn.IsEmpty()) out.push_back(gfn.Get(isolate));
    }
  }
  return out;
}

std::vector<v8::Local<v8::Function>> GetHotPruneCallbacks(v8::Isolate* isolate, const std::string& key) {
  std::vector<v8::Local<v8::Function>> out;
  auto it = g_hotPrune.find(key);
  if (it != g_hotPrune.end()) {
    for (auto& gfn : it->second) {
      if (!gfn.IsEmpty()) out.push_back(gfn.Get(isolate));
    }
  }
  return out;
}

void RegisterHotEventListener(v8::Isolate* isolate, const std::string& event, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  g_hotEventListeners[event].emplace_back(v8::Global<v8::Function>(isolate, cb));
}

void RemoveHotEventListener(v8::Isolate* isolate, const std::string& event, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  auto it = g_hotEventListeners.find(event);
  if (it == g_hotEventListeners.end()) return;
  auto& listeners = it->second;
  // V8 strict equality — same Function reference. A user that registered
  // the same closure twice gets BOTH copies removed; matches
  // `EventTarget.removeEventListener` semantics for repeated registrations.
  for (auto i = listeners.begin(); i != listeners.end();) {
    if (!i->IsEmpty() && i->Get(isolate) == cb) {
      i->Reset();
      i = listeners.erase(i);
    } else {
      ++i;
    }
  }
  if (listeners.empty()) {
    g_hotEventListeners.erase(it);
  }
}

void MarkHotDeclined(const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(g_hotDeclinedMutex);
  g_hotDeclined.insert(key);
}

bool IsHotDeclined(const std::string& key) {
  if (key.empty()) return false;
  std::lock_guard<std::mutex> lock(g_hotDeclinedMutex);
  return g_hotDeclined.find(key) != g_hotDeclined.end();
}

bool IsAnyModuleDeclined(const std::vector<std::string>& keys) {
  std::lock_guard<std::mutex> lock(g_hotDeclinedMutex);
  if (g_hotDeclined.empty()) return false;
  if (keys.empty()) {
    // "Is anything declined?" — yes if the set is non-empty (already
    // checked above).
    return true;
  }
  for (const auto& k : keys) {
    if (g_hotDeclined.find(k) != g_hotDeclined.end()) return true;
  }
  return false;
}

std::vector<v8::Local<v8::Function>> GetHotEventListeners(v8::Isolate* isolate, const std::string& event) {
  std::vector<v8::Local<v8::Function>> out;
  auto it = g_hotEventListeners.find(event);
  if (it != g_hotEventListeners.end()) {
    for (auto& gfn : it->second) {
      if (!gfn.IsEmpty()) out.push_back(gfn.Get(isolate));
    }
  }
  return out;
}

void DispatchHotEvent(v8::Isolate* isolate, v8::Local<v8::Context> context, const std::string& event, v8::Local<v8::Value> data) {
  auto callbacks = GetHotEventListeners(isolate, event);
  const bool verbose = tns::IsScriptLoadingLogEnabled();

  // Single dispatch loop. Always observes `tryCatch.HasCaught()` and
  // `result.ToLocal(...)` regardless of verbose mode, mirroring the
  // dispose/prune drainer (`DrainHotCallbacks`) and the original
  // pre-session `DispatchHotEvent` behavior. A previous variant that
  // skipped these observations on the quiet path broke HMR dispatch even
  // though `~TryCatch` resets state on destruction; treat the observation
  // pattern as the contract.
  //
  // All `Log()` calls are gated behind `verbose` so default-mode dev
  // sessions are quiet; the per-listener int counters are practically
  // free and feed the verbose-only summary line. Reproducing the verbose
  // output requires `logScriptLoading: true` in `nativescript.config.ts`.
  // The summary collapses "did any listener match?" into one line — the
  // single most informative signal when triaging HMR dispatch.
  int matched = 0;   // returned undefined OR a truthy non-bool (Promise/object)
  int falsey = 0;    // returned literal `false`
  int threw = 0;     // listener threw synchronously
  int idx = 0;
  for (auto& cb : callbacks) {
    v8::TryCatch tryCatch(isolate);
    v8::Local<v8::Value> args[] = { data };
    v8::MaybeLocal<v8::Value> result = cb->Call(context, v8::Undefined(isolate), 1, args);
    if (tryCatch.HasCaught()) {
      threw++;
      if (verbose) {
        v8::Local<v8::Value> ex = tryCatch.Exception();
        v8::String::Utf8Value m(isolate, ex);
        Log(@"[import.meta.hot] Listener #%d for '%s' threw: %s", idx, event.c_str(), *m ? *m : "(unknown)");
      }
    } else {
      v8::Local<v8::Value> ret;
      if (result.ToLocal(&ret)) {
        if (ret->IsBoolean() && !ret->BooleanValue(isolate)) {
          falsey++;
        } else {
          matched++;
          if (verbose && !ret->IsUndefined()) {
            v8::String::Utf8Value rstr(isolate, ret);
            std::string s = *rstr ? *rstr : "(unknown)";
            Log(@"[import.meta.hot] Listener #%d for '%s' returned: %s", idx, event.c_str(), s.c_str());
          }
        }
      }
    }
    idx++;
  }
  if (verbose) {
    Log(@"[import.meta.hot] dispatch summary event='%s' total=%d matched=%d falsey=%d threw=%d",
        event.c_str(), (int)callbacks.size(), matched, falsey, threw);
  }
}

void InitializeHotEventDispatcher(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Value;

  // Create a global function __NS_DISPATCH_HOT_EVENT__(event, data)
  // that the HMR client can call to dispatch events to registered listeners.
  // Returns the number of listeners that were invoked so callers can detect
  // "no-listener" scenarios (which would otherwise look identical to a
  // successful dispatch from the JS side).
  auto dispatchCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();
    
    if (info.Length() < 1 || !info[0]->IsString()) {
      info.GetReturnValue().Set(v8::Integer::New(iso, -1));
      return;
    }
    
    v8::String::Utf8Value eventName(iso, info[0]);
    std::string event = *eventName ? *eventName : "";
    if (event.empty()) {
      info.GetReturnValue().Set(v8::Integer::New(iso, -1));
      return;
    }
    
    v8::Local<Value> data = info.Length() > 1 ? info[1] : v8::Undefined(iso).As<Value>();

    auto callbacks = GetHotEventListeners(iso, event);

    if (tns::IsScriptLoadingLogEnabled()) {
      Log(@"[import.meta.hot] Dispatching event '%s' to %d listener(s)", event.c_str(), (int)callbacks.size());
    }
    
    DispatchHotEvent(iso, ctx, event, data);
    info.GetReturnValue().Set(v8::Integer::New(iso, (int)callbacks.size()));
  };

  // __nsListHotEventListeners() — returns an object mapping every registered
  // event name to its current listener count. Diagnostic helper for HMR
  // dispatch issues so JS code can verify whether a given event has any
  // listeners attached at the time of dispatch (the typical failure mode is
  // a custom event being dispatched before the user's compiled component
  // module has executed its `import.meta.hot.on(...)` registration).
  auto listCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();
    v8::Local<v8::Object> result = v8::Object::New(iso);
    for (const auto& kv : g_hotEventListeners) {
      v8::Local<v8::String> name = tns::ToV8String(iso, kv.first.c_str());
      v8::Local<v8::Integer> count = v8::Integer::New(iso, (int)kv.second.size());
      (void)result->CreateDataProperty(ctx, name, count);
    }
    info.GetReturnValue().Set(result);
  };
  
  v8::Local<v8::Object> global = context->Global();
  v8::Local<v8::Function> dispatchFn = v8::Function::New(context, dispatchCb).ToLocalChecked();
  global->CreateDataProperty(context, tns::ToV8String(isolate, "__NS_DISPATCH_HOT_EVENT__"), dispatchFn).Check();
  v8::Local<v8::Function> listFn = v8::Function::New(context, listCb).ToLocalChecked();
  global->CreateDataProperty(context, tns::ToV8String(isolate, "__nsListHotEventListeners"), listFn).Check();
}

namespace {

// Shared drainer for the dispose/prune twin runners. Both have identical
// snapshot-and-swap semantics (re-entrancy safety, mid-drain
// re-registration, per-callback try/catch with a script-loading log); the
// only things that differ between them are the registry map they touch
// and the log tag. Extracting the common body keeps any future fix to
// the drain protocol from drifting between the two paths.
//
// `registry` is taken by reference so the caller's file-static map is
// mutated in place.
int DrainHotCallbacks(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    const std::vector<std::string>& keys,
    std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>>& registry,
    const char* logTag) {
  using v8::Function;
  using v8::Global;
  using v8::HandleScope;
  using v8::Local;
  using v8::Object;
  using v8::TryCatch;
  using v8::Value;

  // Snapshot the keys we'll drain so callers passing an empty list get
  // every registered module. We snapshot first (rather than iterating the
  // map directly) so the registry can be safely mutated mid-drain — both
  // when we erase entries below, and if a callback itself registers a
  // new dispose/prune for the same module (legal per Vite spec; lets
  // users implement hot-data persistence and re-arm side effects).
  std::vector<std::string> targetKeys;
  if (keys.empty()) {
    targetKeys.reserve(registry.size());
    for (const auto& kv : registry) {
      targetKeys.push_back(kv.first);
    }
  } else {
    targetKeys = keys;
  }

  if (targetKeys.empty()) return 0;

  HandleScope handleScope(isolate);
  int executed = 0;

  for (const auto& key : targetKeys) {
    auto it = registry.find(key);
    if (it == registry.end() || it->second.empty()) continue;

    // Move callbacks out of the registry BEFORE invoking. This prevents:
    //   * Re-entrant drain calls from re-firing the same callbacks.
    //   * Callbacks that re-register on the same module from racing with
    //     our iteration — their newly-registered cb lands in the
    //     now-empty bucket and survives until the next drain (the
    //     correct Vite-spec behaviour for a module that re-installs
    //     side-effects after running cleanup).
    std::vector<Global<Function>> callbacks;
    callbacks.swap(it->second);
    registry.erase(it);

    // The user-visible callback signature is `(data) => void`. Pass the
    // module's `hot.data` so users can stash state across the reload —
    // matches Vite's contract documented at:
    //   https://vite.dev/guide/api-hmr#hot-dispose-cb
    //   https://vite.dev/guide/api-hmr#hot-prune-cb
    Local<Object> data = GetOrCreateHotData(isolate, key);
    Local<Value> args[] = { data };

    for (auto& gfn : callbacks) {
      if (gfn.IsEmpty()) continue;
      Local<Function> cb = gfn.Get(isolate);
      if (cb.IsEmpty()) continue;

      TryCatch tryCatch(isolate);
      v8::MaybeLocal<Value> result = cb->Call(context, v8::Undefined(isolate), 1, args);
      (void)result;
      if (tryCatch.HasCaught()) {
        // One bad callback must NEVER take down the HMR cycle for
        // everyone else. Log under the existing script-loading flag so
        // the user has a way to enable diagnostic visibility without
        // recompiling, and continue.
        if (tns::IsScriptLoadingLogEnabled()) {
          Local<Value> ex = tryCatch.Exception();
          v8::String::Utf8Value msg(isolate, ex);
          Log(@"%s callback threw for key=%s: %s",
              logTag, key.c_str(), *msg ? *msg : "(unknown)");
        }
        // Don't ReThrow — swallow per-callback failures so subsequent
        // drains (and the reboot itself) still run.
        continue;
      }
      ++executed;
    }
  }

  return executed;
}

}  // namespace

int RunHotDisposeCallbacks(v8::Isolate* isolate, v8::Local<v8::Context> context,
                           const std::vector<std::string>& keys) {
  return DrainHotCallbacks(isolate, context, keys, g_hotDispose,
                           "[import.meta.hot.dispose]");
}

void InitializeHotDisposeRunner(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Value;

  // Global JS-callable: `__nsRunHmrDispose(keys?: string[]) => number`.
  // Mirrors `InitializeHotEventDispatcher`'s exposure pattern. HMR clients
  // that perform whole-realm reboots (e.g. @nativescript/vite's) call this
  // to drain `import.meta.hot.dispose` callbacks immediately before
  // re-importing the application entry.
  //
  // The `keys` argument lets per-module HMR clients drain only specific
  // modules. Omitting it drains everything — the right semantics for a
  // wholesale reboot, where the entire JS realm's side-effect tree is
  // being torn down.
  auto runDisposeCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();

    std::vector<std::string> keys;
    if (info.Length() >= 1 && info[0]->IsArray()) {
      v8::Local<v8::Array> arr = info[0].As<v8::Array>();
      uint32_t length = arr->Length();
      keys.reserve(length);
      for (uint32_t i = 0; i < length; ++i) {
        v8::Local<Value> entry;
        if (!arr->Get(ctx, i).ToLocal(&entry)) continue;
        if (!entry->IsString()) continue;
        v8::String::Utf8Value s(iso, entry);
        if (*s) keys.emplace_back(*s);
      }
    }
    // info[0] is null/undefined/missing/non-array → empty `keys` → drain all.

    int executed = RunHotDisposeCallbacks(iso, ctx, keys);
    info.GetReturnValue().Set(static_cast<int32_t>(executed));
  };

  v8::Local<v8::Object> global = context->Global();
  v8::Local<v8::Function> fn = v8::Function::New(context, runDisposeCb).ToLocalChecked();
  global->CreateDataProperty(context,
                             tns::ToV8String(isolate, "__nsRunHmrDispose"),
                             fn).Check();
}

int RunHotPruneCallbacks(v8::Isolate* isolate, v8::Local<v8::Context> context,
                         const std::vector<std::string>& keys) {
  return DrainHotCallbacks(isolate, context, keys, g_hotPrune,
                           "[import.meta.hot.prune]");
}

void InitializeHotPruneRunner(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Value;

  // Global JS-callable: `__nsRunHmrPrune(keys?: string[]) => number`.
  // Symmetric with `__nsRunHmrDispose`. Clients with per-module update
  // models call this when modules leave the import graph; wholesale-reboot
  // clients have no prune step. Plumbed end-to-end so the entry point is
  // ready for either model.
  auto runPruneCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();

    std::vector<std::string> keys;
    if (info.Length() >= 1 && info[0]->IsArray()) {
      v8::Local<v8::Array> arr = info[0].As<v8::Array>();
      uint32_t length = arr->Length();
      keys.reserve(length);
      for (uint32_t i = 0; i < length; ++i) {
        v8::Local<Value> entry;
        if (!arr->Get(ctx, i).ToLocal(&entry)) continue;
        if (!entry->IsString()) continue;
        v8::String::Utf8Value s(iso, entry);
        if (*s) keys.emplace_back(*s);
      }
    }

    int executed = RunHotPruneCallbacks(iso, ctx, keys);
    info.GetReturnValue().Set(static_cast<int32_t>(executed));
  };

  v8::Local<v8::Object> global = context->Global();
  v8::Local<v8::Function> fn = v8::Function::New(context, runPruneCb).ToLocalChecked();
  global->CreateDataProperty(context,
                             tns::ToV8String(isolate, "__nsRunHmrPrune"),
                             fn).Check();
}

void InitializeHotDeclinedHelper(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Value;

  // Global JS-callable: `__nsHasDeclinedModule(keys?: string[]) => boolean`.
  // HMR clients pass the update's eviction set here before applying an
  // update; on `true` they fall back to a full reload via `__nsReloadDevApp`
  // instead of the per-cycle reboot.
  //
  // No-arg form ("is anything declined at all?") returns `true` if any
  // module ever called `import.meta.hot.decline()`. Useful as a coarse
  // pre-check: if the answer is `false` the client can skip the more
  // expensive per-key check below.
  auto hasDeclinedCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();

    std::vector<std::string> keys;
    if (info.Length() >= 1 && info[0]->IsArray()) {
      v8::Local<v8::Array> arr = info[0].As<v8::Array>();
      uint32_t length = arr->Length();
      keys.reserve(length);
      for (uint32_t i = 0; i < length; ++i) {
        v8::Local<Value> entry;
        if (!arr->Get(ctx, i).ToLocal(&entry)) continue;
        if (!entry->IsString()) continue;
        v8::String::Utf8Value s(iso, entry);
        if (*s) keys.emplace_back(*s);
      }
    }

    bool declined = IsAnyModuleDeclined(keys);
    info.GetReturnValue().Set(declined);
  };

  v8::Local<v8::Object> global = context->Global();
  v8::Local<v8::Function> fn = v8::Function::New(context, hasDeclinedCb).ToLocalChecked();
  global->CreateDataProperty(context,
                             tns::ToV8String(isolate, "__nsHasDeclinedModule"),
                             fn).Check();
}

void InitializeImportMetaHot(v8::Isolate* isolate,
                             v8::Local<v8::Context> context,
                             v8::Local<v8::Object> importMeta,
                             const std::string& modulePath) {
  using v8::Function;
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Object;
  using v8::String;
  using v8::Value;

  // Ensure context scope for property creation
  v8::HandleScope scope(isolate);

  // Canonicalize key to ensure per-module hot.data persists across HMR URLs.
  // Important: this must NOT affect the HTTP loader cache key; otherwise HMR fetches
  // can collapse onto an already-evaluated module and no update occurs.
  auto canonicalHotKey = [&](const std::string& in) -> std::string {
    // Unwrap file://http(s)://...
    std::string s = in;
    if (StartsWith(s, "file://http://") || StartsWith(s, "file://https://")) {
      s = s.substr(strlen("file://"));
    }

    const bool isHttpUrl = StartsWith(s, "http://") || StartsWith(s, "https://");
    if (isHttpUrl) {
      // Preserve meaningful dev-endpoint query identity (for example /ns/core?p=...)
      // while still dropping cache-busters and canonicalizing versioned bridge URLs.
      s = CanonicalizeHttpUrlKey(s);
    }

    // Drop fragment
    size_t hashPos = s.find('#');
    if (hashPos != std::string::npos) s = s.substr(0, hashPos);

    std::string noQuery = s;
    std::string suffix;
    if (!isHttpUrl) {
      size_t qPos = s.find('?');
      noQuery = (qPos == std::string::npos) ? s : s.substr(0, qPos);
    }

    // If it's an http(s) URL, normalize only the path portion below.
    size_t schemePos = noQuery.find("://");
    size_t pathStart = (schemePos == std::string::npos) ? 0 : noQuery.find('/', schemePos + 3);
    if (pathStart == std::string::npos) {
      // No path; return without query
      return noQuery;
    }

    std::string origin = noQuery.substr(0, pathStart);
    std::string pathAndSuffix = noQuery.substr(pathStart);
    if (isHttpUrl) {
      size_t qPos = pathAndSuffix.find('?');
      if (qPos != std::string::npos) {
        suffix = pathAndSuffix.substr(qPos);
        pathAndSuffix = pathAndSuffix.substr(0, qPos);
      }
    }
    std::string path = pathAndSuffix;

    // Normalize NS HMR virtual module paths:
    // /ns/m/__ns_hmr__/<token>/<rest> -> /ns/m/<rest>
    auto normalizeHmrVirtualPath = [&](const char* prefix) {
      size_t prefixLen = strlen(prefix);
      if (path.compare(0, prefixLen, prefix) != 0) {
        return false;
      }

      size_t nextSlash = path.find('/', prefixLen);
      if (nextSlash == std::string::npos) {
        return false;
      }

      path = std::string("/ns/m/") + path.substr(nextSlash + 1);
      return true;
    };

    // Keep import.meta.hot.data stable across both live-tagged and boot-tagged HMR URLs.
    if (!normalizeHmrVirtualPath("/ns/m/__ns_boot__/b1/__ns_hmr__/")) {
      normalizeHmrVirtualPath("/ns/m/__ns_hmr__/");
    }

    auto normalizeBridge = [&](const char* needle) {
      size_t nlen = strlen(needle);
      if (path.compare(0, nlen, needle) != 0) return;
      if (path.size() == nlen) return;
      if (path.size() <= nlen + 1 || path[nlen] != '/') return;

      size_t i = nlen + 1;
      size_t j = i;
      while (j < path.size() && std::isdigit(static_cast<unsigned char>(path[j]))) {
        j++;
      }
      if (j == i) return;
      if (j != path.size()) return;

      path = std::string(needle);
    };

    normalizeBridge("/ns/rt");
    normalizeBridge("/ns/core");

    // Normalize common script extensions so `/foo` and `/foo.ts` share hot.data.
    const char* exts[] = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"};
    for (auto ext : exts) {
      if (EndsWith(path, ext)) {
        path = path.substr(0, path.size() - strlen(ext));
        break;
      }
    }

    // Also drop `.vue`? No — SFC endpoints should stay distinct.
    return origin + path + suffix;
  };

  const std::string key = canonicalHotKey(modulePath);
  if (tns::IsScriptLoadingLogEnabled()) {
    bool isReload = (g_hotData.find(key) != g_hotData.end());
    Log(@"[hmr][import.meta.hot] module=%s key=%s isReload=%d", modulePath.c_str(), key.c_str(), isReload);
  }

  // Helper to capture key in function data
  auto makeKeyData = [&](const std::string& k) -> Local<Value> {
    return tns::ToV8String(isolate, k.c_str());
  };

  // accept([deps], cb?) — we register cb if provided; deps ignored for now
  auto acceptCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    Local<Value> data = info.Data();
    std::string key;
    if (!data.IsEmpty()) {
      v8::String::Utf8Value s(iso, data);
      key = *s ? *s : "";
    }
    v8::Local<v8::Function> cb;
    if (info.Length() >= 1 && info[0]->IsFunction()) {
      cb = info[0].As<v8::Function>();
    } else if (info.Length() >= 2 && info[1]->IsFunction()) {
      cb = info[1].As<v8::Function>();
    }
    if (!cb.IsEmpty()) {
      RegisterHotAccept(iso, key, cb);
    }
    // Return undefined
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // dispose(cb) — register disposer
  auto disposeCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    Local<Value> data = info.Data();
    std::string key;
    if (!data.IsEmpty()) { v8::String::Utf8Value s(iso, data); key = *s ? *s : ""; }
    if (info.Length() >= 1 && info[0]->IsFunction()) {
      RegisterHotDispose(iso, key, info[0].As<v8::Function>());
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // prune(cb) — register a callback that fires when this module is removed
  // from the dep graph (NOT on every replacement — that's `dispose`). Today
  // the NS HMR pipeline does wholesale reboots so prune callbacks rarely
  // fire, but the registry is plumbed end-to-end so a future per-module
  // HMR client can drain `g_hotPrune` via `__nsRunHmrPrune`.
  auto pruneCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    Local<Value> data = info.Data();
    std::string key;
    if (!data.IsEmpty()) { v8::String::Utf8Value s(iso, data); key = *s ? *s : ""; }
    if (info.Length() >= 1 && info[0]->IsFunction()) {
      RegisterHotPrune(iso, key, info[0].As<v8::Function>());
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // decline() — mark this module as not hot-updateable (Vite spec). Adds the
  // canonical key to `g_hotDeclined`; the HMR client checks this set via
  // `__nsHasDeclinedModule(updatedKeys)` before applying an update and
  // converts the cycle into a full reload (`__nsReloadDevApp`) on a hit.
  auto declineCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    Local<Value> data = info.Data();
    std::string key;
    if (!data.IsEmpty()) { v8::String::Utf8Value s(iso, data); key = *s ? *s : ""; }
    if (!key.empty()) {
      MarkHotDeclined(key);
      if (tns::IsScriptLoadingLogEnabled()) {
        Log(@"[import.meta.hot.decline] key=%s", key.c_str());
      }
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // invalidate(message?) — request a full app reload. Per Vite spec this
  // notifies the dev server; in NS we short-circuit to the runtime's
  // `__nsReloadDevApp` global (which already does the right invalidate +
  // re-import dance). The optional `message` argument is logged for the
  // common Analog HMR fallback case (`'Component HMR failed, reloading'`),
  // which used to silently no-op.
  //
  // We invoke `__nsReloadDevApp` from a microtask so the user's current
  // execution stack (which contains the `invalidate()` call site) finishes
  // before the runtime tears down for reload — calling synchronously would
  // try to re-bootstrap from inside an in-flight callback.
  auto invalidateCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    Local<Value> data = info.Data();
    std::string key;
    if (!data.IsEmpty()) { v8::String::Utf8Value s(iso, data); key = *s ? *s : ""; }

    std::string message;
    if (info.Length() >= 1 && info[0]->IsString()) {
      v8::String::Utf8Value m(iso, info[0]);
      if (*m) message = *m;
    }
    if (tns::IsScriptLoadingLogEnabled()) {
      Log(@"[import.meta.hot.invalidate] key=%s message=%s",
          key.c_str(), message.empty() ? "(none)" : message.c_str());
    }

    v8::Local<v8::Context> ctx = iso->GetCurrentContext();
    v8::Local<v8::Object> global = ctx->Global();
    v8::Local<Value> reloadVal;
    if (!global->Get(ctx, tns::ToV8String(iso, "__nsReloadDevApp")).ToLocal(&reloadVal)) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    if (!reloadVal->IsFunction()) {
      // Older runtime / non-dev mode — silently no-op. Nothing else
      // we can usefully do here.
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }

    // Defer the call via a resolved-promise microtask so we exit the
    // current call stack before the reload tears the runtime down. Using
    // microtasks rather than `setTimeout` keeps the deferral inside the
    // same V8 microtask checkpoint — no event-loop delay, no UI hitch.
    v8::Local<v8::Function> reloadFn = reloadVal.As<v8::Function>();
    v8::Local<v8::Promise::Resolver> resolver;
    if (v8::Promise::Resolver::New(ctx).ToLocal(&resolver)) {
      v8::Local<v8::Function> deferred =
          v8::Function::New(ctx, [](const FunctionCallbackInfo<Value>& innerInfo) {
            v8::Isolate* innerIso = innerInfo.GetIsolate();
            v8::Local<v8::Context> innerCtx = innerIso->GetCurrentContext();
            v8::Local<v8::Object> innerGlobal = innerCtx->Global();
            v8::Local<Value> reloadVal;
            if (!innerGlobal->Get(innerCtx, tns::ToV8String(innerIso, "__nsReloadDevApp")).ToLocal(&reloadVal)) return;
            if (!reloadVal->IsFunction()) return;
            v8::Local<v8::Function> reloadFn = reloadVal.As<v8::Function>();
            v8::TryCatch tc(innerIso);
            (void)reloadFn->Call(innerCtx, v8::Undefined(innerIso), 0, nullptr);
            // Reload is a fire-and-forget Promise on its own. Per-call
            // failures aren't surfaced — they're not actionable from
            // user code.
          }).ToLocalChecked();
      v8::Local<v8::Promise> p = resolver->GetPromise();
      v8::MaybeLocal<v8::Promise> chained = p->Then(ctx, deferred);
      (void)chained;
      (void)resolver->Resolve(ctx, v8::Undefined(iso));
    } else {
      // Promise machinery unavailable — fall back to a synchronous call.
      // The user's current call stack will be torn down mid-execution
      // but the user already requested a full reload, so that's
      // acceptable.
      v8::TryCatch tc(iso);
      (void)reloadFn->Call(ctx, v8::Undefined(iso), 0, nullptr);
    }

    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // on(event, cb) — register custom event listener
  auto onCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    if (info.Length() < 2) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    if (!info[0]->IsString() || !info[1]->IsFunction()) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    v8::String::Utf8Value eventName(iso, info[0]);
    std::string event = *eventName ? *eventName : "";
    if (!event.empty()) {
      RegisterHotEventListener(iso, event, info[1].As<v8::Function>());
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // off(event, cb) — counterpart to `on`. Removes a previously-registered
  // listener (matched by V8 strict equality on the Function reference).
  auto offCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    if (info.Length() < 2) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    if (!info[0]->IsString() || !info[1]->IsFunction()) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    v8::String::Utf8Value eventName(iso, info[0]);
    std::string event = *eventName ? *eventName : "";
    if (!event.empty()) {
      RemoveHotEventListener(iso, event, info[1].As<v8::Function>());
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  // send(event, data) — send a custom message to the dev server. The runtime
  // intentionally does not own a WebSocket; it delegates to a JS-installed
  // `globalThis.__nsHmrSendToServer(event, data)` so the WebSocket-owning
  // JS layer (typically @nativescript/vite's HMR client) keeps sole
  // responsibility for transport. If no JS-side handler is installed (older
  // HMR clients, non-dev mode) this is a clean no-op.
  auto sendCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();
    v8::Local<v8::Object> global = ctx->Global();
    v8::Local<Value> handlerVal;
    if (!global->Get(ctx, tns::ToV8String(iso, "__nsHmrSendToServer")).ToLocal(&handlerVal)) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    if (!handlerVal->IsFunction()) {
      info.GetReturnValue().Set(v8::Undefined(iso));
      return;
    }
    v8::Local<v8::Function> handler = handlerVal.As<v8::Function>();

    // Forward `(event, data)` exactly as called. We don't enforce types on
    // `event` (Vite spec only specifies the first arg as a string but
    // implementations let it be coerced) and we pass `data` through
    // verbatim — JS-side serialization is the transport's concern.
    int argc = info.Length();
    if (argc > 2) argc = 2;
    std::vector<v8::Local<Value>> args;
    args.reserve(argc);
    for (int i = 0; i < argc; ++i) args.push_back(info[i]);

    v8::TryCatch tc(iso);
    (void)handler->Call(ctx, v8::Undefined(iso), argc, args.data());
    if (tc.HasCaught() && tns::IsScriptLoadingLogEnabled()) {
      v8::Local<Value> ex = tc.Exception();
      v8::String::Utf8Value m(iso, ex);
      Log(@"[import.meta.hot.send] handler threw: %s", *m ? *m : "(unknown)");
    }
    info.GetReturnValue().Set(v8::Undefined(iso));
  };

  Local<Object> hot = Object::New(isolate);
  // Stable flags
  hot->CreateDataProperty(context, tns::ToV8String(isolate, "data"),
                          GetOrCreateHotData(isolate, key)).Check();
  // Methods
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "accept"),
      v8::Function::New(context, acceptCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "dispose"),
      v8::Function::New(context, disposeCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "prune"),
      v8::Function::New(context, pruneCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "decline"),
      v8::Function::New(context, declineCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "invalidate"),
      v8::Function::New(context, invalidateCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "on"),
      v8::Function::New(context, onCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "off"),
      v8::Function::New(context, offCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "send"),
      v8::Function::New(context, sendCb, makeKeyData(key)).ToLocalChecked()).Check();

  // Attach to import.meta
  importMeta->CreateDataProperty(
    context, tns::ToV8String(isolate, "hot"),
    hot).Check();
}

// ─────────────────────────────────────────────────────────────
// HTTP loader helpers

std::string CanonicalizeHttpUrlKey(const std::string& url) {
  // Some loaders wrap HTTP module URLs as file://http(s)://...
  std::string normalizedUrl = url;
  if (StartsWith(normalizedUrl, "file://http://") || StartsWith(normalizedUrl, "file://https://")) {
    normalizedUrl = normalizedUrl.substr(strlen("file://"));
  }
  if (!(StartsWith(normalizedUrl, "http://") || StartsWith(normalizedUrl, "https://"))) {
    return normalizedUrl;
  }
  // Drop fragment entirely
  size_t hashPos = normalizedUrl.find('#');
  std::string noHash = (hashPos == std::string::npos) ? normalizedUrl : normalizedUrl.substr(0, hashPos);

  // Locate path start and query start
  size_t schemePos = noHash.find("://");
  if (schemePos == std::string::npos) {
    // Unexpected shape; fall back to removing whole query
    size_t q = noHash.find('?');
    return (q == std::string::npos) ? noHash : noHash.substr(0, q);
  }
  size_t pathStart = noHash.find('/', schemePos + 3);
  if (pathStart == std::string::npos) {
    // No path; nothing to normalize
    return noHash;
  }
  size_t qPos = noHash.find('?', pathStart);
  std::string originAndPath = (qPos == std::string::npos) ? noHash : noHash.substr(0, qPos);
  std::string query = (qPos == std::string::npos) ? std::string() : noHash.substr(qPos + 1);

  // Normalize bridge endpoints to keep a single realm across reloads:
  // - /ns/rt/<ver>    -> /ns/rt
  // - /ns/core/<ver>  -> /ns/core
  // Preserve query params (e.g. /ns/core?p=...), except for internal cache-busters (import, t, v), as part of module identity.
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    auto normalizeBridge = [&](const char* needle) {
      size_t nlen = strlen(needle);
      if (pathOnly.compare(0, nlen, needle) != 0) return;
      if (pathOnly.size() == nlen) return; // already canonical
      if (pathOnly.size() <= nlen + 1 || pathOnly[nlen] != '/') return;

      // Only normalize exact version segment: /ns/*/<digits> (no further segments)
      size_t i = nlen + 1;
      size_t j = i;
      while (j < pathOnly.size() && std::isdigit(static_cast<unsigned char>(pathOnly[j]))) {
        j++;
      }
      if (j == i) return;              // no digits
      if (j != pathOnly.size()) return; // has extra path

      originAndPath = originAndPath.substr(0, pathStart) + std::string(needle);
      pathOnly = originAndPath.substr(pathStart);
    };

    normalizeBridge("/ns/rt");
    normalizeBridge("/ns/core");
  }

  //
  // This block here is the runtime's
  // defense-in-depth layer: even if the server (or any future tooling)
  // emits a versioned or boot-tagged URL, the cache identity collapses to
  // the canonical `/ns/m/<rest>` shape so V8 deduplicates correctly.
  //
  // The prefixes are stripped in fixed order — boot first (it's a static
  // outermost wrapper), then hmr (one path segment whose tag may be
  // `v<digits>`, `n<digits>`, `live`, or any alphanumeric value emitted by
  // `formatNsMHmrServeTag`). The strip is idempotent: applying it twice
  // yields the same result as applying it once.
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    bool changed = false;

    static constexpr const char kBootPrefix[] = "/ns/m/__ns_boot__/b1/";
    static constexpr size_t kBootPrefixLen = sizeof(kBootPrefix) - 1;
    if (StartsWith(pathOnly, kBootPrefix)) {
      pathOnly = std::string("/ns/m/") + pathOnly.substr(kBootPrefixLen);
      changed = true;
    }

    static constexpr const char kHmrPrefix[] = "/ns/m/__ns_hmr__/";
    static constexpr size_t kHmrPrefixLen = sizeof(kHmrPrefix) - 1;
    if (StartsWith(pathOnly, kHmrPrefix)) {
      size_t tagEnd = pathOnly.find('/', kHmrPrefixLen);
      if (tagEnd != std::string::npos && tagEnd > kHmrPrefixLen) {
        pathOnly = std::string("/ns/m/") + pathOnly.substr(tagEnd + 1);
        changed = true;
      }
    }

    if (changed) {
      originAndPath = originAndPath.substr(0, pathStart) + pathOnly;
    }
  }

  // IMPORTANT: This function is used as an HTTP module registry/cache key.
  // For general-purpose HTTP module loading (public internet), the query
  // string can be part of the module's identity (auth, content versioning,
  // routing, etc), so it is preserved verbatim. Query normalization
  // (sorting, dropping `t`/`v`/`import` cache busters) applies only to:
  //
  //   - Known dev-server endpoints, where those params are purely cache
  //     busters.
  //   - Volatile URLs (see `IsVolatileUrl`): endpoints whose response
  //     changes on every save (e.g. component-update endpoints, where each
  //     save's fetch carries a fresh `t=Date.now()`). Their registry key
  //     must stay STABLE across saves — the version discriminator lives in
  //     the fetch URL, never in the key — so the dynamic-import path's
  //     evict-before-import finds and replaces the previous save's entry.
  //     Per-save keys here would turn that evict into a no-op and leak one
  //     compiled module per save for the life of the dev session, while a
  //     stale boot-time entry kept serving old bodies to re-imports.
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    const bool isDevEndpoint =
      StartsWith(pathOnly, "/ns/") ||
      StartsWith(pathOnly, "/node_modules/.vite/") ||
      StartsWith(pathOnly, "/@id/") ||
      StartsWith(pathOnly, "/@fs/");
    if (!isDevEndpoint && !IsVolatileUrl(noHash)) {
      // Preserve query as-is (fragment already removed).
      return noHash;
    }
  }

  if (query.empty()) return originAndPath;

  // Keep all params except typical import markers or t/v cache busters; sort for stability.
  std::vector<std::string> kept;
  size_t start = 0;
  while (start <= query.size()) {
    size_t amp = query.find('&', start);
    std::string pair = (amp == std::string::npos) ? query.substr(start) : query.substr(start, amp - start);
    if (!pair.empty()) {
      size_t eq = pair.find('=');
      std::string name = (eq == std::string::npos) ? pair : pair.substr(0, eq);
      // Drop import marker and common cache-busting stamps.
      if (!(name == "import" || name == "t" || name == "v")) kept.push_back(pair);
    }
    if (amp == std::string::npos) break;
    start = amp + 1;
  }
  if (kept.empty()) return originAndPath;
  std::sort(kept.begin(), kept.end());
  std::string rebuilt = originAndPath + "?";
  for (size_t i = 0; i < kept.size(); i++) {
    if (i > 0) rebuilt += "&";
    rebuilt += kept[i];
  }
  return rebuilt;
}

// ============================================================================
// Speculative module-source prefetcher
// ============================================================================
//
// V8 10.3.22 only exposes a synchronous ResolveModuleCallback for static
// imports. Each call into HttpFetchText() blocks the JS thread on a
// semaphore until that one HTTP response arrives, which forces serial
// fetching from the JS thread's perspective. Server-side telemetry
// shows this as `maxConcurrent=1` for the entire cold boot.
//
// This block speculatively prefetches a module's static imports the
// instant the parent's body arrives, before V8 has even started
// compiling the parent. Prefetches run on a concurrent GCD queue capped
// at kPrefetchMaxConcurrent and write into a thread-safe in-memory
// cache keyed by full URL. By the time V8 calls ResolveModuleCallback
// for a sibling, the source is already in cache and HttpFetchText
// returns instantly without touching the network. Effective parallelism
// goes from 1 → ~K where K = kPrefetchMaxConcurrent.
//
// Correctness invariants:
//   1. Cache reads consume (one-shot). A second HttpFetchText for the
//      same URL after a cache hit triggers a fresh network fetch — this
//      is the right behavior for HMR where re-fetching means we got a
//      newer version of the module.
//   2. Every prefetch goes through IsRemoteUrlAllowed() exactly the
//      same way HttpFetchText does. The security gate is preserved.
//   3. The scanner is best-effort. False positives just trigger one
//      extra HTTP fetch the device might not need. False negatives just
//      cost us K=1 for that one module — same as before this change.
//   4. Recursion happens via dispatch_async; the C++ stack never grows.

static constexpr int kPrefetchMaxConcurrent = 4;
static constexpr size_t kPrefetchMaxImportsPerModule = 256;
static constexpr size_t kPrefetchSummaryEvery = 100;
static constexpr size_t kPrefetchMaxScanBytes = 256 * 1024; // skip very large bodies

// Forward declarations — these helpers are defined below their first use,
// matching the existing convention in this file.
static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out, std::string& contentType, int& status);
static std::vector<std::string> ScanStaticImportSpecifiers(const std::string& source, size_t maxResults);
static std::string ResolveImportSpecifierAgainstUrl(const std::string& specifier, const std::string& parentUrl);
static bool LooksLikeJsSourceUrl(const std::string& url);
static void SchedulePrefetchForDeps(const std::string& parentUrl, const std::string& source);
static void SchedulePrefetchForDepsAsync(const std::string& parentUrl, const std::string& source);
static bool TryGetPrefetchedSource(const std::string& url, std::string& out);
static void MaybeLogPrefetchSummary(const char* trigger);
static void MaybePumpJSThreadDuringBoot();
// Forward decl: the pluggable HTTP-fetch yield hook is defined below
// MaybePumpJSThreadDuringBoot (which is its default callback), but HttpFetchText
// calls it from earlier in the file. See the definition for the rationale on
// the atomic indirection.
static inline void InvokeHttpFetchYield();

static std::mutex g_prefetchMutex;
static std::unordered_map<std::string, std::string> g_prefetchCache;
static std::unordered_set<std::string> g_prefetchInflight;
static dispatch_queue_t g_prefetchQueue = dispatch_queue_create("com.nativescript.module.prefetch", DISPATCH_QUEUE_CONCURRENT);
static dispatch_semaphore_t g_prefetchConcurrencyLimit = dispatch_semaphore_create(kPrefetchMaxConcurrent);

// Always-on diagnostic counters. These intentionally do NOT gate behind
// IsScriptLoadingLogEnabled() — without this signal we cannot tell a
// helping prefetcher from a hurting one.
static std::atomic<size_t> g_prefetchHits{0};            // V8 asked for a URL we had cached
static std::atomic<size_t> g_prefetchMisses{0};          // V8 asked for a URL we did not have
static std::atomic<size_t> g_prefetchScheduled{0};       // background fetches we kicked off
static std::atomic<size_t> g_prefetchSatisfied{0};       // background fetches that landed bytes in the cache
static std::atomic<size_t> g_prefetchFailed{0};          // background fetches that returned non-2xx or empty
static std::atomic<size_t> g_prefetchSkipped{0};         // candidates rejected (already cached/inflight, bare specifier, non-JS, blocked)

// synchronous-fetch timing histogram.
//
// The histogram is intentionally coarse —
// just three buckets — and we log a summary once per kFetchSyncSummaryEvery
// completions. That keeps the noise low (one line per ~100 fetches) while
// still surfacing tail behavior. The "fast" bucket means a request landed
// in <10ms (typical for a kept-alive HTTP/1.1 connection on loopback);
// "slow" means >100ms (which usually means a fresh TCP/TLS handshake or
// a large response body). If most fetches are "fast", keep-alive is
// working. If most are "slow", we still have churn to track down.
static std::atomic<size_t> g_fetchSyncCount{0};
static std::atomic<uint64_t> g_fetchSyncTotalMs{0};
static std::atomic<size_t> g_fetchSyncFast{0};   // <10ms
static std::atomic<size_t> g_fetchSyncMedium{0}; // 10–99ms
static std::atomic<size_t> g_fetchSyncSlow{0};   // >=100ms
static constexpr size_t kFetchSyncSummaryEvery = 100;

bool HttpFetchText(const std::string& url, std::string& out, std::string& contentType, int& status) {
  // Security gate: check if remote module loading is allowed before any HTTP fetch.
  // This is the single point of enforcement for all HTTP module loading.
  if (!IsRemoteUrlAllowed(url)) {
    status = 403; // Forbidden
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][security][blocked] %s", url.c_str());
    }
    return false;
  }

  const bool prefetchEnabled = IsHttpModulePrefetchEnabled();
  // Hoist the URL-log flag once per call so the two success branches
  // below pay one TLS read instead of two.
  const bool urlLogEnabled = IsHttpFetchUrlLogEnabled();

  // the prefetch CACHE READ is always-on,
  // independent of `httpModulePrefetch`. HMR client kicks
  // off a synchronous BFS prefetch (`KickstartHmrPrefetchSync`) right
  // before re-evaluating the entry module; that path populates
  // `g_prefetchCache` regardless of whether speculative cold-boot
  // prefetching is enabled. Gating the read here on `prefetchEnabled`
  // would discard those bodies and force V8 back to the network on
  // every save — defeating the entire purpose of kickstart.
  //
  // Speculative WRITES (`SchedulePrefetchForDepsAsync`) remain gated
  // on the flag below, so cold-boot behaviour is unchanged for users
  // who have not opted into `httpModulePrefetch: true`.
  //
  // Cache reads are one-shot; consuming the entry guarantees that a
  // re-fetch (e.g. after HMR) goes back to the network for fresh source.
  if (TryGetPrefetchedSource(url, out)) {
    contentType = "application/javascript"; // best effort — same as the dev server returns
    status = 200;
    g_prefetchHits.fetch_add(1, std::memory_order_relaxed);
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader][prefetch][hit] %s (%lu bytes)", url.c_str(), (unsigned long)out.size());
    }
    if (urlLogEnabled) {
      // Per-URL diagnostic. Distinguish prefetch-cache hits from
      // network fetches so we can attribute who actually paid for
      // each module body. ms is omitted because the cache lookup is
      // effectively instantaneous compared to network I/O.
      Log(@"[http-loader][fetch][prefetch] %s bytes=%lu",
          url.c_str(), (unsigned long)out.size());
    }
    MaybeLogPrefetchSummary("hit");
    // Chain the wave: scan the cached body for its own imports and
    // schedule those prefetches off the JS thread. The scan itself is
    // CPU work; running it inline on every cache hit was burning the
    // very thread we are trying to unblock.
    SchedulePrefetchForDepsAsync(url, out);
    // Yield to the placeholder heartbeat between cache hits — without
    // this the runloop is starved by back-to-back HttpFetchText calls.
    InvokeHttpFetchYield();
    return true;
  }

  // Slow path: cache miss → synchronous fetch with one retry on failure.
  // This preserves the original HttpFetchText behavior exactly.
  if (prefetchEnabled) {
    g_prefetchMisses.fetch_add(1, std::memory_order_relaxed);
  }
  // Time the network branch end-to-end so the per-URL log can
  // attribute milliseconds to each fetch. We measure here (not
  // inside PerformHttpFetchOnceSync) so the retry interval gets
  // billed to the URL too — which is what the user sees as "this
  // URL was slow".
  const uint64_t netStartUs = urlLogEnabled
      ? (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0)
      : 0ull;
  bool ok = PerformHttpFetchOnceSync(url, out, contentType, status);
  if (!ok) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader] retrying %s after initial fetch error", url.c_str());
    }
    usleep(120 * 1000);
    ok = PerformHttpFetchOnceSync(url, out, contentType, status);
  }
  // Cold-boot connection recovery. status == 0 means the request died at
  // the connection level — no HTTP response at all. During a dev-session
  // cold boot the dominant cause is iOS local-network privacy: the app's
  // first fetch to a LAN dev server raises the system's Local Network
  // alert and is denied immediately, before the user can respond. Apple's
  // guidance (TN3179) for APIs without waitsForConnectivity is to add
  // retry logic. Without it, boot is unrecoverably dead the instant the
  // alert appears and the user must approve + manually relaunch; with it,
  // the flow becomes alert → Allow → next retry succeeds → boot
  // continues. Also covers a dev server that is still starting up when
  // the app launches.
  //
  // HARD BUDGET: dev boots run before UIApplicationMain, so the whole
  // wait sits inside the process-launch transaction and the launch
  // watchdog kills the app at 20s wall-clock from exec (0x8BADF00D,
  // verified via device crash report when this window was 30s). The
  // window must leave the first failed attempt + give-up path well clear
  // of that line, so the app can still fail soft like it did before.
  //
  // While waiting we *run the main runloop* rather than sleep: a blocked
  // main thread starves whatever chance the system has to present the
  // Local Network alert while the app is frontmost, and starves any boot
  // UI of frames.
  //
  // Scope guards keep this strictly a debug-build cold-boot JS-thread
  // affordance:
  //   - Debug builds only. Release apps that opt into remote modules
  //     (`allowRemoteModules: true`) must keep the fast-fail import
  //     semantics they had before this loop existed —
  //     `IsDevSessionBootComplete()` is permanently false in release
  //     (no dev session ever applies), so without this gate every
  //     connection-level import failure there would stall the JS
  //     thread for the full window.
  //   - `GetCurrentRuntime()` is thread_local (null on GCD prefetch
  //     workers), so background fetches keep failing fast.
  //   - HMR-time fetches (boot complete) keep failing fast.
  //   - HTTP error statuses (404/500) keep failing fast: only
  //     connection-level failures retry.
  if (!ok && status == 0 && RuntimeConfig.IsDebug &&
      Runtime::GetCurrentRuntime() != nullptr &&
      !IsDevSessionBootComplete()) {
    constexpr double kBootConnRetryWindowSec = 12.0;
    const CFAbsoluteTime giveUpAt =
        CFAbsoluteTimeGetCurrent() + kBootConnRetryWindowSec;
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader][boot-recovery] dev server unreachable (status=0); "
           "retrying %s for up to %.0fs (local network permission pending "
           "or server starting)",
          url.c_str(), kBootConnRetryWindowSec);
    }
    int attempts = 0;
    while (!ok && status == 0 && CFAbsoluteTimeGetCurrent() < giveUpAt) {
      if (NSThread.isMainThread) {
        // Service the runloop for the whole backoff so system alert
        // presentation and frame commits can happen while we wait.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
      } else {
        usleep(500 * 1000);
      }
      ok = PerformHttpFetchOnceSync(url, out, contentType, status);
      attempts++;
    }
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader][boot-recovery] %s after %d attempt%s url=%s status=%d",
          ok ? "recovered" : "gave up", attempts, attempts == 1 ? "" : "s",
          url.c_str(), status);
    }
  }
  if (!ok || status < 200 || status >= 300) {
    return false;
  }
  if (out.empty()) return false;
  if (IsScriptLoadingLogEnabled()) {
    unsigned long long blen = (unsigned long long)out.size();
    const char* ctstr = contentType.empty() ? "<none>" : contentType.c_str();
    Log(@"[http-loader] fetched status=%d content-type=%s bytes=%llu", status, ctstr, blen);
  }
  if (urlLogEnabled) {
    const uint64_t netEndUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t netMs = netEndUs > netStartUs ? (netEndUs - netStartUs) / 1000ull : 0ull;
    Log(@"[http-loader][fetch][network] %s bytes=%lu ms=%llu",
        url.c_str(), (unsigned long)out.size(), (unsigned long long)netMs);
  }

  // Speculative prefetch: kick off async fetches for this module's
  // static imports. By the time V8 walks the dep tree on the JS thread,
  // those bodies are already in g_prefetchCache.
  if (prefetchEnabled) {
    SchedulePrefetchForDepsAsync(url, out);
  }
  MaybeLogPrefetchSummary("miss");
  // Yield to the placeholder heartbeat after the 10–60ms sync fetch
  // block so the bar can repaint before V8 calls us again.
  InvokeHttpFetchYield();
  return true;
}

// Synchronous HTTP fetcher implementation.
//
// We use `+[NSURLConnection sendSynchronousRequest:returningResponse:error:]`
// (deprecated but functional on every shipping iOS version) instead of
// the modern NSURLSession API. NSURLSession exhibits a deadlock on the
// JS thread (the iOS main thread — dev sessions execute JS on the UI
// thread) once app bootstrap has completed:
//
//   - JS calls `import('foo')` (dynamic import).
//   - The runtime sync-fetches `foo`'s body on the main thread, blocking
//     on `dispatch_semaphore_wait`. This first fetch lands normally
//     (e.g. `hmr/client/index.js` arrives in ~60ms).
//   - V8 then synchronously calls `InstantiateModule`, which invokes our
//     `ResolveModuleCallback` for each static dependency. That callback
//     issues another sync fetch (e.g. `hmr/client/utils.js`).
//   - For this second sync fetch, NSURLSessionDataTask transitions to
//     NSURLSessionTaskStateRunning, but the completion handler **never
//     fires** within 6 seconds. NSURLSession's own
//     `timeoutIntervalForRequest` does not trip either — `task.error`
//     stays nil. The task remains stuck in Running state. Cancelling
//     it synchronously does not produce a completion-handler callback.
//
// The deadlock reproduces with both an implicit delegate queue and an
// explicit non-main `NSOperationQueue`. It also reproduces with
// `httpModulePrefetch` disabled, ruling out prefetcher contention.
// Boot-time sync fetches (thousands of them) never tripped it; only
// dynamic-import fetches issued after bootstrap completed did. Both run
// on the iOS main thread (dev sessions execute JS on the UI thread), so
// thread identity alone does not explain the difference — the trigger
// is the nested resolve-callback fetch pattern described above.
//
// `NSURLConnection.sendSynchronousRequest` uses CFNetwork directly,
// bypassing NSURLSession's task lifecycle, and returns the NSURLResponse
// so we can read HTTP status and Content-Type. The deprecation warning
// is suppressed locally because every published Apple SDK still ships
// a working implementation, and there is currently no non-deprecated
// API that gives us a runloop-independent synchronous fetch with a
// real HTTP status code.

// Marshaling type for one fetch attempt: plain C++ values only, so no
// ObjC object ownership crosses the GCD hop in PerformHttpFetchOnceSync
// (everything ObjC lives and dies inside HttpFetchOnceLoad's
// autorelease pool).
struct HttpFetchOnceResult {
  NSInteger status = 0;
  bool badUrl = false;
  bool hasError = false;
  long errCode = 0;
  std::string errDomain;
  std::string errDesc;
  std::string contentType;
  std::string body;
};

// The CFNetwork load itself: build the request, send it synchronously,
// marshal the response. Runnable on any thread; owns no shared state.
static HttpFetchOnceResult HttpFetchOnceLoad(const std::string& fetchUrl, bool isHmrRefetch) {
  HttpFetchOnceResult result;
  @autoreleasepool {
    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:fetchUrl.c_str()]];
    if (!u) {
      result.badUrl = true;
      return result;
    }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:u];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"application/javascript, text/javascript, */*;q=0.1"
   forHTTPHeaderField:@"Accept"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setTimeoutInterval:5.0];
    // CRITICAL for HMR: layered defense to bypass CFNetwork's URL cache.
    // `setCachePolicy:` alone is insufficient on iOS 18+/26+ Simulator —
    // CFNetwork still serves a previous save's body for a tagged HMR
    // URL from fsCachedData. Combined with the zero-capacity
    // sharedURLCache and per-request URL nonce in the caller, these give
    // us a reliable "always go to origin" path for the dev runtime.
    [request setValue:@"no-cache, no-store, max-age=0"
   forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    if (isHmrRefetch) {
      // Force a fresh TCP connection for HMR RE-fetches only.
      // CFNetwork has been observed to serve a body buffered on a
      // kept-alive HTTP/1.1 connection for a prior fetch of the SAME
      // logical module when a re-fetch reuses the connection. Boot
      // fetches are first-touch URLs with fully-consumed responses,
      // so they keep connection reuse — on a physical device over
      // Wi-Fi, a fresh TCP handshake per module fetch multiplied by
      // thousands of boot modules is the difference between booting
      // in seconds and being killed by the launch watchdog.
      [request setValue:@"close" forHTTPHeaderField:@"Connection"];
    }
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [request setHTTPShouldHandleCookies:NO];
    // `setHTTPShouldUsePipelining:` is deprecated on visionOS 2.4+ (classic
    // loader only). Passing NO matches the default — pipelining is already
    // off — so this is intent-preserving on every platform; suppress the
    // deprecation so the -Werror visionOS build keeps compiling.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [request setHTTPShouldUsePipelining:NO];
#pragma clang diagnostic pop
    [[NSURLCache sharedURLCache] removeCachedResponseForRequest:request];

    NSError* err = nil;
    NSURLResponse* response = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData* data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&err];
#pragma clang diagnostic pop

    // Drop any response sendSynchronousRequest: implicitly stored so it
    // cannot poison a later fetch of the same URL.
    [[NSURLCache sharedURLCache] removeCachedResponseForRequest:request];

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
      result.status = [httpResp statusCode];
      NSString* ct = [httpResp allHeaderFields][@"Content-Type"];
      if (ct) {
        const char* utf8 = [ct UTF8String];
        if (utf8) result.contentType = std::string(utf8);
      }
    }

    if (data && [data length] > 0) {
      const void* bytes = [data bytes];
      NSUInteger len = [data length];
      result.body.assign(static_cast<const char*>(bytes), static_cast<size_t>(len));
    }

    if (err != nil) {
      result.hasError = true;
      result.errCode = (long)err.code;
      const char* domain = err.domain ? [err.domain UTF8String] : nullptr;
      if (domain) result.errDomain = domain;
      const char* desc = err.localizedDescription ? [err.localizedDescription UTF8String] : nullptr;
      if (desc) result.errDesc = desc;
    }
  }
  return result;
}

static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out, std::string& contentType, int& status) {
  // One-time: replace the shared NSURLCache with a zero-capacity one
  // so CFNetwork has no on-disk store to satisfy fetches from. Per-
  // request cache policy + `removeCachedResponseForRequest:` were
  // empirically insufficient on iOS 18+/26+ Simulator — fsCachedData
  // would still serve a previous save's body for a tagged HMR URL.
  static dispatch_once_t s_cacheDisableOnce;
  dispatch_once(&s_cacheDisableOnce, ^{
    @autoreleasepool {
      NSURLCache* nullCache = [[NSURLCache alloc] initWithMemoryCapacity:0
                                                            diskCapacity:0
                                                            directoryURL:nil];
      [NSURLCache setSharedURLCache:nullCache];
    }
  });

  // For HMR re-fetch URLs (`/ns/m/__ns_hmr__/<tag>/...`), append a
  // unique nonce query parameter so CFNetwork sees a different URL
  // every time and cannot satisfy from any cache. Vite ignores
  // unknown query params on these routes, so the response body is
  // unchanged. Scoped to HMR URLs only because some Vite virtual
  // routes (e.g. `/@nativescript/vendor.mjs`) require exact-match
  // URLs and 404 on unknown query params. Boot fetches don't need
  // cache busting — first-touch by definition.
  const bool isHmrRefetch = url.find("__ns_hmr__") != std::string::npos;
  std::string fetchUrl = url;
  if (isHmrRefetch) {
    static std::atomic<uint64_t> s_fetchSeq{0};
    const uint64_t seq = s_fetchSeq.fetch_add(1, std::memory_order_relaxed);
    const uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    fetchUrl += (url.find('?') == std::string::npos) ? '?' : '&';
    fetchUrl += "__ns_dev_nonce=";
    fetchUrl += std::to_string(nowMs);
    fetchUrl += "-";
    fetchUrl += std::to_string(seq);
  }

  const auto fetchStartUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

  // Main-thread offload: dev sessions execute JS on the iOS main thread,
  // so V8's synchronous resolve callbacks land here on main. The caller
  // must block for the full fetch either way (the callbacks are
  // synchronous; there is no avoiding that), but hopping the load onto a
  // GCD worker keeps the synchronous URL load itself off the main
  // thread, which silences Foundation's per-fetch "Synchronous URL
  // loading ... should not occur on this application's main thread"
  // warning — thousands of them per cold boot.
  //
  // The hop must be `dispatch_async` + semaphore wait: `dispatch_sync`
  // to a global queue runs the block on the CALLING thread (GCD's
  // documented optimization for everything except the main queue), which
  // would leave the load on the main pthread and change nothing.
  //
  // QoS note: semaphore waits don't donate priority, so main can briefly
  // wait behind USER_INITIATED work. Acceptable for this dev-only path —
  // the wait is bounded by the request's 5s timeout.
  __block HttpFetchOnceResult result;
  if (NSThread.isMainThread) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      result = HttpFetchOnceLoad(fetchUrl, isHmrRefetch);
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);  // ARC-disabled file
  } else {
    result = HttpFetchOnceLoad(fetchUrl, isHmrRefetch);
  }

  if (result.badUrl) { status = 0; return false; }

  const auto fetchEndUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
  const uint64_t fetchMs = fetchEndUs > fetchStartUs ? (fetchEndUs - fetchStartUs) / 1000ull : 0ull;
  g_fetchSyncTotalMs.fetch_add(fetchMs, std::memory_order_relaxed);
  if (fetchMs < 10) {
    g_fetchSyncFast.fetch_add(1, std::memory_order_relaxed);
  } else if (fetchMs < 100) {
    g_fetchSyncMedium.fetch_add(1, std::memory_order_relaxed);
  } else {
    g_fetchSyncSlow.fetch_add(1, std::memory_order_relaxed);
  }
  const size_t syncCount = g_fetchSyncCount.fetch_add(1, std::memory_order_relaxed) + 1;
  if (syncCount > 0 && syncCount % kFetchSyncSummaryEvery == 0 &&
      IsScriptLoadingLogEnabled()) {
    const size_t fast = g_fetchSyncFast.load(std::memory_order_relaxed);
    const size_t medium = g_fetchSyncMedium.load(std::memory_order_relaxed);
    const size_t slow = g_fetchSyncSlow.load(std::memory_order_relaxed);
    const uint64_t totalMs = g_fetchSyncTotalMs.load(std::memory_order_relaxed);
    const uint64_t avgMs = syncCount ? totalMs / (uint64_t)syncCount : 0;
    Log(@"[http-loader][fetch-sync][summary] count=%lu avg=%llums fast(<10ms)=%lu medium=%lu slow(>=100ms)=%lu",
        (unsigned long)syncCount,
        (unsigned long long)avgMs,
        (unsigned long)fast,
        (unsigned long)medium,
        (unsigned long)slow);
  }

  status = (int)result.status;
  contentType = std::move(result.contentType);
  if (result.hasError || result.body.empty()) {
    if (IsScriptLoadingLogEnabled()) {
      const char* desc = result.errDesc.empty() ? "<no description>" : result.errDesc.c_str();
      const char* domain = result.errDomain.empty() ? "<no domain>" : result.errDomain.c_str();
      Log(@"[http-loader][fetch-error] url=%s domain=%s code=%ld desc=%s status=%ld bodyEmpty=%d ms=%llu",
          url.c_str(),
          domain,
          result.errCode,
          desc,
          (long)result.status,
          result.body.empty() ? 1 : 0,
          (unsigned long long)fetchMs);
    }
    return false;
  }
  out = std::move(result.body);
  return true;
}

static bool TryGetPrefetchedSource(const std::string& url, std::string& out) {
  std::lock_guard<std::mutex> lock(g_prefetchMutex);
  auto it = g_prefetchCache.find(url);
  if (it == g_prefetchCache.end()) return false;
  out = std::move(it->second);
  g_prefetchCache.erase(it);
  return true;
}

// Drop a specific URL set from `g_prefetchCache`. Used by
// `InvalidateModules` so an HMR eviction purges any stale HTTP body
// the previous prefetch wave left behind. See the doc comment in
// HMRSupport.h for the cache-poisoning case this fixes.
void EvictHttpModulePrefetchCacheUrls(const std::vector<std::string>& urls) {
  if (urls.empty()) return;
  size_t dropped = 0;
  {
    std::lock_guard<std::mutex> lock(g_prefetchMutex);
    for (const auto& url : urls) {
      if (url.empty()) continue;
      auto it = g_prefetchCache.find(url);
      if (it != g_prefetchCache.end()) {
        g_prefetchCache.erase(it);
        ++dropped;
      }
    }
  }
  if (dropped > 0 && IsScriptLoadingLogEnabled()) {
    Log(@"[http-loader][prefetch][evict] dropped=%lu of %lu",
        (unsigned long)dropped, (unsigned long)urls.size());
  }
}

static bool IsIdentifierChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

static bool IsHorizontalWs(char c) { return c == ' ' || c == '\t'; }

// Walks back over horizontal whitespace and returns the previous
// non-whitespace character, or 0 if we reached the start of the file.
static char PreviousNonHwsChar(const std::string& source, size_t hit) {
  if (hit == 0) return 0;
  ssize_t i = (ssize_t)hit - 1;
  while (i >= 0 && IsHorizontalWs(source[i])) i--;
  if (i < 0) return 0;
  return source[i];
}

// Tighter import scanner
//
// What we accept:
//   `} from "..."`              named-import block
//   `*  from "..."`             wildcard re-export
//   `<id> from "..."`           default import / `as Foo from`
//   `<line-start> import "..."` side-effect import
//   `<line-start> export ... from "..."` (caught by the `from` rule)
//
// What we explicitly reject:
//   `.from("...")`              member access (Array.from, etc.)
//   `.import("...")`            member access on dynamic-import-shaped APIs
//   `import("...")`             dynamic imports — lazy chunks rarely run
//                               at boot, and the speculative wave on
//                               them blew the budget.
//   matches inside template / string literals where the previous non-WS
//   char is a quote character (best-effort guard).
//
// False positives still possible inside multi-line string literals or
// comments containing the literal token sequences above; those are
// rare in real code and just cost one redundant HTTP fetch.
static std::vector<std::string> ScanStaticImportSpecifiers(const std::string& source, size_t maxResults) {
  std::vector<std::string> result;
  if (source.size() > kPrefetchMaxScanBytes) {
    return result; // skip very large bodies; we'd have nothing useful to prefetch anyway
  }
  std::unordered_set<std::string> seen;
  result.reserve(16);

  auto captureSpecAfter = [&](size_t cursor) -> ssize_t {
    // Skip whitespace before the quote.
    while (cursor < source.size()) {
      char c = source[cursor];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        cursor++;
        continue;
      }
      break;
    }
    if (cursor >= source.size()) return -1;
    char quote = source[cursor];
    if (quote != '"' && quote != '\'' && quote != '`') return -1;
    size_t end = source.find(quote, cursor + 1);
    if (end == std::string::npos) return -1;
    std::string spec = source.substr(cursor + 1, end - cursor - 1);
    if (!spec.empty() && spec.find('\n') == std::string::npos && seen.insert(spec).second) {
      result.push_back(std::move(spec));
    }
    return (ssize_t)(end + 1);
  };

  // ── Pass 1: `from "..."` ──────────────────────────────────────────
  // Accept only when the char immediately preceding `from` (after
  // optional horizontal whitespace) is `}`, `*`, or an identifier
  // character. Reject `.from(...)`.
  {
    const char* needle = "from";
    const size_t needleLen = 4;
    size_t pos = 0;
    while (pos < source.size() && result.size() < maxResults) {
      size_t hit = source.find(needle, pos);
      if (hit == std::string::npos) break;
      if (hit > 0 && IsIdentifierChar(source[hit - 1])) { pos = hit + 1; continue; }
      size_t after = hit + needleLen;
      if (after < source.size() && IsIdentifierChar(source[after])) { pos = hit + 1; continue; }
      char prev = PreviousNonHwsChar(source, hit);
      // Accept import-context predecessors only.
      bool ok = (prev == '}' || prev == '*' || prev == ',' || IsIdentifierChar(prev));
      if (!ok) { pos = hit + 1; continue; }
      ssize_t adv = captureSpecAfter(after);
      if (adv < 0) { pos = hit + 1; continue; }
      pos = (size_t)adv;
    }
  }

  // ── Pass 2: side-effect `import "..."` ────────────────────────────
  // Accept only when `import` is at the start of a statement: the
  // previous non-horizontal-whitespace character must be a newline,
  // `;`, `}`, or 0 (start of file). Reject member access (`.import`)
  // and dynamic imports (`import(...)`) — both cause more harm than
  // good for the cold-boot wave.
  {
    const char* needle = "import";
    const size_t needleLen = 6;
    size_t pos = 0;
    while (pos < source.size() && result.size() < maxResults) {
      size_t hit = source.find(needle, pos);
      if (hit == std::string::npos) break;
      if (hit > 0 && IsIdentifierChar(source[hit - 1])) { pos = hit + 1; continue; }
      size_t after = hit + needleLen;
      if (after < source.size() && IsIdentifierChar(source[after])) { pos = hit + 1; continue; }
      char prev = PreviousNonHwsChar(source, hit);
      bool atStmtStart = (prev == 0 || prev == '\n' || prev == '\r' || prev == ';' || prev == '}');
      if (!atStmtStart) { pos = hit + 1; continue; }
      // Distinguish `import "..."` (static) from `import(...)` and
      // `import X from "..."` (handled by Pass 1).
      // After `import`, skip horizontal whitespace and look at the
      // first non-whitespace character.
      size_t cursor = after;
      while (cursor < source.size() && IsHorizontalWs(source[cursor])) cursor++;
      if (cursor >= source.size()) break;
      char next = source[cursor];
      if (next == '(') { pos = hit + 1; continue; }       // dynamic — skip
      if (next != '"' && next != '\'' && next != '`') { pos = hit + 1; continue; } // `import X from` — Pass 1 handles
      ssize_t adv = captureSpecAfter(cursor);
      if (adv < 0) { pos = hit + 1; continue; }
      pos = (size_t)adv;
    }
  }

  return result;
}

static std::string ResolveImportSpecifierAgainstUrl(const std::string& specifier, const std::string& parentUrl) {
  if (specifier.empty()) return "";

  // Already absolute.
  if (StartsWith(specifier, "http://") || StartsWith(specifier, "https://")) {
    return specifier;
  }

  // Skip bare specifiers (need an import map we don't replicate here).
  bool isRelative = StartsWith(specifier, "./") || StartsWith(specifier, "../");
  bool isRootAbs = !specifier.empty() && specifier[0] == '/';
  if (!isRelative && !isRootAbs) return "";

  @autoreleasepool {
    NSString* parent = [NSString stringWithUTF8String:parentUrl.c_str()];
    NSString* spec = [NSString stringWithUTF8String:specifier.c_str()];
    if (!parent || !spec) return "";
    NSURL* baseUrl = [NSURL URLWithString:parent];
    if (!baseUrl) return "";
    NSURL* resolved = [NSURL URLWithString:spec relativeToURL:baseUrl];
    if (!resolved) return "";
    NSURL* abs = [resolved absoluteURL];
    NSString* result = abs ? [abs absoluteString] : nil;
    if (!result) return "";
    const char* utf8 = [result UTF8String];
    return utf8 ? std::string(utf8) : std::string();
  }
}

static bool LooksLikeJsSourceUrl(const std::string& url) {
  // Strip query string for extension check.
  size_t qpos = url.find('?');
  std::string path = (qpos == std::string::npos) ? url : url.substr(0, qpos);

  // Skip non-JS resource types that V8 either won't request through this
  // path or that would break our content-type assumption on cache hit.
  if (EndsWith(path, ".css") || EndsWith(path, ".scss") || EndsWith(path, ".sass") || EndsWith(path, ".less")) return false;
  if (EndsWith(path, ".png") || EndsWith(path, ".jpg") || EndsWith(path, ".jpeg") || EndsWith(path, ".gif") || EndsWith(path, ".svg") || EndsWith(path, ".webp") || EndsWith(path, ".ico")) return false;
  if (EndsWith(path, ".json")) return false;
  if (EndsWith(path, ".html") || EndsWith(path, ".htm")) return false;
  if (EndsWith(path, ".woff") || EndsWith(path, ".woff2") || EndsWith(path, ".ttf") || EndsWith(path, ".otf") || EndsWith(path, ".eot")) return false;
  if (EndsWith(path, ".mp4") || EndsWith(path, ".webm") || EndsWith(path, ".mp3") || EndsWith(path, ".wav")) return false;
  return true;
}

static void SchedulePrefetchForDeps(const std::string& parentUrl, const std::string& source) {
  std::vector<std::string> specifiers = ScanStaticImportSpecifiers(source, kPrefetchMaxImportsPerModule);
  if (specifiers.empty()) return;

  std::vector<std::string> toFetch;
  toFetch.reserve(specifiers.size());

  for (const std::string& spec : specifiers) {
    std::string absUrl = ResolveImportSpecifierAgainstUrl(spec, parentUrl);
    if (absUrl.empty()) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }
    if (!StartsWith(absUrl, "http://") && !StartsWith(absUrl, "https://")) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }
    if (!LooksLikeJsSourceUrl(absUrl)) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }
    if (!IsRemoteUrlAllowed(absUrl)) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }

    std::lock_guard<std::mutex> lock(g_prefetchMutex);
    if (g_prefetchCache.find(absUrl) != g_prefetchCache.end()) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }
    if (!g_prefetchInflight.insert(absUrl).second) {
      g_prefetchSkipped.fetch_add(1, std::memory_order_relaxed);
      continue;
    }
    toFetch.push_back(absUrl);
  }

  if (toFetch.empty()) return;

  for (const std::string& url : toFetch) {
    g_prefetchScheduled.fetch_add(1, std::memory_order_relaxed);
    std::string urlCopy = url;
    dispatch_async(g_prefetchQueue, ^{
      // Concurrency gate — never more than kPrefetchMaxConcurrent
      // simultaneous network fetches in flight from the prefetcher.
      dispatch_semaphore_wait(g_prefetchConcurrencyLimit, DISPATCH_TIME_FOREVER);

      std::string body;
      std::string contentType;
      int status = 0;
      bool ok = PerformHttpFetchOnceSync(urlCopy, body, contentType, status);

      if (ok && status >= 200 && status < 300 && !body.empty()) {
        {
          std::lock_guard<std::mutex> lock(g_prefetchMutex);
          g_prefetchCache[urlCopy] = body;
          g_prefetchInflight.erase(urlCopy);
        }
        g_prefetchSatisfied.fetch_add(1, std::memory_order_relaxed);
        if (IsScriptLoadingLogEnabled()) {
          Log(@"[http-loader][prefetch] cached %s (%lu bytes)", urlCopy.c_str(), (unsigned long)body.size());
        }
        // Recursively prefetch this module's deps. Recursion is via
        // dispatch_async, so the C++ stack never grows; depth is
        // implicitly bounded by the dep graph plus the dedupe set.
        SchedulePrefetchForDeps(urlCopy, body);
      } else {
        g_prefetchFailed.fetch_add(1, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lock(g_prefetchMutex);
        g_prefetchInflight.erase(urlCopy);
      }

      dispatch_semaphore_signal(g_prefetchConcurrencyLimit);
    });
  }
}

// Schedule prefetch on a background thread. The actual scan + URL
// resolution is the part we want OFF the JS thread — that is where we
// were burning cycles on every cache hit. Capturing source by value
// costs one std::string copy (small); we pay it once per HttpFetchText
// success and recover much more time on the JS thread.
static void SchedulePrefetchForDepsAsync(const std::string& parentUrl, const std::string& source) {
  if (source.empty()) return;
  std::string urlCopy = parentUrl;
  std::string sourceCopy = source;
  dispatch_async(g_prefetchQueue, ^{
    SchedulePrefetchForDeps(urlCopy, sourceCopy);
  });
}

// Periodic summary of prefetcher counters. Logs once every
// kPrefetchSummaryEvery hits+misses+satisfied+failed events, plus
// on the trailing edge of cache cleanup. Gated on the logScriptLoading
// flag so it stays silent by default — flip the flag when diagnosing
// prefetch behavior.
static void MaybeLogPrefetchSummary(const char* trigger) {
  size_t hits = g_prefetchHits.load(std::memory_order_relaxed);
  size_t misses = g_prefetchMisses.load(std::memory_order_relaxed);
  size_t scheduled = g_prefetchScheduled.load(std::memory_order_relaxed);
  size_t satisfied = g_prefetchSatisfied.load(std::memory_order_relaxed);
  size_t failed = g_prefetchFailed.load(std::memory_order_relaxed);
  size_t skipped = g_prefetchSkipped.load(std::memory_order_relaxed);
  size_t total = hits + misses;
  if (total == 0) return;
  if (total % kPrefetchSummaryEvery != 0) return;
  if (!IsScriptLoadingLogEnabled()) return;

  size_t cacheSize = 0;
  size_t inflight = 0;
  {
    std::lock_guard<std::mutex> lock(g_prefetchMutex);
    cacheSize = g_prefetchCache.size();
    inflight = g_prefetchInflight.size();
  }

  size_t hitPct = total ? (hits * 100 / total) : 0;
  Log(@"[http-loader][prefetch][summary] trigger=%s totalAsks=%lu hits=%lu (%lu%%) misses=%lu scheduled=%lu satisfied=%lu failed=%lu skipped=%lu cache=%lu inflight=%lu",
      trigger,
      (unsigned long)total,
      (unsigned long)hits, (unsigned long)hitPct,
      (unsigned long)misses,
      (unsigned long)scheduled,
      (unsigned long)satisfied,
      (unsigned long)failed,
      (unsigned long)skipped,
      (unsigned long)cacheSize,
      (unsigned long)inflight);
}

// Cold-boot JS-thread runloop pump.
//
// Synchronous `HttpFetchText` calls during V8's static-import walk park
// the JS thread inside `+sendSynchronousRequest:`, starving the
// `setInterval` heartbeat that drives the placeholder progress bar.
// Between fetches we run one short CFRunLoop slice in default mode so
// any due `CFRunLoopTimer` (the heartbeat) fires once before we return.
// Microtask checkpoints bracket the slice to flush V8 promise queues
// either side of the timer callback. v8::Locker is recursive, so nested
// acquisition by the timer callback is safe.
//
// Gated to JS-thread + cold-boot only:
//   - `Runtime::GetCurrentRuntime()` is thread_local; null on GCD
//     prefetch threads, so they never pump someone else's runloop.
//   - `IsDevSessionBootComplete()` short-circuits once the dev-session
//     boot has committed its first stable view — no placeholder to
//     repaint, and HMR-time fetches must not pay the pump cost.
//   - The runloop identity check survives any future change that
//     decouples the runtime's captured runloop from the current thread.
static void MaybePumpJSThreadDuringBoot() {
  Runtime* runtime = Runtime::GetCurrentRuntime();
  if (runtime == nullptr) return;
  if (IsDevSessionBootComplete()) return;

  v8::Isolate* isolate = runtime->GetIsolate();
  if (isolate == nullptr) return;

  CFRunLoopRef rl = runtime->RuntimeLoop();
  if (rl == nullptr || rl != CFRunLoopGetCurrent()) return;

  isolate->PerformMicrotaskCheckpoint();
  @autoreleasepool {
    // 1ms slice: long enough to cover the placeholder's 250ms-cadence
    // heartbeat when overdue, short enough that ~200 boot fetches add
    // <200ms of pump overhead total.
    NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
    NSDate* sliceDeadline = [NSDate dateWithTimeIntervalSinceNow:0.001];
    [runLoop runMode:NSDefaultRunLoopMode beforeDate:sliceDeadline];
  }
  isolate->PerformMicrotaskCheckpoint();
}

// Pluggable "yield to caller" hook used by HttpFetchText. The default
// implementation pumps the JS thread runloop during dev-session cold boot
// (see MaybePumpJSThreadDuringBoot for the gating rationale). Hosts can
// override or null it out via RegisterHttpFetchYield to keep HTTP fetches
// fully synchronous without any UI concerns leaking in.
//
// NOTE: function-pointer atomics are guaranteed lock-free on iOS for
// pointer-sized targets, so this carries no extra lock cost on the hot
// path. Read uses memory_order_acquire so callers see the pointer
// installed via memory_order_release in `RegisterHttpFetchYield`.
static std::atomic<void (*)()> g_httpFetchYield{&MaybePumpJSThreadDuringBoot};

void RegisterHttpFetchYield(void (*callback)()) {
  g_httpFetchYield.store(callback, std::memory_order_release);
}

static inline void InvokeHttpFetchYield() {
  auto cb = g_httpFetchYield.load(std::memory_order_acquire);
  if (cb != nullptr) cb();
}

void ClearHttpModulePrefetchCache() {
  std::lock_guard<std::mutex> lock(g_prefetchMutex);
  g_prefetchCache.clear();
  g_prefetchInflight.clear();
}

// HMR-driven kickstart prefetch.
//
// `__ns_hmr__/v<N>` URL prefixes are part of V8's cache key, so the
// dev server bumping `graphVersion` on each save makes every save look
// cold to V8. The kickstart pre-populates `g_prefetchCache` via a
// parallel BFS over `NSURLSession` (kept-alive) before V8 walks, so
// each `HttpFetchText` resolves from the cache (~microseconds) instead
// of the network (~10ms).
//
// `dispatch_group_wait` provides clean "BFS fully drained" semantics
// before V8 starts walking; the per-call queue isolates this group
// from other HMR cycles. We deliberately reuse `g_prefetchCache`
// (rather than a kickstart-only map) so the read path in
// `HttpFetchText` stays single-source — speculative-prefetch and
// kickstart consumers share the same destructive-read code.
namespace {

struct KickstartContext {
  std::mutex mutex;
  std::unordered_set<std::string> visited;
  std::atomic<size_t> fetchedCount{0};
  std::atomic<size_t> bytes{0};
  dispatch_group_t group = nullptr;
  dispatch_queue_t queue = nullptr;
  dispatch_semaphore_t concurrency = nullptr;
  // `recursive == true`: BFS scans each fetched body for static
  // imports (cold-boot speculative prefetcher and the legacy
  // single-seed kickstart). `recursive == false`: fetch only the
  // explicit URLs given (HMR-driven kickstart, where the dev server
  // already computed the inverse-dep closure in `evictPaths`).
  bool recursive = true;

  // ARC-disabled file: dispatch_release is required. By the time the
  // shared_ptr owning this context drops to zero, dispatch_group_wait
  // has returned and every scheduled block has released its capture.
  ~KickstartContext() {
    if (group) dispatch_release(group);
    if (queue) dispatch_release(queue);
    if (concurrency) dispatch_release(concurrency);
  }
};

}  // anonymous namespace

static void KickstartScheduleUrls(std::shared_ptr<KickstartContext> ctx,
                                  std::vector<std::string> urls) {
  for (const std::string& urlRef : urls) {
    if (urlRef.empty()) continue;
    if (!StartsWith(urlRef, "http://") && !StartsWith(urlRef, "https://")) continue;
    if (!LooksLikeJsSourceUrl(urlRef)) continue;
    if (!IsRemoteUrlAllowed(urlRef)) continue;

    bool fresh;
    {
      std::lock_guard<std::mutex> lock(ctx->mutex);
      fresh = ctx->visited.insert(urlRef).second;
    }
    if (!fresh) continue;

    // In recursive (cold-boot BFS) mode, if a previous wave (or an
    // opt-in speculative prefetch) already landed this body, treat
    // the URL as covered — no point spinning up a fetch we'd discard
    // anyway.
    //
    // In HMR (non-recursive) mode this guard is *toxic*: the caller
    // has explicitly told us "these URLs are stale, please refetch",
    // and any body sitting in `g_prefetchCache` is a leftover from
    // the previous wave that V8 didn't consume. Honoring the cache
    // here would feed V8 the stale body on the next walk — the
    // "1 cycle behind" symptom for `.ts` edits with many transitive
    // importers. So we skip this short-circuit entirely when
    // `recursive == false`. The emplace-vs-overwrite decision below
    // is also tightened for the same reason. (`InvalidateModules`
    // now pre-clears the cache for the eviction set, so this is
    // defense-in-depth — but the kickstart may also be invoked
    // manually for diagnostics, and we want it to be correct in
    // isolation.)
    if (ctx->recursive) {
      std::lock_guard<std::mutex> lock(g_prefetchMutex);
      if (g_prefetchCache.find(urlRef) != g_prefetchCache.end()) continue;
    }

    dispatch_group_enter(ctx->group);
    std::string urlCopy = urlRef;
    const bool hmrMode = !ctx->recursive;
    dispatch_async(ctx->queue, ^{
      dispatch_semaphore_wait(ctx->concurrency, DISPATCH_TIME_FOREVER);

      std::string body;
      std::string contentType;
      int status = 0;
      bool ok = PerformHttpFetchOnceSync(urlCopy, body, contentType, status);

      if (ok && status >= 200 && status < 300 && !body.empty()) {
        size_t bodySize = body.size();
        // Recursive (cold-boot) — Insert (do not overwrite). Another
        // path may have already landed the same URL via the
        // speculative prefetcher; honor whichever copy got there
        // first to avoid wastefully clobbering an already-valid
        // cache entry.
        //
        // HMR (non-recursive) — When the caller is the HMR
        // kickstart, the *fresh* body we just fetched is by
        // definition the authoritative copy; any older entry in the
        // cache is stale by construction (the dev server has just
        // told us so). So overwrite unconditionally for HMR. The
        // recursive cold-boot path keeps its emplace semantics.
        std::string scanSource;
        {
          std::lock_guard<std::mutex> lock(g_prefetchMutex);
          if (hmrMode) {
            auto& slot = g_prefetchCache[urlCopy];
            slot = std::move(body);
            scanSource = slot;
            bodySize = slot.size();
          } else {
            auto inserted = g_prefetchCache.emplace(urlCopy, std::move(body));
            if (inserted.second) {
              scanSource = inserted.first->second;  // take a copy for off-lock scanning
            } else {
              scanSource = inserted.first->second;
              bodySize = inserted.first->second.size();
            }
          }
        }
        ctx->fetchedCount.fetch_add(1, std::memory_order_relaxed);
        ctx->bytes.fetch_add(bodySize, std::memory_order_relaxed);

        // Only walk the dep graph when the caller asked for BFS.
        // HMR kickstart drives this with a precomputed inverse-dep
        // closure (`evictPaths`) and sets recursive=false to skip a
        // full graph re-scan that would only re-discover the set we
        // already have.
        if (ctx->recursive) {
          // Recurse: scan the body for static imports, resolve each
          // specifier against this URL, and schedule any new URLs.
          std::vector<std::string> specs = ScanStaticImportSpecifiers(scanSource, kPrefetchMaxImportsPerModule);
          if (!specs.empty()) {
            std::vector<std::string> nextUrls;
            nextUrls.reserve(specs.size());
            for (const std::string& spec : specs) {
              std::string absUrl = ResolveImportSpecifierAgainstUrl(spec, urlCopy);
              if (!absUrl.empty()) nextUrls.push_back(std::move(absUrl));
            }
            if (!nextUrls.empty()) {
              KickstartScheduleUrls(ctx, std::move(nextUrls));
            }
          }
        }
      }

      dispatch_semaphore_signal(ctx->concurrency);
      dispatch_group_leave(ctx->group);
    });
  }
}

// Internal multi-URL kickstart. Both the legacy single-seed
// `KickstartHmrPrefetchSync` and the HMR-driven
// `KickstartHmrPrefetchUrlsSync` funnel through here so the two
// callers share one validated, instrumented code path.
//
// `recursive=true`  → seed-rooted BFS over static imports (cold boot,
//                     legacy callers).
// `recursive=false` → fetch the provided list and stop (HMR cycle:
//                     server already gave us the inverse-dep closure).
static bool KickstartRunSync(std::vector<std::string> urls,
                             int maxConcurrent,
                             double timeoutSeconds,
                             bool recursive,
                             const char* logLabel,
                             const std::string& diagSeed,
                             size_t* outFetchedCount,
                             uint64_t* outElapsedMs) {
  if (urls.empty()) return false;
  // Drop empty / non-allowlisted URLs up front. We still want a
  // truthy result even if some entries get filtered, because partial
  // success is strictly better than the pre-kickstart baseline.
  std::vector<std::string> filtered;
  filtered.reserve(urls.size());
  for (auto& u : urls) {
    if (u.empty()) continue;
    if (!IsRemoteUrlAllowed(u)) continue;
    filtered.push_back(std::move(u));
  }
  if (filtered.empty()) return false;

  if (maxConcurrent <= 0) maxConcurrent = 16;
  if (timeoutSeconds <= 0.0) timeoutSeconds = 10.0;

  const uint64_t startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

  auto ctx = std::make_shared<KickstartContext>();
  ctx->group = dispatch_group_create();
  ctx->queue = dispatch_queue_create("com.nativescript.hmr.kickstart", DISPATCH_QUEUE_CONCURRENT);
  ctx->concurrency = dispatch_semaphore_create(maxConcurrent);
  ctx->recursive = recursive;

  KickstartScheduleUrls(ctx, std::move(filtered));

  // Cold-boot caller (JS thread, pre-bootstrap): poll `dispatch_group_wait`
  // in 50ms slices and pump the runloop between them so the placeholder
  // heartbeat keeps ticking. HMR-refresh caller (post-bootstrap or
  // off-thread): plain blocking wait — no bar to animate and the wait
  // is short. Pump cost on a 21s cold-boot kickstart: ~600 syscalls +
  // ~600ms of CFRunLoop slices, in exchange for ~85 heartbeat ticks.
  long timedOut;
  Runtime* coldBootRuntime = Runtime::GetCurrentRuntime();
  const bool useColdBootPumpWait = coldBootRuntime != nullptr && !IsDevSessionBootComplete();
  if (useColdBootPumpWait) {
    const int64_t sliceNs = 50LL * NSEC_PER_MSEC;
    const uint64_t timeoutUs = (uint64_t)(timeoutSeconds * 1000.0 * 1000.0);
    timedOut = 1;
    while (true) {
      const long sliceResult = dispatch_group_wait(ctx->group, dispatch_time(DISPATCH_TIME_NOW, sliceNs));
      if (sliceResult == 0) {
        timedOut = 0;
        break;
      }
      const uint64_t nowUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
      if (nowUs - startUs >= timeoutUs) break;
      InvokeHttpFetchYield();
    }
  } else {
    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(timeoutSeconds * NSEC_PER_SEC));
    timedOut = dispatch_group_wait(ctx->group, deadline);
  }

  const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
  const uint64_t elapsedMs = endUs > startUs ? (endUs - startUs) / 1000ull : 0ull;
  const size_t fetched = ctx->fetchedCount.load(std::memory_order_relaxed);
  const size_t bytes = ctx->bytes.load(std::memory_order_relaxed);

  if (outFetchedCount) *outFetchedCount = fetched;
  if (outElapsedMs) *outElapsedMs = elapsedMs;

  // BFS (cold-boot seed) and list (HMR multi-URL) emit distinct shapes
  // so the two waves are distinguishable in logs at a glance.
  if (IsScriptLoadingLogEnabled()) {
    if (recursive) {
      Log(@"[hmr-kickstart][%s] seed=%s fetched=%lu bytes=%lu ms=%llu status=%s concurrency=%d",
          logLabel ? logLabel : "bfs",
          diagSeed.c_str(),
          (unsigned long)fetched,
          (unsigned long)bytes,
          (unsigned long long)elapsedMs,
          timedOut == 0 ? "drained" : "timeout",
          maxConcurrent);
    } else {
      Log(@"[hmr-kickstart][%s] urls=%lu fetched=%lu bytes=%lu ms=%llu status=%s concurrency=%d",
          logLabel ? logLabel : "list",
          (unsigned long)urls.size(),
          (unsigned long)fetched,
          (unsigned long)bytes,
          (unsigned long long)elapsedMs,
          timedOut == 0 ? "drained" : "timeout",
          maxConcurrent);
    }
  }

  return timedOut == 0;
}

bool KickstartHmrPrefetchSync(const std::string& seedUrl,
                              int maxConcurrent,
                              double timeoutSeconds,
                              size_t* outFetchedCount,
                              uint64_t* outElapsedMs) {
  if (seedUrl.empty()) return false;
  if (!IsRemoteUrlAllowed(seedUrl)) return false;

  std::vector<std::string> seeds{seedUrl};
  return KickstartRunSync(std::move(seeds),
                          maxConcurrent,
                          timeoutSeconds,
                          /*recursive=*/true,
                          /*logLabel=*/"bfs",
                          seedUrl,
                          outFetchedCount,
                          outElapsedMs);
}

bool KickstartHmrPrefetchUrlsSync(const std::vector<std::string>& urls,
                                  int maxConcurrent,
                                  double timeoutSeconds,
                                  size_t* outFetchedCount,
                                  uint64_t* outElapsedMs) {
  if (urls.empty()) return false;

  // Diagnostic seed — we record the first URL purely so the log line
  // has a recognizable anchor when the user is correlating with their
  // server-side `[hmr-ws][update] file=...` line.
  std::string diagSeed;
  for (const auto& u : urls) {
    if (!u.empty()) { diagSeed = u; break; }
  }

  std::vector<std::string> copy = urls;
  return KickstartRunSync(std::move(copy),
                          maxConcurrent,
                          timeoutSeconds,
                          /*recursive=*/false,
                          /*logLabel=*/"list",
                          diagSeed,
                          outFetchedCount,
                          outElapsedMs);
}

void CleanupHMRGlobals() {
  // Reset all v8::Global handles BEFORE the isolate is disposed.
  // These static maps survive past isolate teardown and their destructors
  // (__cxa_finalize_ranges) would call v8::Global::Reset() on an already-
  // destroyed isolate, causing a crash in v8::internal::GlobalHandles::Destroy().
  for (auto& kv : g_hotData) { kv.second.Reset(); }
  g_hotData.clear();

  for (auto& kv : g_hotAccept) {
    for (auto& fn : kv.second) { fn.Reset(); }
  }
  g_hotAccept.clear();

  for (auto& kv : g_hotDispose) {
    for (auto& fn : kv.second) { fn.Reset(); }
  }
  g_hotDispose.clear();

  for (auto& kv : g_hotPrune) {
    for (auto& fn : kv.second) { fn.Reset(); }
  }
  g_hotPrune.clear();

  for (auto& kv : g_hotEventListeners) {
    for (auto& fn : kv.second) { fn.Reset(); }
  }
  g_hotEventListeners.clear();

  {
    // `g_hotDeclined` holds plain strings — no v8::Global handles — but
    // we still clear it under its own mutex on teardown so a re-launched
    // runtime in the same process starts with a clean slate.
    std::lock_guard<std::mutex> lock(g_hotDeclinedMutex);
    g_hotDeclined.clear();
  }

  // Drop any speculatively-prefetched module sources. These are plain
  // std::string buffers (no v8::Global), but flushing them on teardown
  // prevents stale source from leaking into a re-launched runtime in
  // the same process.
  ClearHttpModulePrefetchCache();
}

// ─────────────────────────────────────────────────────────────
// HMR + dev-session JS-callable globals
//
// Each `*Callback` below was previously an inline lambda in
// `Runtime::Init`. The lambdas captured nothing (`[]`), so the bodies
// transfer to file-local free functions unchanged. The single
// `InitializeHmrDevGlobals` entry point at the bottom installs them on
// the realm and is the only symbol exported to Runtime.mm.

namespace {

// Local helper that mirrors the `installGlobalFunction` lambda Runtime.mm
// used to define inline. Sets the function name on the v8 Function for
// nicer stack traces, attaches it to the realm's global object, and
// mirrors it onto globalThis so legacy `globalThis.__nsXxx(...)` callers
// keep working.
void InstallGlobalFunction(v8::Isolate* isolate, v8::Local<v8::Context> context,
                           const char* name, v8::FunctionCallback callback) {
  v8::Local<v8::FunctionTemplate> fnTpl =
      v8::FunctionTemplate::New(isolate, callback);
  v8::Local<v8::Function> fn = fnTpl->GetFunction(context).ToLocalChecked();
  fn->SetName(tns::ToV8String(isolate, name));
  context->Global()
      ->Set(context, tns::ToV8String(isolate, name), fn)
      .FromMaybe(false);
  MirrorFunctionOnGlobalThis(isolate, context, name);
}

// Run a dev-session module import and, on failure, publish a rejected
// promise carrying the original failure cause. Returns true when the
// module loaded successfully; on false the caller must return
// immediately because `info.GetReturnValue()` already holds the
// rejection. `logTag` is the bracketed prefix used in both the log
// line and the rejection message (e.g. `[__nsStartDevSession]`);
// `urlKind` is the human-readable subject (e.g. `clientUrl`).
bool RunModuleOrSendRejection(const v8::FunctionCallbackInfo<v8::Value>& info,
                              Runtime* runtime,
                              v8::Local<v8::Context> ctx,
                              const std::string& url,
                              const char* logTag,
                              const char* urlKind,
                              const std::string& sessionId,
                              bool logScriptLoading) {
  v8::Isolate* isolate = info.GetIsolate();
  std::string err;
  if (runtime->RunModule(url, &err)) {
    return true;
  }
  const std::string causeText = err.empty() ? std::string("<no-message>") : err;
  if (logScriptLoading) {
    Log(@"%s %s import failed session=%s url=%s message=%s",
        logTag, urlKind, sessionId.c_str(), url.c_str(), causeText.c_str());
  }
  std::string msg = std::string(logTag) + " failed to import " +
                    urlKind + ": " + url + " — " + causeText;
  info.GetReturnValue().Set(CreateRejectedPromise(
      ctx, v8::Exception::Error(tns::ToV8String(isolate, msg.c_str()))));
  return false;
}

void ConfigureDevRuntimeCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

  if (info.Length() < 1 || !info[0]->IsObject()) {
    if (logScriptLoading) {
      Log(@"[__nsConfigureRuntime] expected config object argument");
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
      v8::Local<v8::Object> jsonObj = ctx->Global()->Get(ctx,
        tns::ToV8String(isolate, "JSON")).ToLocalChecked().As<v8::Object>();
      v8::Local<v8::Function> stringify = jsonObj->Get(ctx,
        tns::ToV8String(isolate, "stringify")).ToLocalChecked().As<v8::Function>();
      v8::Local<v8::Value> args[] = { importMapVal };
      v8::Local<v8::Value> result;
      if (stringify->Call(ctx, jsonObj, 1, args).ToLocal(&result) && result->IsString()) {
        v8::String::Utf8Value utf8(isolate, result);
        if (*utf8) jsonStr = *utf8;
      }
    }
    if (!jsonStr.empty()) {
      SetImportMap(jsonStr);
      if (logScriptLoading) {
        Log(@"[__nsConfigureRuntime] import map set (%zu bytes)", jsonStr.size());
      }
    }
  }

  // Process volatilePatterns: array of strings
  v8::Local<v8::String> vpKey = tns::ToV8String(isolate, "volatilePatterns");
  v8::Local<v8::Value> vpVal;
  if (config->Get(ctx, vpKey).ToLocal(&vpVal) && vpVal->IsArray()) {
    v8::Local<v8::Array> arr = vpVal.As<v8::Array>();
    std::vector<std::string> patterns;
    for (uint32_t i = 0; i < arr->Length(); i++) {
      v8::Local<v8::Value> elem;
      if (arr->Get(ctx, i).ToLocal(&elem) && elem->IsString()) {
        v8::String::Utf8Value utf8(isolate, elem);
        if (*utf8) patterns.push_back(*utf8);
      }
    }
    if (!patterns.empty()) {
      SetVolatilePatterns(patterns);
      if (logScriptLoading) {
        Log(@"[__nsConfigureRuntime] %zu volatile patterns set", patterns.size());
      }
    }
  }
}

void StartDevSessionCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  if (info.Length() < 1 || !info[0]->IsObject()) {
    info.GetReturnValue().Set(CreateRejectedPromise(
        ctx, v8::Exception::TypeError(
                 tns::ToV8String(isolate,
                                 "[__nsStartDevSession] expected config object"))));
    return;
  }

  v8::Local<v8::Object> config = info[0].As<v8::Object>();
  tns::DevSessionState next;
  std::string sessionError;
  if (!tns::ReadDevSessionConfig(isolate, ctx, config, &next, &sessionError)) {
    info.GetReturnValue().Set(CreateRejectedPromise(
        ctx, v8::Exception::TypeError(
                 tns::ToV8String(isolate, sessionError.c_str()))));
    return;
  }

  tns::DevSessionState previous = tns::GetActiveDevSessionSnapshot();
  bool sessionChanged = tns::HasDevSessionChanged(previous, next);
  bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

  if (sessionChanged && previous.active) {
    std::vector<std::string> staleUrls = tns::CollectSessionModuleUrls(previous);
    if (logScriptLoading) {
      Log(@"[__nsStartDevSession] session changed old=%s new=%s invalidating=%lu",
          previous.sessionId.c_str(), next.sessionId.c_str(),
          (unsigned long)staleUrls.size());
    }
    if (!staleUrls.empty()) {
      tns::InvalidateModules(isolate, ctx, staleUrls);
    }
  }

  if (!sessionChanged && previous.active && previous.started) {
    if (logScriptLoading) {
      Log(@"[__nsStartDevSession] session already active: %s",
          next.sessionId.c_str());
    }
    info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
    return;
  }

  bool nativeRuntimeConfigDelegationEnabled = false;
  {
    v8::Local<v8::Value> delegationFlag;
    if (ctx->Global()
            ->Get(ctx, tns::ToV8String(isolate, "__NS_EXPERIMENTAL_NATIVE_RUNTIME_CONFIG_URL__"))
            .ToLocal(&delegationFlag) &&
        !delegationFlag.IsEmpty() && !delegationFlag->IsUndefined() &&
        !delegationFlag->IsNull()) {
      nativeRuntimeConfigDelegationEnabled = delegationFlag->BooleanValue(isolate);
    }
  }

  if (!next.runtimeConfigUrl.empty() && nativeRuntimeConfigDelegationEnabled) {
    if (logScriptLoading) {
      Log(@"[__nsStartDevSession] runtimeConfigUrl fetch start session=%s url=%s",
          next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
    }
    std::string runtimeConfigError;
    if (!tns::ApplyDevRuntimeConfigFromUrl(next.runtimeConfigUrl,
                                           &runtimeConfigError)) {
      if (logScriptLoading) {
        Log(@"[__nsStartDevSession] runtimeConfigUrl fetch failed session=%s url=%s",
            next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
      }
      info.GetReturnValue().Set(CreateRejectedPromise(
          ctx, v8::Exception::Error(
                   tns::ToV8String(isolate, runtimeConfigError.c_str()))));
      return;
    }
    if (logScriptLoading) {
      Log(@"[__nsStartDevSession] runtimeConfigUrl fetch complete session=%s url=%s",
          next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
    }
  } else if (!next.runtimeConfigUrl.empty() && logScriptLoading) {
    Log(@"[__nsStartDevSession] runtimeConfigUrl native delegation disabled; using JS-configured runtime session=%s url=%s",
        next.sessionId.c_str(), next.runtimeConfigUrl.c_str());
  }

  tns::ApplyDevSessionGlobals(isolate, ctx, next);

  tns::StoreActiveDevSession(next);

  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr) {
    if (logScriptLoading) {
      Log(@"[__nsStartDevSession] runtime unavailable for session=%s",
          next.sessionId.c_str());
    }
    info.GetReturnValue().Set(CreateRejectedPromise(
        ctx, v8::Exception::Error(
                 tns::ToV8String(isolate,
                                 "[__nsStartDevSession] runtime unavailable"))));
    return;
  }

  if (logScriptLoading) {
    Log(@"[__nsStartDevSession] clientUrl import start session=%s url=%s",
        next.sessionId.c_str(), next.clientUrl.c_str());
  }

  // `RunModuleOrSendRejection` captures the failure cause from
  // `RunModule` (`NativeScriptException::getMessage()`, top-level-await
  // rejection reason, TLA timeout text, or empty-namespace hint) so the
  // JS-side rejection carries the real reason instead of a generic
  // "failed to import".
  if (!RunModuleOrSendRejection(info, runtime, ctx, next.clientUrl,
                                "[__nsStartDevSession]", "clientUrl",
                                next.sessionId, logScriptLoading)) {
    return;
  }

  if (logScriptLoading) {
    Log(@"[__nsStartDevSession] clientUrl import complete session=%s url=%s",
        next.sessionId.c_str(), next.clientUrl.c_str());
    Log(@"[__nsStartDevSession] entryUrl import start session=%s url=%s",
        next.sessionId.c_str(), next.entryUrl.c_str());
  }

  if (!RunModuleOrSendRejection(info, runtime, ctx, next.entryUrl,
                                "[__nsStartDevSession]", "entryUrl",
                                next.sessionId, logScriptLoading)) {
    return;
  }

  next.started = true;
  tns::StoreActiveDevSession(next);

  if (logScriptLoading) {
    Log(@"[__nsStartDevSession] entryUrl import complete session=%s url=%s",
        next.sessionId.c_str(), next.entryUrl.c_str());
    Log(@"[__nsStartDevSession] session=%s imports complete; waiting for real app root commit",
        next.sessionId.c_str());
  }

  if (logScriptLoading) {
    Log(@"[__nsStartDevSession] session=%s platform=%s origin=%s client=%s entry=%s changed=%s",
        next.sessionId.c_str(), next.platform.c_str(), next.origin.c_str(),
        next.clientUrl.c_str(), next.entryUrl.c_str(),
        sessionChanged ? "true" : "false");
  }

  info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
}

void InvalidateModulesCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  if (info.Length() < 1 || !info[0]->IsArray()) {
    Log(@"[__nsInvalidateModules] expected array of URL strings");
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
  if (tns::IsScriptLoadingLogEnabled()) {
    Log(@"[ns-hmr][ios-invalidate] called urls.count=%zu", urls.size());
    size_t shown = 0;
    for (const auto& u : urls) {
      if (shown >= 32) break;
      Log(@"[ns-hmr][ios-invalidate] url[%zu]=%s", shown, u.c_str());
      shown++;
    }
    if (urls.size() > shown) {
      Log(@"[ns-hmr][ios-invalidate] (hidden %zu more URL(s))", urls.size() - shown);
    }
  }

  tns::InvalidateModules(isolate, ctx, urls);
}

//
// `__nsKickstartHmrPrefetch(seedUrlOrUrls, options?)` lets HMR client
// tell the runtime "the next re-import will walk this dep tree — please
// pre-fill the loader cache with every reachable module body before V8
// starts walking". Two argument shapes:
//
//   1. `seedUrl: string`  — legacy cold-boot BFS from a single seed.
//   2. `urls: string[]`   — HMR: the dev server already precomputed the
//      inverse-dep closure (the update payload's eviction set); fetch
//      that exact set in parallel with no body scan.
//
// Returns `{ ok, fetched, ms }` so JS can log the result. On failure
// callers should fall back to V8's normal synchronous walk.
void KickstartHmrPrefetchCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  auto buildResult = [&](bool ok, size_t fetched, uint64_t elapsedMs) {
    v8::Local<v8::Object> result = v8::Object::New(isolate);
    result->Set(ctx, tns::ToV8String(isolate, "ok"), v8::Boolean::New(isolate, ok)).Check();
    result->Set(ctx, tns::ToV8String(isolate, "fetched"), v8::Integer::NewFromUnsigned(isolate, (uint32_t)fetched)).Check();
    result->Set(ctx, tns::ToV8String(isolate, "ms"), v8::Number::New(isolate, (double)elapsedMs)).Check();
    info.GetReturnValue().Set(result);
  };

  if (info.Length() < 1 || (!info[0]->IsString() && !info[0]->IsArray())) {
    Log(@"[__nsKickstartHmrPrefetch] expected (seedUrl: string, options?) or (urls: string[], options?)");
    buildResult(false, 0, 0);
    return;
  }

  int maxConcurrent = 16;
  double timeoutSeconds = 10.0;
  if (info.Length() >= 2 && info[1]->IsObject()) {
    v8::Local<v8::Object> options = info[1].As<v8::Object>();

    v8::Local<v8::Value> mcVal;
    if (options->Get(ctx, tns::ToV8String(isolate, "maxConcurrent")).ToLocal(&mcVal) &&
        !mcVal.IsEmpty() && mcVal->IsNumber()) {
      double mc = mcVal->NumberValue(ctx).FromMaybe(16.0);
      if (mc >= 1.0 && mc <= 64.0) maxConcurrent = (int)mc;
    }

    v8::Local<v8::Value> toVal;
    if (options->Get(ctx, tns::ToV8String(isolate, "timeoutMs")).ToLocal(&toVal) &&
        !toVal.IsEmpty() && toVal->IsNumber()) {
      double ms = toVal->NumberValue(ctx).FromMaybe(10000.0);
      if (ms >= 100.0 && ms <= 60000.0) timeoutSeconds = ms / 1000.0;
    }
  }

  size_t fetched = 0;
  uint64_t elapsedMs = 0;

  if (info[0]->IsArray()) {
    // Multi-URL form — non-recursive parallel fetch of the
    // server-provided eviction closure.
    v8::Local<v8::Array> arr = info[0].As<v8::Array>();
    const uint32_t len = arr->Length();
    std::vector<std::string> urls;
    urls.reserve(len);
    for (uint32_t i = 0; i < len; i++) {
      v8::Local<v8::Value> elem;
      if (!arr->Get(ctx, i).ToLocal(&elem)) continue;
      if (!elem->IsString()) continue;
      v8::String::Utf8Value u8(isolate, elem);
      if (!*u8) continue;
      std::string s(*u8);
      if (s.empty()) continue;
      urls.push_back(std::move(s));
    }
    if (urls.empty()) {
      buildResult(false, 0, 0);
      return;
    }
    bool ok = tns::KickstartHmrPrefetchUrlsSync(urls, maxConcurrent, timeoutSeconds, &fetched, &elapsedMs);
    buildResult(ok, fetched, elapsedMs);
    return;
  }

  // Single-string form — legacy BFS-from-seed.
  v8::String::Utf8Value seedUtf8(isolate, info[0]);
  if (!*seedUtf8) {
    buildResult(false, 0, 0);
    return;
  }
  std::string seedUrl(*seedUtf8);

  bool ok = tns::KickstartHmrPrefetchSync(seedUrl, maxConcurrent, timeoutSeconds, &fetched, &elapsedMs);
  buildResult(ok, fetched, elapsedMs);
}

void ReloadDevAppCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

  tns::DevSessionState session = tns::GetActiveDevSessionSnapshot();
  if (!session.active || session.entryUrl.empty()) {
    if (logScriptLoading) {
      Log(@"[__nsReloadDevApp] no active dev session");
    }
    info.GetReturnValue().Set(CreateRejectedPromise(
        ctx, v8::Exception::Error(
                 tns::ToV8String(isolate,
                                 "[__nsReloadDevApp] no active dev session"))));
    return;
  }

  std::vector<std::string> sessionUrls = tns::CollectSessionModuleUrls(session);
  if (logScriptLoading) {
    Log(@"[__nsReloadDevApp] invalidating session=%s urls=%lu",
        session.sessionId.c_str(), (unsigned long)sessionUrls.size());
  }
  if (!sessionUrls.empty()) {
    tns::InvalidateModules(isolate, ctx, sessionUrls);
  }

  tns::SetDevSessionBootComplete(isolate, ctx, false);

  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr) {
    if (logScriptLoading) {
      Log(@"[__nsReloadDevApp] runtime unavailable for session=%s",
          session.sessionId.c_str());
    }
    info.GetReturnValue().Set(CreateRejectedPromise(
        ctx, v8::Exception::Error(
                 tns::ToV8String(isolate,
                                 "[__nsReloadDevApp] runtime unavailable"))));
    return;
  }

  if (logScriptLoading) {
    Log(@"[__nsReloadDevApp] entryUrl import start session=%s url=%s",
        session.sessionId.c_str(), session.entryUrl.c_str());
  }

  // Capture the inner failure cause so the reload's JS-side rejection
  // carries the actual reason instead of a generic "failed to import" —
  // symmetrical with the `__nsStartDevSession` path above so a
  // single-file HMR reload that re-evaluates the entry surfaces
  // TLA / module-load failures cleanly.
  if (!RunModuleOrSendRejection(info, runtime, ctx, session.entryUrl,
                                "[__nsReloadDevApp]", "entryUrl",
                                session.sessionId, logScriptLoading)) {
    return;
  }

  if (logScriptLoading) {
    Log(@"[__nsReloadDevApp] entryUrl import complete session=%s url=%s",
        session.sessionId.c_str(), session.entryUrl.c_str());
    Log(@"[__nsReloadDevApp] session=%s reload imports complete; waiting for real app root commit (invalidated=%lu)",
        session.sessionId.c_str(), (unsigned long)sessionUrls.size());
  }

  info.GetReturnValue().Set(CreateResolvedPromise(isolate, ctx));
}

void ApplyStyleUpdateCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  // All [__nsApplyStyleUpdate] log surfaces below are gated on the
  // logScriptLoading flag (DevFlags::IsScriptLoadingLogEnabled). This
  // path runs on every CSS HMR apply, so we keep it silent unless the
  // developer opts in via nativescript.config.ts. Real V8 exceptions
  // are still surfaced via tns::LogError unconditionally so HMR
  // failures are never swallowed.
  const bool logEnabled = tns::IsScriptLoadingLogEnabled();

  if (info.Length() < 1 || !info[0]->IsObject()) {
    if (logEnabled) {
      Log(@"[__nsApplyStyleUpdate] expected payload object");
    }
    return;
  }

  v8::Local<v8::Object> payload = info[0].As<v8::Object>();
  std::string cssText;
  std::string url;
  GetOptionalStringProperty(isolate, ctx, payload, "cssText", &cssText);
  GetOptionalStringProperty(isolate, ctx, payload, "url", &url);

  if (cssText.empty()) {
    if (logEnabled) {
      Log(@"[__nsApplyStyleUpdate] missing cssText payload");
    }
    return;
  }

  v8::Local<v8::Value> applicationValue;
  if (!ctx->Global()
           ->Get(ctx, tns::ToV8String(isolate, "Application"))
           .ToLocal(&applicationValue) ||
      !applicationValue->IsObject()) {
    if (logEnabled) {
      Log(@"[__nsApplyStyleUpdate] Application is unavailable for %s",
          url.c_str());
    }
    return;
  }

  v8::Local<v8::Object> applicationObject = applicationValue.As<v8::Object>();

  v8::Local<v8::Value> addCssValue;
  if (!applicationObject
           ->Get(ctx, tns::ToV8String(isolate, "addCss"))
           .ToLocal(&addCssValue) ||
      !addCssValue->IsFunction()) {
    if (logEnabled) {
      Log(@"[__nsApplyStyleUpdate] Application.addCss is unavailable for %s",
          url.c_str());
    }
    return;
  }

  v8::TryCatch tc(isolate);
  v8::Local<v8::Value> args[] = {
      tns::ToV8String(isolate, cssText.c_str()),
  };
  v8::Local<v8::Value> ignored;
  bool addCssCalled = addCssValue.As<v8::Function>()
                          ->Call(ctx, applicationObject, 1, args)
                          .ToLocal(&ignored);

  if (addCssCalled && !tc.HasCaught()) {
    v8::Local<v8::Value> getRootViewValue;
    if (applicationObject
            ->Get(ctx, tns::ToV8String(isolate, "getRootView"))
            .ToLocal(&getRootViewValue) &&
        getRootViewValue->IsFunction()) {
      v8::Local<v8::Value> rootViewValue;
      if (getRootViewValue.As<v8::Function>()
              ->Call(ctx, applicationObject, 0, nullptr)
              .ToLocal(&rootViewValue) &&
          rootViewValue->IsObject()) {
        v8::Local<v8::Object> rootViewObject = rootViewValue.As<v8::Object>();
        v8::Local<v8::Value> cssStateChangeValue;
        if (rootViewObject
                ->Get(ctx, tns::ToV8String(isolate, "_onCssStateChange"))
                .ToLocal(&cssStateChangeValue) &&
            cssStateChangeValue->IsFunction()) {
          bool cssStateChanged = cssStateChangeValue.As<v8::Function>()
                                     ->Call(ctx, rootViewObject, 0, nullptr)
                                     .ToLocal(&ignored);
          (void)cssStateChanged;
        }
      }
    }
  }

  if (tc.HasCaught()) {
    if (logEnabled) {
      Log(@"[__nsApplyStyleUpdate] failed for %s", url.c_str());
    }
    tns::LogError(isolate, tc);
    return;
  }

  if (logEnabled) {
    Log(@"[__nsApplyStyleUpdate] applied %s", url.c_str());
  }
}

void GetLoadedModuleUrlsCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  std::vector<std::string> urls = tns::GetLoadedModuleUrls();
  v8::Local<v8::Array> result =
      v8::Array::New(isolate, static_cast<int>(urls.size()));

  for (uint32_t index = 0; index < urls.size(); index++) {
    result
        ->Set(ctx, index, tns::ToV8String(isolate, urls[index].c_str()))
        .FromMaybe(false);
  }

  info.GetReturnValue().Set(result);
}

}  // namespace

void InitializeHmrDevGlobals(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  // Initialize HMR runtime helpers for dev mode. These collectively expose
  // the JS-callable globals the @nativescript/vite HMR client uses to drain
  // per-module callbacks and check declined-module state before each reboot:
  //   - __NS_DISPATCH_HOT_EVENT__   — fire registered import.meta.hot.on() listeners
  //   - __nsRunHmrDispose            — drain import.meta.hot.dispose() callbacks
  //   - __nsRunHmrPrune              — drain import.meta.hot.prune() callbacks
  //   - __nsHasDeclinedModule        — check g_hotDeclined for full-reload fallback
  // All four installations share one try/catch — they have identical risk
  // profiles (single V8 function registration each) and a failure in any
  // one of them shouldn't abort the rest of runtime init.
  if (RuntimeConfig.IsDebug) {
    try {
      InitializeHotEventDispatcher(isolate, context);
      InitializeHotDisposeRunner(isolate, context);
      InitializeHotPruneRunner(isolate, context);
      InitializeHotDeclinedHelper(isolate, context);

      // Debug-only diagnostic: expose the HTTP canonical-key function to JS so
      // the test harness can pin its identity behavior across cache-busters,
      // boot/hmr tags, and versioned bridge endpoints. This is NOT part of the
      // HMR client API surface and is never installed in release builds.
      {
        auto canonicalizeCb = [](const v8::FunctionCallbackInfo<v8::Value>& info) {
          v8::Isolate* iso = info.GetIsolate();
          if (info.Length() < 1 || !info[0]->IsString()) {
            info.GetReturnValue().SetEmptyString();
            return;
          }
          v8::String::Utf8Value u(iso, info[0]);
          std::string key =
              CanonicalizeHttpUrlKey(*u ? std::string(*u) : std::string());
          info.GetReturnValue().Set(tns::ToV8String(iso, key.c_str()));
        };
        v8::Local<v8::Function> fn =
            v8::Function::New(context, canonicalizeCb).ToLocalChecked();
        context->Global()
            ->CreateDataProperty(
                context, tns::ToV8String(isolate, "__nsCanonicalizeHttpUrlKey"),
                fn)
            .Check();
      }
    } catch (...) {
      // Don't crash if HMR setup fails
    }
  }

  // Install the session bootstrap runtime configuration hook for import map
  // support. `__nsConfigureDevRuntime` is the explicit host-runtime surface
  // used by the deterministic session bootstrap. `__nsConfigureRuntime`
  // remains as a compatibility alias while older entry paths still exist.
  InstallGlobalFunction(isolate, context, "__nsConfigureDevRuntime", ConfigureDevRuntimeCallback);
  InstallGlobalFunction(isolate, context, "__nsConfigureRuntime", ConfigureDevRuntimeCallback);
  context->Global()
      ->CreateDataProperty(context,
                           tns::ToV8String(isolate, "__nsSupportsRuntimeConfigUrl"),
                           v8::Boolean::New(isolate, true))
      .Check();

  InstallGlobalFunction(isolate, context, "__nsStartDevSession", StartDevSessionCallback);
  InstallGlobalFunction(isolate, context, "__nsInvalidateModules", InvalidateModulesCallback);
  InstallGlobalFunction(isolate, context, "__nsKickstartHmrPrefetch", KickstartHmrPrefetchCallback);
  InstallGlobalFunction(isolate, context, "__nsReloadDevApp", ReloadDevAppCallback);
  InstallGlobalFunction(isolate, context, "__nsApplyStyleUpdate", ApplyStyleUpdateCallback);
  InstallGlobalFunction(isolate, context, "__nsGetLoadedModuleUrls", GetLoadedModuleUrlsCallback);
}

} // namespace tns
