#include "HMRSupport.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include "DevFlags.h"

#include <unordered_map>
#include <vector>
#include <string>
#include "Helpers.h"

// Use centralized dev flags helper for logging

namespace tns {

static inline bool StartsWith(const std::string& s, const char* prefix) {
  size_t n = strlen(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
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

  // Helper to capture key in function data
  auto makeKeyData = [&](const std::string& key) -> Local<Value> {
    return tns::ToV8String(isolate, key.c_str());
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

  Local<Object> hot = Object::New(isolate);
  // Stable flags
  hot->CreateDataProperty(context, tns::ToV8String(isolate, "data"),
                          GetOrCreateHotData(isolate, modulePath)).Check();
  hot->CreateDataProperty(context, tns::ToV8String(isolate, "prune"),
                          v8::Boolean::New(isolate, false)).Check();
  // Methods
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "accept"),
      v8::Function::New(context, acceptCb, makeKeyData(modulePath)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "dispose"),
      v8::Function::New(context, disposeCb, makeKeyData(modulePath)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "decline"),
      v8::Function::New(context, declineCb, makeKeyData(modulePath)).ToLocalChecked()).Check();
  hot->CreateDataProperty(
    context, tns::ToV8String(isolate, "invalidate"),
      v8::Function::New(context, invalidateCb, makeKeyData(modulePath)).ToLocalChecked()).Check();

  // Attach to import.meta
  importMeta->CreateDataProperty(
    context, tns::ToV8String(isolate, "hot"),
    hot).Check();
}

// ─────────────────────────────────────────────────────────────
// Dev HTTP loader helpers

std::string CanonicalizeHttpUrlKey(const std::string& url) {
  if (!(StartsWith(url, "http://") || StartsWith(url, "https://"))) {
    return url;
  }
  // Drop fragment entirely
  size_t hashPos = url.find('#');
  std::string noHash = (hashPos == std::string::npos) ? url : url.substr(0, hashPos);

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

  // Normalize bridge endpoints to keep a single realm across HMR updates:
  // - /ns/rt/<ver>    -> /ns/rt
  // - /ns/core/<ver>  -> /ns/core
  // Preserve query params (e.g. /ns/core?p=...) as part of module identity.
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

  if (query.empty()) return originAndPath;

  // Keep all params except Vite's import marker; sort for stability.
  std::vector<std::string> kept;
  size_t start = 0;
  while (start <= query.size()) {
    size_t amp = query.find('&', start);
    std::string pair = (amp == std::string::npos) ? query.substr(start) : query.substr(start, amp - start);
    if (!pair.empty()) {
      size_t eq = pair.find('=');
      std::string name = (eq == std::string::npos) ? pair : pair.substr(0, eq);
      if (!(name == "import")) kept.push_back(pair);
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
  
  @autoreleasepool {
    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    if (!u) { status = 0; return false; }

    __block NSError* err = nil;
    __block NSInteger httpStatusLocal = 0;
    __block std::string contentTypeLocal;
    __block std::string bodyLocal;

    auto fetchOnce = ^BOOL(NSURL* reqUrl) {
      bodyLocal.clear();
      err = nil;
      httpStatusLocal = 0;
      contentTypeLocal.clear();
      NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
      cfg.HTTPAdditionalHeaders = @{ @"Accept": @"application/javascript, text/javascript, */*;q=0.1",
                                     @"Accept-Encoding": @"identity" };
      // Note: this could be made configurable if needed
      cfg.timeoutIntervalForRequest = 5.0;
      cfg.timeoutIntervalForResource = 5.0;
      NSURLSession* session = [NSURLSession sessionWithConfiguration:cfg];
      dispatch_semaphore_t sema = dispatch_semaphore_create(0);
      NSURLSessionDataTask* task = [session dataTaskWithURL:reqUrl
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
      [session finishTasksAndInvalidate];
      return err == nil && !bodyLocal.empty();
    };

    BOOL ok = fetchOnce(u);
    if (!ok) {
      if (tns::IsScriptLoadingLogEnabled()) { Log(@"[http-loader] retrying %s after initial fetch error", url.c_str()); }
      usleep(120 * 1000);
      ok = fetchOnce(u);
    }

    status = (int)httpStatusLocal;
    contentType = contentTypeLocal;
    if (!ok || status < 200 || status >= 300) {
      return false;
    }

    out.swap(bodyLocal);
    if (out.empty()) return false;
    if (tns::IsScriptLoadingLogEnabled()) {
      unsigned long long blen = (unsigned long long)out.size();
      const char* ctstr = contentType.empty() ? "<none>" : contentType.c_str();
      Log(@"[http-loader] fetched status=%ld content-type=%s bytes=%llu", (long)status, ctstr, blen);
    }
    return true;
  }
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
}

} // namespace tns
