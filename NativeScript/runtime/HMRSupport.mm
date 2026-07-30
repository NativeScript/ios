#include "HMRSupport.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include "DevFlags.h"

#include <atomic>
#include <mutex>
#include <string>
#include <vector>
#include "Helpers.h"
#include "ModuleInternalCallbacks.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "Worker.h"
#include "robin_hood.h"

// Use centralized dev flags helper for logging

namespace tns {

static inline bool StartsWith(const std::string& s, const char* prefix) {
  size_t n = strlen(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
}

void MirrorGlobalOnGlobalThis(v8::Isolate* isolate, v8::Local<v8::Context> context,
                              const char* name) {
  std::string src = "if (typeof globalThis !== 'undefined' && typeof globalThis." +
                    std::string(name) +
                    " === 'undefined') {"
                    "  Object.defineProperty(globalThis, '" +
                    std::string(name) + "', { value: this." + std::string(name) +
                    ", writable: true, configurable: true, enumerable: false });"
                    "}";

  v8::Local<v8::Script> script;
  if (v8::Script::Compile(context, tns::ToV8String(isolate, src.c_str())).ToLocal(&script)) {
    script->Run(context).FromMaybe(v8::Local<v8::Value>());
  }
}

static void SetBooleanGlobal(v8::Isolate* isolate, v8::Local<v8::Context> context, const char* key,
                             bool value) {
  context->Global()
      ->Set(context, tns::ToV8String(isolate, key), v8::Boolean::New(isolate, value))
      .FromMaybe(false);
}

// ─────────────────────────────────────────────────────────────
// Dev-boot completion flag
//
// Native-side mirror of `__NS_HMR_BOOT_COMPLETE__`. Read by the
// runloop pump in `MaybePumpJSThreadDuringBoot` so its gate is a
// single relaxed atomic load on the HMR-time hot path. The JS dev
// client flips this via the
// `__NS_DEV__.setDevBootComplete(bool)` global once the real app root view
// commits; boot orchestration itself is entirely userland.
static std::atomic<bool> g_devSessionBootComplete{false};

static inline bool IsDevSessionBootComplete() {
  return g_devSessionBootComplete.load(std::memory_order_relaxed);
}

void SetDevBootComplete(v8::Isolate* isolate, v8::Local<v8::Context> context, bool value) {
  SetBooleanGlobal(isolate, context, "__NS_HMR_BOOT_COMPLETE__", value);
  g_devSessionBootComplete.store(value, std::memory_order_relaxed);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-boot] __NS_HMR_BOOT_COMPLETE__=%s", value ? "true" : "false");
  }
}

// ─────────────────────────────────────────────────────────────
// HTTP loader helpers

// Canonicalization vocabulary (client-supplied policy).
//
// The canonical-key *mechanism* (fragment strip, cache-buster param drop,
// param sort) must be native because it keys the module registry inside
// V8's synchronous resolve walk. The *vocabulary* — which query params are
// pure cache busters, which path prefixes identify dev endpoints whose
// queries may be normalized, and which paths must keep their query verbatim
// because the query IS the identity — is server/framework policy, supplied
// by the dev client via
// `__NS_DEV__.configureRuntime({ canonicalization: {...} })`.
//
// Write-before-read contract: the client configures this once, before the
// first import wave (session-bootstrap order), so plain statics are
// safe here — the same convention as `g_volatilePatterns` / `g_importMap`.
// URLs touched before configuration (the local trampoline's clean
// `/ns/core/*` imports) carry no query, so they canonicalize identically
// under any vocabulary.
//
// When unconfigured, a built-in vocabulary matching current
// `@nativescript/vite` conventions applies.
// TODO(feat/hmr-dev-sessions follow-up): delete the built-in vocabulary once
// the paired `@nativescript/vite` release that sends `canonicalization` has
// been qualified — the runtime should carry zero server/framework URL
// strings.
struct CanonicalizationConfig {
  std::vector<std::string> stripParams;            // query param names to drop
  std::vector<std::string> devPathPrefixes;        // path StartsWith → normalize query
  std::vector<std::string> preserveQueryPrefixes;  // path contains → preserve query verbatim
};
static CanonicalizationConfig g_canonConfig;
static bool g_canonConfigured = false;

