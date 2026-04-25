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

// Custom event listeners
// Keyed by event name (global, not per-module)
static std::unordered_map<std::string, std::vector<v8::Global<v8::Function>>> g_hotEventListeners;

// Active deterministic dev-session state.
static DevSessionState g_activeDevSession;
static std::mutex g_activeDevSessionMutex;

static bool GetOptionalStringProperty(v8::Isolate* isolate, v8::Local<v8::Context> context,
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

void ApplyDevSessionGlobals(v8::Isolate* isolate,
                            v8::Local<v8::Context> context,
                            const DevSessionState& session) {
  SetStringGlobal(isolate, context, "__NS_HTTP_ORIGIN__", session.origin);
  SetStringGlobal(isolate, context, "__NS_HMR_WS_URL__", session.wsUrl);
  SetBooleanGlobal(isolate, context, "__NS_HMR_BOOT_COMPLETE__", false);
  SetBooleanGlobal(isolate, context, "__NS_HMR_CLIENT_ACTIVE__", false);
  SetBooleanGlobal(isolate, context, "__NS_HMR_BROWSER_RUNTIME_CLIENT_ACTIVE__", false);
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

void RegisterHotEventListener(v8::Isolate* isolate, const std::string& event, v8::Local<v8::Function> cb) {
  if (cb.IsEmpty()) return;
  g_hotEventListeners[event].emplace_back(v8::Global<v8::Function>(isolate, cb));
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
  for (auto& cb : callbacks) {
    v8::TryCatch tryCatch(isolate);
    v8::Local<v8::Value> args[] = { data };
    v8::MaybeLocal<v8::Value> result = cb->Call(context, v8::Undefined(isolate), 1, args);
    (void)result; // Suppress unused result warning
    if (tryCatch.HasCaught()) {
      // Log error but continue to other listeners
      if (tns::IsScriptLoadingLogEnabled()) {
        Log(@"[import.meta.hot] Error in event listener for '%s'", event.c_str());
      }
    }
  }
}

void InitializeHotEventDispatcher(v8::Isolate* isolate, v8::Local<v8::Context> context) {
  using v8::FunctionCallbackInfo;
  using v8::Local;
  using v8::Value;

  // Create a global function __NS_DISPATCH_HOT_EVENT__(event, data)
  // that the HMR client can call to dispatch events to registered listeners
  auto dispatchCb = [](const FunctionCallbackInfo<Value>& info) {
    v8::Isolate* iso = info.GetIsolate();
    v8::Local<v8::Context> ctx = iso->GetCurrentContext();
    
    if (info.Length() < 1 || !info[0]->IsString()) {
      info.GetReturnValue().Set(v8::Boolean::New(iso, false));
      return;
    }
    
    v8::String::Utf8Value eventName(iso, info[0]);
    std::string event = *eventName ? *eventName : "";
    if (event.empty()) {
      info.GetReturnValue().Set(v8::Boolean::New(iso, false));
      return;
    }
    
    v8::Local<Value> data = info.Length() > 1 ? info[1] : v8::Undefined(iso).As<Value>();
    
    if (tns::IsScriptLoadingLogEnabled()) {
      Log(@"[import.meta.hot] Dispatching event '%s'", event.c_str());
    }
    
    DispatchHotEvent(iso, ctx, event, data);
    info.GetReturnValue().Set(v8::Boolean::New(iso, true));
  };
  
  v8::Local<v8::Object> global = context->Global();
  v8::Local<v8::Function> dispatchFn = v8::Function::New(context, dispatchCb).ToLocalChecked();
  global->CreateDataProperty(context, tns::ToV8String(isolate, "__NS_DISPATCH_HOT_EVENT__"), dispatchFn).Check();
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

  // decline() — mark declined (no-op for now)
  auto declineCb = [](const FunctionCallbackInfo<Value>& info) {
    info.GetReturnValue().Set(v8::Undefined(info.GetIsolate()));
  };

  // invalidate() — no-op for now
  auto invalidateCb = [](const FunctionCallbackInfo<Value>& info) {
    info.GetReturnValue().Set(v8::Undefined(info.GetIsolate()));
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

  // send(event, data) — send event to server (no-op on client, could be wired to WebSocket)
  auto sendCb = [](const FunctionCallbackInfo<Value>& info) {
    // No-op for now - could be wired to WebSocket for client->server events
    info.GetReturnValue().Set(v8::Undefined(info.GetIsolate()));
  };

  Local<Object> hot = Object::New(isolate);
  // Stable flags
  hot->CreateDataProperty(context, tns::ToV8String(isolate, "data"),
                          GetOrCreateHotData(isolate, key)).Check();
  hot->CreateDataProperty(context, tns::ToV8String(isolate, "prune"),
                          v8::Boolean::New(isolate, false)).Check();
  // Methods
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "accept"),
      v8::Function::New(context, acceptCb, makeKeyData(key)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "dispose"),
      v8::Function::New(context, disposeCb, makeKeyData(key)).ToLocalChecked()).Check();
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
  // For general-purpose HTTP module loading (public internet), the query string
  // can be part of the module's identity (auth, content versioning, routing, etc).
  // Therefore we only apply query normalization (sorting/dropping) for known
  // NativeScript dev endpoints where `t`/`v`/`import` are purely cache busters.
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    const bool isDevEndpoint =
      StartsWith(pathOnly, "/ns/") ||
      StartsWith(pathOnly, "/node_modules/.vite/") ||
      StartsWith(pathOnly, "/@id/") ||
      StartsWith(pathOnly, "/@fs/");
    if (!isDevEndpoint) {
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
static bool IsHttpModulePrefetchEnabled();
static bool IsHttpFetchUrlLogEnabled();
static void MaybeLogPrefetchSummary(const char* trigger);

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
  // Round-ten phase A — diagnostic. Hoist the flag once per call so the
  // two success branches below pay one TLS read instead of two.
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
      // Round-ten phase A — per-URL diagnostic. Distinguish prefetch-cache
      // hits from network fetches so we can attribute who actually paid
      // for each module body. ms is omitted because the cache lookup is
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
    return true;
  }

  // Slow path: cache miss → synchronous fetch with one retry on failure.
  // This preserves the original HttpFetchText behavior exactly.
  if (prefetchEnabled) {
    g_prefetchMisses.fetch_add(1, std::memory_order_relaxed);
  }
  // Round-ten phase A — diagnostic. Time the network branch end-to-end so
  // the per-URL log can attribute milliseconds to each fetch. We measure
  // here (not inside PerformHttpFetchOnceSync) so the retry interval gets
  // billed to the URL too — which is what the user sees as "this URL was
  // slow".
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
  return true;
}

// shared NSURLSession for HTTP keep-alive.
//
// A single process-wide NSURLSession (created once on first call) keeps
// connections open via standard HTTP/1.1 keep-alive — and on dev servers
// that negotiate HTTP/2, NSURLSession multiplexes all requests over one
// connection. NSURLSession is documented thread-safe for `dataTaskWithURL`
// and `resume`, so the JS thread and the prefetcher GCD queue can both
// share it without locking. We never invalidate it — the session's
// lifetime is tied to the runtime process, just like our V8 isolate.
//
// MRC NOTE: HMRSupport.mm is compiled with ARC disabled (the v8ios
// `NativeScript` target sets CLANG_ENABLE_OBJC_ARC = NO). That means
// `+sessionWithConfiguration:` returns an autoreleased instance and the
// surrounding `@autoreleasepool` drains it the moment we exit this
// `std::call_once` callback — leaving `g_httpSharedSession` dangling
// for every subsequent `[session dataTaskWithURL:…]` call (the original
// Without this, runtime can crash in `objc_msgSend` on app boot.
// We explicitly `[…retain]` the session so it lives for
// the runtime's lifetime; matching that, we never `[release]` it, so
// there's no double-free risk.
static NSURLSession* g_httpSharedSession = nil;
static std::once_flag g_httpSharedSessionOnce;

static NSURLSession* GetSharedHttpSession() {
  std::call_once(g_httpSharedSessionOnce, []() {
    @autoreleasepool {
      NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
      cfg.HTTPAdditionalHeaders = @{ @"Accept": @"application/javascript, text/javascript, */*;q=0.1",
                                     @"Accept-Encoding": @"identity" };
      cfg.timeoutIntervalForRequest = 5.0;
      cfg.timeoutIntervalForResource = 5.0;
      // Generous per-host max so the prefetcher's K=4 background fetches
      // don't get queued behind V8's foreground fetches. Apple's default
      // (4 on iOS) is exactly the number we configure for K — leave room.
      cfg.HTTPMaximumConnectionsPerHost = 16;
      // Disable URL cache: HMR depends on always seeing the freshest body
      // for the requested URL. We rely on Vite's `t`/`v` cache busters and
      // our own canonicalization for module identity, not the OS cache.
      cfg.URLCache = nil;
      cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
      // Explicit retain — see MRC NOTE above.
      g_httpSharedSession = [[NSURLSession sessionWithConfiguration:cfg] retain];
    }
  });
  return g_httpSharedSession;
}

static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out, std::string& contentType, int& status) {
  @autoreleasepool {
    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    if (!u) { status = 0; return false; }

    __block NSError* err = nil;
    __block NSInteger httpStatusLocal = 0;
    __block std::string contentTypeLocal;
    __block std::string bodyLocal;

    NSURLSession* session = GetSharedHttpSession();
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    const auto fetchStartUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    NSURLSessionDataTask* task = [session dataTaskWithURL:u
                                        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
      @autoreleasepool {
        err = error;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
          httpStatusLocal = ((NSHTTPURLResponse*)response).statusCode;
          NSString* ct = ((NSHTTPURLResponse*)response).allHeaderFields[@"Content-Type"];
          if (ct) { contentTypeLocal = std::string([ct UTF8String] ?: ""); }
        }
        if (data) {
          const void* bytes = [data bytes];
          NSUInteger len = [data length];
          if (bytes && len > 0) {
            bodyLocal.assign(static_cast<const char*>(bytes), static_cast<size_t>(len));
          }
        }
      }
      dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC));
    dispatch_semaphore_wait(sema, timeout);
    // IMPORTANT: do NOT call finishTasksAndInvalidate on g_httpSharedSession.
    // We want the connection pool to stay alive for the next fetch.

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
    if (syncCount > 0 && syncCount % kFetchSyncSummaryEvery == 0) {
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

    status = (int)httpStatusLocal;
    contentType = contentTypeLocal;
    if (err != nil || bodyLocal.empty()) {
      return false;
    }
    out.swap(bodyLocal);
    return true;
  }
}