static void SetCanonicalizationConfig(CanonicalizationConfig config) {
  g_canonConfig = std::move(config);
  g_canonConfigured = true;
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[__NS_DEV__.configureRuntime] canonicalization set (strip=%lu devPrefixes=%lu "
        @"preserve=%lu)",
        (unsigned long)g_canonConfig.stripParams.size(),
        (unsigned long)g_canonConfig.devPathPrefixes.size(),
        (unsigned long)g_canonConfig.preserveQueryPrefixes.size());
  }
}

static void ResetCanonicalizationConfig() {
  g_canonConfig = CanonicalizationConfig{};
  g_canonConfigured = false;
}

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
  std::string noHash =
      (hashPos == std::string::npos) ? normalizedUrl : normalizedUrl.substr(0, hashPos);

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

  // IMPORTANT: This function is used as an HTTP module registry/cache key.
  // For general-purpose HTTP module loading (public internet), the query string
  // can be part of the module's identity (auth, content versioning, routing, etc).
  // Therefore query normalization (sorting/dropping) applies only to dev
  // endpoints, per the client-supplied vocabulary above.
  //
  // The dev server serves every module under ONE canonical URL — module
  // identity IS the URL string. Freshness after an HMR edit is handled by
  // `__NS_DEV__.invalidateModules` (registry evict) plus the
  // eviction-driven fetch nonce in `PerformHttpFetchOnceSync`, never by URL
  // variation. There is deliberately no path-tag vocabulary to collapse here.
  //
  // Why `preserveQueryFor` exists (and is checked BEFORE the dev-endpoint
  // prefix test, so it covers nested paths like
  // `/ns/m/<componentDir>/@ng/component`): some endpoints' query IS the
  // identity. Angular's `/@ng/component?c=<id>&t=<ts>` is the canonical
  // example — each `t` identifies a specific recompile of the component's
  // metadata, and stripping it would collapse every HMR fetch to the
  // boot-time cache key, so `ɵɵreplaceMetadata` would forever replay stale
  // template instructions ("server logs hmr update, screen never changes").
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    if (g_canonConfigured) {
      for (const auto& p : g_canonConfig.preserveQueryPrefixes) {
        if (!p.empty() && pathOnly.find(p) != std::string::npos) {
          return noHash;  // query preserved verbatim (fragment already removed)
        }
      }
      bool isDevEndpoint = false;
      for (const auto& p : g_canonConfig.devPathPrefixes) {
        if (!p.empty() && StartsWith(pathOnly, p.c_str())) {
          isDevEndpoint = true;
          break;
        }
      }
      if (!isDevEndpoint) {
        return noHash;
      }
    } else {
      // Built-in fallback vocabulary — see the deletion TODO above.
      if (pathOnly.find("/@ng/component") != std::string::npos) {
        return noHash;
      }
      const bool isDevEndpoint = StartsWith(pathOnly, "/ns/") ||
                                 StartsWith(pathOnly, "/node_modules/.vite/") ||
                                 StartsWith(pathOnly, "/@id/") || StartsWith(pathOnly, "/@fs/");
      if (!isDevEndpoint) {
        return noHash;
      }
    }
  }

  if (query.empty()) return originAndPath;

  // Keep all params except the configured cache busters; sort for stability.
  std::vector<std::string> kept;
  size_t start = 0;
  while (start <= query.size()) {
    size_t amp = query.find('&', start);
    std::string pair =
        (amp == std::string::npos) ? query.substr(start) : query.substr(start, amp - start);
    if (!pair.empty()) {
      size_t eq = pair.find('=');
      std::string name = (eq == std::string::npos) ? pair : pair.substr(0, eq);
      bool drop;
      if (g_canonConfigured) {
        drop = std::find(g_canonConfig.stripParams.begin(), g_canonConfig.stripParams.end(),
                         name) != g_canonConfig.stripParams.end();
      } else {
        // Built-in fallback: Vite's import marker and t/v cache stamps.
        drop = (name == "import" || name == "t" || name == "v");
      }
      if (!drop) kept.push_back(pair);
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

// ─────────────────────────────────────────────────────────────
// Eviction-driven fetch cache-bust
//
// When the HMR client invalidates a module, the NEXT network fetch of
// that module must not be satisfiable by any OS-level HTTP cache
// (CFNetwork's fsCachedData has been observed serving a previous
// save's body on iOS 18+/26+ Simulator even with `no-store` headers
// and a reload-ignoring cache policy). `InvalidateModules` marks the
// canonical keys of the eviction set here; `PerformHttpFetchOnceSync`
// then appends a unique `__ns_dev_nonce` query parameter to the
// wire-level request for any marked URL, guaranteeing CFNetwork sees
// a URL it has never cached. The nonce is transport-only — it never
// enters the module registry key (identity stays the canonical URL),
// and the server and the registry never see a varied URL.
static std::mutex g_bustNextFetchMutex;
static robin_hood::unordered_set<std::string> g_bustNextFetchKeys;

void MarkUrlsForCacheBust(const std::vector<std::string>& urls) {
  if (urls.empty()) return;
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  for (const auto& url : urls) {
    if (url.empty()) continue;
    if (!(StartsWith(url, "http://") || StartsWith(url, "https://"))) continue;
    g_bustNextFetchKeys.insert(CanonicalizeHttpUrlKey(url));
  }
}

// Peek (do not consume) — the fetch may be retried on transient failure
// and the retry must still carry a nonce. Cleared on fetch success.
static bool IsUrlMarkedForCacheBust(const std::string& url) {
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  if (g_bustNextFetchKeys.empty()) return false;
  return g_bustNextFetchKeys.find(CanonicalizeHttpUrlKey(url)) != g_bustNextFetchKeys.end();
}

static void ClearCacheBustForUrl(const std::string& url) {
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  if (g_bustNextFetchKeys.empty()) return;
  g_bustNextFetchKeys.erase(CanonicalizeHttpUrlKey(url));
}

static void ClearAllCacheBustMarks() {
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  g_bustNextFetchKeys.clear();
}

// ============================================================================
// HTTP module fetching
// ============================================================================
//
// Two fetch primitives back the HTTP ESM loader:
//   - `HttpFetchText` — the synchronous fetch V8's ResolveModuleCallback
//     falls back to for anything the async module-graph walk missed
//     (the callback is synchronous — still true as of 14.9.207.39 — so
//     this fallback must be native and blocking).
//   - `FetchModuleBodyAsync` — the NSURLSession-backed primitive behind
//     the phase-1 async graph walk (StartAsyncHttpModuleGraphLoad),
//     which fetches the transitive closure concurrently off the JS
//     thread before instantiation begins.
//
// There is deliberately NO body prewarm cache and NO JS-driven prefetch
// API here. Measurement (see docs/knowledge/hmr-simplification-pass.md)
// showed the async discovery walk beats server-computed
// closure/archive seeding on real apps — concurrent fetches overlap
// with on-device compile, while seeding serializes a full server-side
// transform pass before the entry can start.

// Forward declarations — these helpers are defined below their first use,
// matching the existing convention in this file.
static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out,
                                     std::string& contentType, int& status);
static void MaybePumpJSThreadDuringBoot();
// Forward decl: the pluggable HTTP-fetch yield hook is defined below
// MaybePumpJSThreadDuringBoot (which is its default callback), but HttpFetchText
// calls it from earlier in the file. See the definition for the rationale on
// the atomic indirection.
static inline void InvokeHttpFetchYield();

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
static std::atomic<size_t> g_fetchSyncFast{0};    // <10ms
static std::atomic<size_t> g_fetchSyncMedium{0};  // 10–99ms
static std::atomic<size_t> g_fetchSyncSlow{0};    // >=100ms
static constexpr size_t kFetchSyncSummaryEvery = 100;

bool HttpFetchText(const std::string& url, std::string& out, std::string& contentType,
                   int& status) {
  // Security gate: check if remote module loading is allowed before any HTTP fetch.
  // This is the single point of enforcement for all HTTP module loading.
  if (!IsRemoteUrlAllowed(url)) {
    status = 403;  // Forbidden
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][security][blocked] %s", url.c_str());
    }
    return false;
  }

  // Hoist the URL-log flag once per call so the success branches below pay
  // one TLS read instead of two.
  const bool urlLogEnabled = IsHttpFetchUrlLogEnabled();

  // Synchronous fetch with one retry on failure.
  // Time the network branch end-to-end so the per-URL log can
  // attribute milliseconds to each fetch. We measure here (not
  // inside PerformHttpFetchOnceSync) so the retry interval gets
  // billed to the URL too — which is what the user sees as "this
  // URL was slow".
  const uint64_t netStartUs =
      urlLogEnabled ? (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0) : 0ull;
  bool ok = PerformHttpFetchOnceSync(url, out, contentType, status);
  if (!ok) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader] retrying %s after initial fetch error", url.c_str());
    }
    usleep(120 * 1000);
    ok = PerformHttpFetchOnceSync(url, out, contentType, status);
  }
  // NOTE: no long dev-server-startup retry loop here on purpose. The CLI's
  // `compileWithWatch` gates app deploy/restart on its `vite serve`
  // readiness probe (bundler-compiler-service), so a connection-refused at
  // boot is a real failure, not a startup race — surface it immediately.
  if (!ok || status < 200 || status >= 300) {
    return false;
  }
  // An empty 2xx body is a VALID module response: type-only TypeScript
  // modules legitimately transform to zero runtime code (Vite's /@fs
  // endpoint serves them as empty 200s). Substitute the canonical empty ESM
  // module — treating this as a fetch failure kills the entire dev-session
  // graph with a misleading "HTTP import failed (status=200)".
  if (out.empty()) {
    out = "export {};\n";
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader] empty 2xx body for %s — serving canonical empty module", url.c_str());
    }
  }
  if (IsScriptLoadingLogEnabled()) {
    unsigned long long blen = (unsigned long long)out.size();
    const char* ctstr = contentType.empty() ? "<none>" : contentType.c_str();
    Log(@"[http-loader] fetched status=%d content-type=%s bytes=%llu", status, ctstr, blen);
  }
  if (urlLogEnabled) {
    const uint64_t netEndUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t netMs = netEndUs > netStartUs ? (netEndUs - netStartUs) / 1000ull : 0ull;
    Log(@"[http-loader][fetch][network] %s bytes=%lu ms=%llu", url.c_str(),
        (unsigned long)out.size(), (unsigned long long)netMs);
  }

  // Yield to the placeholder heartbeat after the 10–60ms sync fetch
  // block so the bar can repaint before V8 calls us again.
  InvokeHttpFetchYield();
  return true;
}

// Synchronous HTTP fetcher implementation.
//
// We use `+[NSURLConnection sendSynchronousRequest:returningResponse:error:]`
// (deprecated but functional on every shipping iOS version) instead of
// the modern NSURLSession API. NSURLSession exhibits a deadlock when the
// JS thread is the iOS main thread (post-Angular bootstrap):
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
// explicit non-main `NSOperationQueue`. Boot-time sync fetches
// (thousands of them) succeed because they happen before the iOS main
// thread becomes the JS executor.
//
// `NSURLConnection.sendSynchronousRequest` uses CFNetwork directly,
// bypassing NSURLSession's task lifecycle, and returns the NSURLResponse
// so we can read HTTP status and Content-Type. The deprecation warning
// is suppressed locally because every published Apple SDK still ships
// a working implementation, and there is currently no non-deprecated
// API that gives us a runloop-independent synchronous fetch with a
// real HTTP status code.
// Shared request builder for the sync (NSURLConnection) and async
// (NSURLSession) module fetch paths so both carry identical cache-defeat
// semantics. Returns an autoreleased NSMutableURLRequest (nil for
// unparseable URLs) and reports via `outBustRequested` whether the URL was
// marked for an eviction-driven cache-bust nonce (the caller clears the
// mark once a fresh body actually arrives).
static NSMutableURLRequest* BuildModuleFetchRequest(const std::string& url,
                                                    bool* outBustRequested) {
  // One-time: replace the shared NSURLCache with a zero-capacity one
  // so CFNetwork has no on-disk store to satisfy fetches from. Per-
  // request cache policy + `removeCachedResponseForRequest:` were
  // empirically insufficient on iOS 18+/26+ Simulator — fsCachedData
  // would still serve a previous save's body for a just-updated URL.
  static dispatch_once_t s_cacheDisableOnce;
  dispatch_once(&s_cacheDisableOnce, ^{
    NSURLCache* nullCache = [[NSURLCache alloc] initWithMemoryCapacity:0
                                                          diskCapacity:0
                                                          directoryURL:nil];
    [NSURLCache setSharedURLCache:nullCache];
  });

  // Eviction-driven cache-bust: if this URL's canonical key was marked
  // by `InvalidateModules` (via `MarkUrlsForCacheBust`), append a
  // unique nonce query parameter so CFNetwork sees a different URL
  // and cannot satisfy the request from any cache layer. The dev
  // server ignores unknown query params on module routes, so the
  // response body is unchanged. First-touch fetches don't need
  // busting — nothing has cached them yet — so unmarked URLs go out
  // verbatim (some Vite virtual routes require exact-match URLs and
  // 404 on unknown query params).
  std::string fetchUrl = url;
  const bool bustRequested = IsUrlMarkedForCacheBust(url);
  if (outBustRequested) *outBustRequested = bustRequested;
  if (bustRequested) {
    static std::atomic<uint64_t> s_fetchSeq{0};
    const uint64_t seq = s_fetchSeq.fetch_add(1, std::memory_order_relaxed);
    const uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    fetchUrl += (url.find('?') == std::string::npos) ? '?' : '&';
    fetchUrl += "__ns_dev_nonce=";
    fetchUrl += std::to_string(nowMs);
    fetchUrl += "-";
    fetchUrl += std::to_string(seq);
  }

  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:fetchUrl.c_str()]];
  if (!u) {
    return nil;
  }

  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:u];
  [request setHTTPMethod:@"GET"];
  [request setValue:@"application/javascript, text/javascript, */*;q=0.1"
      forHTTPHeaderField:@"Accept"];
  [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
  [request setTimeoutInterval:5.0];
  // CRITICAL for HMR: layered defense to bypass CFNetwork's URL cache.
  // `setCachePolicy:` alone is insufficient on iOS 18+/26+ Simulator —
  // CFNetwork still serves a previous save's body from fsCachedData.
  // Combined with the zero-capacity sharedURLCache and the eviction-
  // driven URL nonce above, these give us a reliable "always go to
  // origin" path for the dev runtime.
  [request setValue:@"no-cache, no-store, max-age=0" forHTTPHeaderField:@"Cache-Control"];
  [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
  // Force a fresh TCP connection per fetch. CFNetwork has been
  // observed to serve a body buffered on a kept-alive HTTP/1.1
  // connection for a prior fetch when a new fetch reuses it.
  [request setValue:@"close" forHTTPHeaderField:@"Connection"];
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

  return request;
}

static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out,
                                     std::string& contentType, int& status) {
  @autoreleasepool {
    bool bustRequested = false;
    NSMutableURLRequest* request = BuildModuleFetchRequest(url, &bustRequested);
    if (!request) {
      status = 0;
      return false;
    }

    NSError* err = nil;
    NSInteger httpStatusLocal = 0;
    std::string contentTypeLocal;
    std::string bodyLocal;

    const auto fetchStartUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

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
      httpStatusLocal = [httpResp statusCode];
      NSString* ct = [httpResp allHeaderFields][@"Content-Type"];
      if (ct) {
        const char* utf8 = [ct UTF8String];
        if (utf8) contentTypeLocal = std::string(utf8);
      }
    }

    if (data && [data length] > 0) {
      const void* bytes = [data bytes];
      NSUInteger len = [data length];
      bodyLocal.assign(static_cast<const char*>(bytes), static_cast<size_t>(len));
    }

    const auto fetchEndUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t fetchMs =
        fetchEndUs > fetchStartUs ? (fetchEndUs - fetchStartUs) / 1000ull : 0ull;
    g_fetchSyncTotalMs.fetch_add(fetchMs, std::memory_order_relaxed);
    if (fetchMs < 10) {
      g_fetchSyncFast.fetch_add(1, std::memory_order_relaxed);
    } else if (fetchMs < 100) {
      g_fetchSyncMedium.fetch_add(1, std::memory_order_relaxed);
    } else {
      g_fetchSyncSlow.fetch_add(1, std::memory_order_relaxed);
    }
    const size_t syncCount = g_fetchSyncCount.fetch_add(1, std::memory_order_relaxed) + 1;
    if (syncCount > 0 && syncCount % kFetchSyncSummaryEvery == 0 && IsScriptLoadingLogEnabled()) {
      const size_t fast = g_fetchSyncFast.load(std::memory_order_relaxed);
      const size_t medium = g_fetchSyncMedium.load(std::memory_order_relaxed);
      const size_t slow = g_fetchSyncSlow.load(std::memory_order_relaxed);
      const uint64_t totalMs = g_fetchSyncTotalMs.load(std::memory_order_relaxed);
      const uint64_t avgMs = syncCount ? totalMs / (uint64_t)syncCount : 0;
      Log(@"[http-loader][fetch-sync][summary] count=%lu avg=%llums fast(<10ms)=%lu medium=%lu "
          @"slow(>=100ms)=%lu",
          (unsigned long)syncCount, (unsigned long long)avgMs, (unsigned long)fast,
          (unsigned long)medium, (unsigned long)slow);
    }

    status = (int)httpStatusLocal;
    contentType = contentTypeLocal;
    // An empty body on a 2xx with no transport error is a legitimate
    // response (type-only TS modules transform to zero runtime code —
    // Vite serves them as empty 200s). Only transport errors and empty
    // non-2xx responses are fetch failures; HttpFetchText normalizes the
    // empty-success body to the canonical empty module.
    const bool emptyNon2xx = bodyLocal.empty() && (httpStatusLocal < 200 || httpStatusLocal >= 300);
    if (err != nil || emptyNon2xx) {
      if (IsScriptLoadingLogEnabled()) {
        NSString* desc = err.localizedDescription ?: @"<no description>";
        NSString* domain = err.domain ?: @"<no domain>";
        Log(@"[http-loader][fetch-error] url=%s domain=%@ code=%ld desc=%@ status=%ld bodyEmpty=%d "
            @"ms=%llu",
            url.c_str(), domain, (long)err.code, desc, (long)httpStatusLocal,
            bodyLocal.empty() ? 1 : 0, (unsigned long long)fetchMs);
      }
      return false;
    }
    out.swap(bodyLocal);
    // A fresh body arrived from origin — the bust request (if any) has
    // been satisfied. Clear the mark so steady-state re-fetches of the
    // same URL don't keep paying the nonce (and stay exact-match for
    // routes that require it).
    if (bustRequested) {
      ClearCacheBustForUrl(url);
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────
// Async module fetch (NSURLSession)
//
// The async pipeline's fetches never block the JS thread, so the
// NSURLConnection workaround documented above PerformHttpFetchOnceSync does
// not apply here: that deadlock is specific to *synchronously waiting* on an
// NSURLSession task from the iOS main thread. Fire-and-forget tasks with a
// background delegate queue are the intended NSURLSession usage.
//
// The session is ephemeral with a nil URLCache — the layered cache defeats
// in BuildModuleFetchRequest assume CFNetwork cannot satisfy any module
// request from a cache, and an ephemeral cacheless session is the strongest
// form of that guarantee.
static NSURLSession* ModuleFetchSession() {
  static NSURLSession* s_session = nil;
  static dispatch_once_t s_once;
  dispatch_once(&s_once, ^{
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    config.HTTPShouldSetCookies = NO;
    config.timeoutIntervalForRequest = 10.0;
    config.HTTPMaximumConnectionsPerHost = 16;
    // ARC is disabled in this file: sessionWithConfiguration: returns an
    // autoreleased object; retain it for the process-lifetime singleton.
    s_session = [[NSURLSession sessionWithConfiguration:config] retain];
  });
  return s_session;
}

// One network attempt for FetchModuleBodyAsync. Takes ownership of
// `completionHeap` (heap-allocated so the ObjC block can carry the
// std::function across threads without ARC) and guarantees exactly one
// invocation + delete. Retries once on transport error, mirroring the
// single-retry policy of the synchronous path.
static void PerformModuleFetchAsyncAttempt(
    const std::string& url, int attempt,
    std::function<void(bool ok, int status, std::string body)>* completionHeap) {
  @autoreleasepool {
    bool bustRequested = false;
    NSMutableURLRequest* request = BuildModuleFetchRequest(url, &bustRequested);
    if (!request) {
      (*completionHeap)(false, 0, std::string());
      delete completionHeap;
      return;
    }

    const std::string urlCopy = url;
    const bool bust = bustRequested;
    const uint64_t startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    NSURLSessionDataTask* task = [ModuleFetchSession()
        dataTaskWithRequest:request
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            int status = 0;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
              status = (int)[(NSHTTPURLResponse*)response statusCode];
            }
            std::string body;
            if (data && [data length] > 0) {
              body.assign(static_cast<const char*>([data bytes]),
                          static_cast<size_t>([data length]));
            }

            // Transport error → one retry (parity with HttpFetchText's
            // usleep(120ms)+retry, without blocking any thread).
            if (error != nil && attempt == 0) {
              if (IsScriptLoadingLogEnabled()) {
                Log(@"[http-loader][fetch-async] retrying %s after transport error: %@",
                    urlCopy.c_str(), error.localizedDescription ?: @"<no description>");
              }
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                             dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                               PerformModuleFetchAsyncAttempt(urlCopy, 1, completionHeap);
                             });
              return;
            }

            const bool ok = (error == nil) && status >= 200 && status < 300;
            if (ok && body.empty()) {
              // Empty 2xx bodies are valid module responses (type-only TS
              // modules) — same normalization as the sync path.
              body = "export {};\n";
            }
            if (ok && bust) {
              ClearCacheBustForUrl(urlCopy);
            }
            if (!ok && IsScriptLoadingLogEnabled()) {
              NSString* desc =
                  error ? (error.localizedDescription ?: @"<no description>") : @"<http status>";
              Log(@"[http-loader][fetch-async][error] url=%s status=%d attempt=%d desc=%@",
                  urlCopy.c_str(), status, attempt, desc);
            }
            if (ok && IsHttpFetchUrlLogEnabled()) {
              const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
              const uint64_t ms = endUs > startUs ? (endUs - startUs) / 1000ull : 0ull;
              Log(@"[http-loader][fetch][async] %s bytes=%lu ms=%llu", urlCopy.c_str(),
                  (unsigned long)body.size(), (unsigned long long)ms);
            }
            (*completionHeap)(ok, status, std::move(body));
            delete completionHeap;
          }];
    [task resume];
  }
}