static bool TryGetPrefetchedSource(const std::string& url, std::string& out) {
  std::lock_guard<std::mutex> lock(g_prefetchMutex);
  auto it = g_prefetchCache.find(url);
  if (it == g_prefetchCache.end()) return false;
  out = std::move(it->second);
  g_prefetchCache.erase(it);
  return true;
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
//   `import("...")`             dynamic imports — they almost never run
//                               at boot for Angular and the speculative
//                               wave on lazy chunks blew the budget.
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

// Reads `httpModulePrefetch` from app config (default: DISABLED).
//
// Apps that want to opt in for testing can set:
//
//   // nativescript.config.ts
//   export default {
//     httpModulePrefetch: true,
//   } as NativeScriptConfig;
//
// Returning false here
// short-circuits both the cache lookup and the prefetch wave in
// HttpFetchText, restoring the pre-prefetcher behavior bit-for-bit.
static bool IsHttpModulePrefetchEnabled() {
  static std::once_flag s_initFlag;
  static bool s_enabled = false;
  std::call_once(s_initFlag, []() {
    @autoreleasepool {
      id value = Runtime::GetAppConfigValue("httpModulePrefetch");
      if (value && [value respondsToSelector:@selector(boolValue)]) {
        s_enabled = [value boolValue];
      }
    }
    // Always-on startup banner.
    //
    //   [http-loader] prefetch=disabled   ← expected default
    //   [http-loader] prefetch=enabled    ← only if config opt-in
    Log(@"[http-loader] prefetch=%s shared-session=on hmr-kickstart=on",
        s_enabled ? "enabled" : "disabled");
  });
  return s_enabled;
}

//
// Default OFF because the volume is high (one line per fetch, hundreds
// per cold boot, hundreds per HMR refresh). Opt in via
// `nativescript.config.ts`:
//
//     export default {
//       httpFetchUrlLog: true,   // turn on for diagnosis only
//       …
//     };
//
static bool IsHttpFetchUrlLogEnabled() {
  static std::once_flag s_initFlag;
  static bool s_enabled = false;
  std::call_once(s_initFlag, []() {
    @autoreleasepool {
      id value = Runtime::GetAppConfigValue("httpFetchUrlLog");
      if (value && [value respondsToSelector:@selector(boolValue)]) {
        s_enabled = [value boolValue];
      }
    }
    Log(@"[http-loader] fetch-url-log=%s",
        s_enabled ? "enabled" : "disabled");
  });
  return s_enabled;
}

// Periodic always-on summary of prefetcher counters. Logs once every
// kPrefetchSummaryEvery hits+misses+satisfied+failed events, plus
// on the trailing edge of cache cleanup. Always-on (no flag gating)
// because we cannot diagnose this subsystem without it.
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

  size_t cacheSize = 0;
  size_t inflight = 0;
  {
    std::lock_guard<std::mutex> lock(g_prefetchMutex);
    cacheSize = g_prefetchCache.size();
    inflight = g_prefetchInflight.size();
  }

  // Hit rate as integer percent. Avoid divide-by-zero handled above.
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

void ClearHttpModulePrefetchCache() {
  std::lock_guard<std::mutex> lock(g_prefetchMutex);
  g_prefetchCache.clear();
  g_prefetchInflight.clear();
}

// ─────────────────────────────────────────────────────────────────────
// HMR-driven kickstart prefetch.
//
// `g_moduleRegistry` cannot reuse cached compiled modules across
// `__ns_hmr__/v<N>` boundaries: the dev server bumps `graphVersion`
// on every save, and the URL prefix is part of V8's cache key. So
// every save effectively starts cold from V8's perspective even
// though the bodies on disk are identical to the previous save.
//
// The kickstart side-steps this by populating our process-wide
// `g_prefetchCache` with every reachable body BEFORE V8 walks. The
// Angular HMR client invokes `__nsKickstartHmrPrefetch(seedUrl)`
// just before `refreshAngularBootstrapOptions` does its dynamic
// import — the kickstart blocks the JS thread while a 16-way
// parallel BFS over `NSURLSession` (kept-alive) primes the cache.
// When V8 then walks the tree, every `HttpFetchText` call hits the
// cache (~microseconds) instead of the network (~10ms), turning
// 200 × 10ms = 2000ms into one parallel wave that takes ~150–250ms.
//
// Why dispatch_group + a per-call queue. We need ground-truth
// "BFS fully drained" semantics: cleanly transition from parallel
// fetching to V8 module walking with no in-flight fetches that
// could race or duplicate work. dispatch_group_wait gives us
// exactly that. A per-call queue keeps the kickstart's work
// isolated from `g_prefetchQueue` so other HMR cycles or shutdown
// can't accidentally drain the wrong group.
//
// Why we still touch g_prefetchCache (the speculative cache) and
// not a kickstart-only map. `HttpFetchText`'s read path already
// consults `g_prefetchCache`, and that read is destructive — V8 consumes
// each entry exactly once during the walk. Reusing the same map
// guarantees that opt-in speculative `httpModulePrefetch=true`
// users and kickstart-only users share one code path on the read
// side, with no duplicate cache logic to drift.
namespace {

struct KickstartContext {
  std::mutex mutex;
  std::unordered_set<std::string> visited;
  std::atomic<size_t> fetchedCount{0};
  std::atomic<size_t> bytes{0};
  dispatch_group_t group = nullptr;
  dispatch_queue_t queue = nullptr;
  dispatch_semaphore_t concurrency = nullptr;

  ~KickstartContext() {
    // MRC NOTE: HMRSupport.mm is compiled with ARC disabled, so
    // dispatch_release is required for objects we created via
    // dispatch_*_create. By the time the shared_ptr that owns this
    // context goes to zero, dispatch_group_wait has long since
    // returned and every block we scheduled has completed and
    // released its capture of the shared_ptr — so nothing is in
    // flight that could touch these objects after release.
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

    // If a previous wave (or an opt-in speculative prefetch) already
    // landed this body, treat the URL as covered — no point spinning
    // up a fetch we'd discard anyway.
    {
      std::lock_guard<std::mutex> lock(g_prefetchMutex);
      if (g_prefetchCache.find(urlRef) != g_prefetchCache.end()) continue;
    }

    dispatch_group_enter(ctx->group);
    std::string urlCopy = urlRef;
    dispatch_async(ctx->queue, ^{
      dispatch_semaphore_wait(ctx->concurrency, DISPATCH_TIME_FOREVER);

      std::string body;
      std::string contentType;
      int status = 0;
      bool ok = PerformHttpFetchOnceSync(urlCopy, body, contentType, status);

      if (ok && status >= 200 && status < 300 && !body.empty()) {
        size_t bodySize = body.size();
        // Insert (do not overwrite). Another path may have already
        // landed the same URL via the speculative prefetcher; honor
        // whichever copy got there first to avoid wastefully clobbering
        // an already-valid cache entry.
        std::string scanSource;
        {
          std::lock_guard<std::mutex> lock(g_prefetchMutex);
          auto inserted = g_prefetchCache.emplace(urlCopy, std::move(body));
          if (inserted.second) {
            scanSource = inserted.first->second;  // take a copy for off-lock scanning
          } else {
            scanSource = inserted.first->second;
            bodySize = inserted.first->second.size();
          }
        }
        ctx->fetchedCount.fetch_add(1, std::memory_order_relaxed);
        ctx->bytes.fetch_add(bodySize, std::memory_order_relaxed);

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

      dispatch_semaphore_signal(ctx->concurrency);
      dispatch_group_leave(ctx->group);
    });
  }
}

bool KickstartHmrPrefetchSync(const std::string& seedUrl,
                              int maxConcurrent,
                              double timeoutSeconds,
                              size_t* outFetchedCount,
                              uint64_t* outElapsedMs) {
  if (seedUrl.empty()) return false;
  if (!IsRemoteUrlAllowed(seedUrl)) return false;
  if (maxConcurrent <= 0) maxConcurrent = 16;
  if (timeoutSeconds <= 0.0) timeoutSeconds = 10.0;

  const uint64_t startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

  auto ctx = std::make_shared<KickstartContext>();
  ctx->group = dispatch_group_create();
  ctx->queue = dispatch_queue_create("com.nativescript.hmr.kickstart", DISPATCH_QUEUE_CONCURRENT);
  ctx->concurrency = dispatch_semaphore_create(maxConcurrent);

  KickstartScheduleUrls(ctx, std::vector<std::string>{seedUrl});

  dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(timeoutSeconds * NSEC_PER_SEC));
  long timedOut = dispatch_group_wait(ctx->group, deadline);

  const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
  const uint64_t elapsedMs = endUs > startUs ? (endUs - startUs) / 1000ull : 0ull;
  const size_t fetched = ctx->fetchedCount.load(std::memory_order_relaxed);
  const size_t bytes = ctx->bytes.load(std::memory_order_relaxed);

  if (outFetchedCount) *outFetchedCount = fetched;
  if (outElapsedMs) *outElapsedMs = elapsedMs;

  Log(@"[hmr-kickstart] seed=%s fetched=%lu bytes=%lu ms=%llu status=%s concurrency=%d",
      seedUrl.c_str(),
      (unsigned long)fetched,
      (unsigned long)bytes,
      (unsigned long long)elapsedMs,
      timedOut == 0 ? "drained" : "timeout",
      maxConcurrent);

  return timedOut == 0;
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

  // Drop any speculatively-prefetched module sources. These are plain
  // std::string buffers (no v8::Global), but flushing them on teardown
  // prevents stale source from leaking into a re-launched runtime in
  // the same process.
  ClearHttpModulePrefetchCache();
}

} // namespace tns