void FetchModuleBodyAsync(const std::string& url,
                          std::function<void(bool ok, int status, std::string body)> completion) {
  // Security gate: single point of enforcement, same as HttpFetchText.
  if (!IsRemoteUrlAllowed(url)) {
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-esm][security][blocked] %s", url.c_str());
    }
    completion(false, 403, std::string());
    return;
  }

  auto* completionHeap = new std::function<void(bool, int, std::string)>(std::move(completion));
  PerformModuleFetchAsyncAttempt(url, 0, completionHeap);
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
//     background threads, so they never pump someone else's runloop.
//   - `IsDevSessionBootComplete()` short-circuits once the dev client
//     has committed its first stable view (it calls
//     `__NS_DEV__.setDevBootComplete(true)`) — no placeholder to repaint, and
//     HMR-time fetches must not pay the pump cost.
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

void CleanupHMRGlobals() {
  ClearAllCacheBustMarks();
  // Reset the boot-complete flag so a re-launched runtime in the same
  // process starts in "cold boot" mode again (runloop pump armed).
  g_devSessionBootComplete.store(false, std::memory_order_relaxed);
  // Drop the client-supplied canonicalization vocabulary so a re-launched
  // runtime starts from the built-in fallback until its own client
  // configures it.
  ResetCanonicalizationConfig();
}

// ─────────────────────────────────────────────────────────────
// Dev-loader JS-callable globals
//
// The runtime's dev surface is deliberately small: it exposes
// *mechanism* only (resolution config, registry eviction, registry
// introspection, boot-complete signal). All HMR *policy* — boot
// orchestration, `import.meta.hot`, full reload, CSS apply, WebSocket
// protocol — lives in the JS dev client (`@nativescript/vite`).

namespace {

// Sets the function name on the v8 Function for nicer stack traces and
// attaches it as a method of the `__NS_DEV__` namespace object.
void InstallDevFunction(v8::Isolate* isolate, v8::Local<v8::Context> context,
                        v8::Local<v8::Object> target, const char* name,
                        v8::FunctionCallback callback) {
  v8::Local<v8::FunctionTemplate> fnTpl = v8::FunctionTemplate::New(isolate, callback);
  v8::Local<v8::Function> fn = fnTpl->GetFunction(context).ToLocalChecked();
  fn->SetName(tns::ToV8String(isolate, name));
  target->CreateDataProperty(context, tns::ToV8String(isolate, name), fn).Check();
}

void ConfigureDevRuntimeCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  bool logScriptLoading = tns::IsScriptLoadingLogEnabled();

  if (info.Length() < 1 || !info[0]->IsObject()) {
    if (logScriptLoading) {
      Log(@"[__NS_DEV__.configureRuntime] expected config object argument");
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
    if (!jsonStr.empty()) {
      SetImportMap(jsonStr);
      if (logScriptLoading) {
        Log(@"[__NS_DEV__.configureRuntime] import map set (%zu bytes)", jsonStr.size());
      }
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
      if (logScriptLoading) {
        Log(@"[__NS_DEV__.configureRuntime] %zu volatile patterns set", patterns.size());
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
    Log(@"[__NS_DEV__.invalidateModules] expected array of URL strings");
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

// `__NS_DEV__.setDevBootComplete(value?: boolean)` — the JS dev client calls
// this (with `true`, or no argument) once the real app root view has
// committed. It flips both the JS-visible `__NS_HMR_BOOT_COMPLETE__`
// global and the native atomic that disarms the cold-boot runloop pump.
// The client may also pass `false` before a full JS-realm reload to
// re-arm the boot-time behaviors.
void SetDevBootCompleteCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  bool value = true;
  if (info.Length() >= 1 && !info[0]->IsUndefined() && !info[0]->IsNull()) {
    value = info[0]->BooleanValue(isolate);
  }

  tns::SetDevBootComplete(isolate, ctx, value);
}

}  // namespace

void InitializeHmrDevGlobals(v8::Isolate* isolate, v8::Local<v8::Context> context, bool isWorker) {
  // The dev host API lives here: `__NS_DEV__`.
  v8::Local<v8::Object> dev = v8::Object::New(isolate);

  InstallDevFunction(isolate, context, dev, "configureRuntime", ConfigureDevRuntimeCallback);
  InstallDevFunction(isolate, context, dev, "invalidateModules", InvalidateModulesCallback);
  InstallDevFunction(isolate, context, dev, "getLoadedModuleUrls", GetLoadedModuleUrlsCallback);
  InstallDevFunction(isolate, context, dev, "setDevBootComplete", SetDevBootCompleteCallback);

  // Main-isolate only: terminating workers from inside a worker would let
  // a stuck worker take down its peers (see Worker.h).
  if (!isWorker) {
    InstallDevFunction(isolate, context, dev, "terminateAllWorkers",
                       Worker::TerminateAllWorkersCallback);
  }

  if (RuntimeConfig.IsDebug) {
    try {
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
      v8::Local<v8::Function> fn = v8::Function::New(context, canonicalizeCb).ToLocalChecked();
      fn->SetName(tns::ToV8String(isolate, "canonicalizeHttpUrlKey"));
      dev->CreateDataProperty(context, tns::ToV8String(isolate, "canonicalizeHttpUrlKey"), fn)
          .Check();
    } catch (...) {
      // Don't crash if debug-diagnostic setup fails
    }
  }

  context->Global()->Set(context, tns::ToV8String(isolate, "__NS_DEV__"), dev).FromMaybe(false);
  MirrorGlobalOnGlobalThis(isolate, context, "__NS_DEV__");
}

}  // namespace tns
