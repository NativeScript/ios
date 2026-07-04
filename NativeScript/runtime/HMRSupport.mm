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
#include "Worker.h"

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

void MirrorGlobalOnGlobalThis(v8::Isolate* isolate, v8::Local<v8::Context> context,
                              const char* name) {
  std::string src =
      "if (typeof globalThis !== 'undefined' && typeof globalThis." +
      std::string(name) +
      " === 'undefined') {"
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

static void SetBooleanGlobal(v8::Isolate* isolate, v8::Local<v8::Context> context,
                             const char* key, bool value) {
  context->Global()
      ->Set(context, tns::ToV8String(isolate, key), v8::Boolean::New(isolate, value))
      .FromMaybe(false);
}

// ─────────────────────────────────────────────────────────────
// Dev-boot completion flag
//
// Native-side mirror of `__NS_HMR_BOOT_COMPLETE__`. Read by the
// runloop pump in `MaybePumpJSThreadDuringBoot` (and the cold-boot
// kickstart wait) so their gate is a single relaxed atomic load on
// the HMR-time hot path. The JS dev client flips this via the
// `__NS_DEV__.setDevBootComplete(bool)` global once the real app root view
// commits; boot orchestration itself is entirely userland.
static std::atomic<bool> g_devSessionBootComplete{false};

static inline bool IsDevSessionBootComplete() {
  return g_devSessionBootComplete.load(std::memory_order_relaxed);
}

void SetDevBootComplete(v8::Isolate* isolate, v8::Local<v8::Context> context,
                        bool value) {
  SetBooleanGlobal(isolate, context, "__NS_HMR_BOOT_COMPLETE__", value);
  g_devSessionBootComplete.store(value, std::memory_order_relaxed);
  if (IsScriptLoadingLogEnabled()) {
    Log(@"[dev-boot] __NS_HMR_BOOT_COMPLETE__=%s", value ? "true" : "false");
  }
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

  // IMPORTANT: This function is used as an HTTP module registry/cache key.
  // For general-purpose HTTP module loading (public internet), the query string
  // can be part of the module's identity (auth, content versioning, routing, etc).
  // Therefore we only apply query normalization (sorting/dropping) for known
  // NativeScript dev endpoints where `t`/`v`/`import` are purely cache busters.
  //
  // The dev server serves every module under ONE canonical URL — module
  // identity IS the URL string. Freshness after an HMR edit is handled by
  // `__NS_DEV__.invalidateModules` (registry + prefetch-cache evict) plus the
  // eviction-driven fetch nonce in `PerformHttpFetchOnceSync`, never by URL
  // variation. There is deliberately no path-tag vocabulary to collapse here.
  //
  // Special cases that LOOK like dev endpoints but aren't normalized:
  //
  //   `/@ng/component` (Angular HMR component-update endpoint)
  //     The `t` (timestamp) parameter is the WHOLE POINT of the URL — it
  //     identifies a specific recompile of the component's metadata after
  //     a `.html`/style edit. Stripping it would collapse every HMR fetch
  //     to the same cache key (the boot-time call uses `Date.now()` and
  //     each subsequent save uses a new `Date.now()`), and the second
  //     `__ns_import(...)` would hit V8's module cache, resolve the
  //     boot-time `_UpdateMetadata` default export, and call
  //     `ɵɵreplaceMetadata` with stale instructions. Result: server logs
  //     `(client) hmr update`, the listener fires, but the visual never
  //     changes because the runtime swapped the live view's metadata
  //     with the same metadata it already had. Treat the path as a
  //     non-dev endpoint and preserve the query verbatim so each
  //     timestamped fetch is a distinct registry entry.
  //
  // Apply the special-case check BEFORE the dev-endpoint short-circuit so
  // it covers paths under `/ns/m/<componentDir>/@ng/component` (the
  // resolved URL Angular's compiler produces relative to the component's
  // `import.meta.url`).
  {
    std::string pathOnly = originAndPath.substr(pathStart);
    if (pathOnly.find("/@ng/component") != std::string::npos) {
      // Preserve query as-is — `t` is the version discriminator.
      return noHash;
    }
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
static std::unordered_set<std::string> g_bustNextFetchKeys;

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
// HTTP body cache + parallel kickstart prewarm
// ============================================================================
//
// V8 10.3.22 only exposes a synchronous ResolveModuleCallback for static
// imports. Each call into HttpFetchText() blocks the JS thread on a
// synchronous network turn, which forces serial fetching from the JS
// thread's perspective.
//
// `__NS_DEV__.kickstartPrefetch(urls)` lets the JS dev client hand the runtime
// a server-computed module closure (cold-boot graph or HMR eviction set)
// to fetch in one parallel wave BEFORE V8 walks the import graph. Bodies
// land in `g_prefetchCache` keyed by full URL; the always-on cache read in
// `HttpFetchText` then serves V8's synchronous walk at memory speed.
//
// The runtime performs NO import scanning and NO speculative graph
// discovery of its own — the server owns the module graph and supplies
// explicit URL lists.
//
// Correctness invariants:
//   1. Cache reads consume (one-shot). A second HttpFetchText for the
//      same URL after a cache hit triggers a fresh network fetch — this
//      is the right behavior for HMR where re-fetching means we got a
//      newer version of the module.
//   2. Every kickstart fetch goes through IsRemoteUrlAllowed() exactly
//      the same way HttpFetchText does. The security gate is preserved.
//   3. Kickstart overwrites cache entries unconditionally — a body the
//      client explicitly asked to re-fetch is authoritative by
//      construction (the previous entry is stale).

// Forward declarations — these helpers are defined below their first use,
// matching the existing convention in this file.
static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out, std::string& contentType, int& status);
static bool LooksLikeJsSourceUrl(const std::string& url);
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

// Always-on diagnostic counters. These intentionally do NOT gate behind
// IsScriptLoadingLogEnabled() — without this signal we cannot tell a
// helping prewarm cache from a hurting one.
static std::atomic<size_t> g_prefetchHits{0};            // V8 asked for a URL we had cached
static std::atomic<size_t> g_prefetchMisses{0};          // V8 asked for a URL we did not have

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

  // Hoist the URL-log flag once per call so the two success branches
  // below pay one TLS read instead of two.
  const bool urlLogEnabled = IsHttpFetchUrlLogEnabled();

  // Cache-read fast path. The JS dev client populates `g_prefetchCache`
  // via `__NS_DEV__.kickstartPrefetch(urls)` right before importing (cold
  // boot) or re-importing (HMR); by the time V8's synchronous walk asks
  // for a module, the body is already here and the walk runs at memory
  // speed instead of network speed.
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
      // Per-URL diagnostic. Distinguish prewarm-cache hits from
      // network fetches so we can attribute who actually paid for
      // each module body. ms is omitted because the cache lookup is
      // effectively instantaneous compared to network I/O.
      Log(@"[http-loader][fetch][prefetch] %s bytes=%lu",
          url.c_str(), (unsigned long)out.size());
    }
    MaybeLogPrefetchSummary("hit");
    // Yield to the placeholder heartbeat between cache hits — without
    // this the runloop is starved by back-to-back HttpFetchText calls.
    InvokeHttpFetchYield();
    return true;
  }

  // Slow path: cache miss → synchronous fetch with one retry on failure.
  g_prefetchMisses.fetch_add(1, std::memory_order_relaxed);
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
static bool PerformHttpFetchOnceSync(const std::string& url, std::string& out, std::string& contentType, int& status) {
  @autoreleasepool {
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
    if (!u) { status = 0; return false; }

    NSError* err = nil;
    NSInteger httpStatusLocal = 0;
    std::string contentTypeLocal;
    std::string bodyLocal;

    const auto fetchStartUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

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
    [request setValue:@"no-cache, no-store, max-age=0"
   forHTTPHeaderField:@"Cache-Control"];
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

    status = (int)httpStatusLocal;
    contentType = contentTypeLocal;
    if (err != nil || bodyLocal.empty()) {
      if (IsScriptLoadingLogEnabled()) {
        NSString* desc = err.localizedDescription ?: @"<no description>";
        NSString* domain = err.domain ?: @"<no domain>";
        Log(@"[http-loader][fetch-error] url=%s domain=%@ code=%ld desc=%@ status=%ld bodyEmpty=%d ms=%llu",
            url.c_str(),
            domain,
            (long)err.code,
            desc,
            (long)httpStatusLocal,
            bodyLocal.empty() ? 1 : 0,
            (unsigned long long)fetchMs);
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
// the previous kickstart wave left behind. See the doc comment in
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

// Periodic summary of prewarm-cache counters. Logs once every
// kPrefetchSummaryEvery hits+misses. Gated on the logScriptLoading
// flag so it stays silent by default — flip the flag when diagnosing
// kickstart behavior.
static constexpr size_t kPrefetchSummaryEvery = 100;
static void MaybeLogPrefetchSummary(const char* trigger) {
  size_t hits = g_prefetchHits.load(std::memory_order_relaxed);
  size_t misses = g_prefetchMisses.load(std::memory_order_relaxed);
  size_t total = hits + misses;
  if (total == 0) return;
  if (total % kPrefetchSummaryEvery != 0) return;
  if (!IsScriptLoadingLogEnabled()) return;

  size_t cacheSize = 0;
  {
    std::lock_guard<std::mutex> lock(g_prefetchMutex);
    cacheSize = g_prefetchCache.size();
  }

  size_t hitPct = total ? (hits * 100 / total) : 0;
  Log(@"[http-loader][prefetch][summary] trigger=%s totalAsks=%lu hits=%lu (%lu%%) misses=%lu cache=%lu",
      trigger,
      (unsigned long)total,
      (unsigned long)hits, (unsigned long)hitPct,
      (unsigned long)misses,
      (unsigned long)cacheSize);
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
//     kickstart threads, so they never pump someone else's runloop.
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

void ClearHttpModulePrefetchCache() {
  std::lock_guard<std::mutex> lock(g_prefetchMutex);
  g_prefetchCache.clear();
}

// List-mode kickstart prewarm.
//
// The dev server owns the module graph: it computes the inverse-dep
// closure for HMR updates (`evictPaths`) and can crawl the entry graph
// for cold boot. The client hands that explicit URL list to
// `__NS_DEV__.kickstartPrefetch(urls)`, which fetches every entry in one
// parallel wave into `g_prefetchCache` before V8 starts its serial
// synchronous walk.
//
// `dispatch_group_wait` provides clean "wave fully drained" semantics
// before V8 starts walking; the per-call queue isolates this group
// from other HMR cycles. We deliberately reuse `g_prefetchCache`
// (rather than a kickstart-only map) so the read path in
// `HttpFetchText` stays single-source.
namespace {

struct KickstartContext {
  std::mutex mutex;
  std::unordered_set<std::string> visited;
  std::atomic<size_t> fetchedCount{0};
  std::atomic<size_t> bytes{0};
  dispatch_group_t group = nullptr;
  dispatch_queue_t queue = nullptr;
  dispatch_semaphore_t concurrency = nullptr;

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

    // No "already cached" short-circuit here — the caller has explicitly
    // told us "fetch these URLs fresh". Any body sitting in
    // `g_prefetchCache` for one of them is a leftover from a previous
    // wave that V8 didn't consume; honoring it would feed V8 a stale
    // body on the next walk — the "1 cycle behind" symptom for `.ts`
    // edits with many transitive importers. (`InvalidateModules`
    // pre-clears the cache for the eviction set, so this is
    // defense-in-depth — but the kickstart may also be invoked
    // manually for diagnostics, and we want it to be correct in
    // isolation.)

    dispatch_group_enter(ctx->group);
    std::string urlCopy = urlRef;
    dispatch_async(ctx->queue, ^{
      dispatch_semaphore_wait(ctx->concurrency, DISPATCH_TIME_FOREVER);

      std::string body;
      std::string contentType;
      int status = 0;
      bool ok = PerformHttpFetchOnceSync(urlCopy, body, contentType, status);

      if (ok && status >= 200 && status < 300 && !body.empty()) {
        const size_t bodySize = body.size();
        // Overwrite unconditionally — the fresh body we just fetched is
        // by definition the authoritative copy; any older cache entry is
        // stale by construction (the caller has just told us so).
        {
          std::lock_guard<std::mutex> lock(g_prefetchMutex);
          g_prefetchCache[urlCopy] = std::move(body);
        }
        ctx->fetchedCount.fetch_add(1, std::memory_order_relaxed);
        ctx->bytes.fetch_add(bodySize, std::memory_order_relaxed);
      }

      dispatch_semaphore_signal(ctx->concurrency);
      dispatch_group_leave(ctx->group);
    });
  }
}

bool KickstartHmrPrefetchUrlsSync(const std::vector<std::string>& urls,
                                  int maxConcurrent,
                                  double timeoutSeconds,
                                  size_t* outFetchedCount,
                                  uint64_t* outElapsedMs) {
  if (urls.empty()) return false;
  // Drop empty / non-allowlisted URLs up front. We still want a
  // truthy result even if some entries get filtered, because partial
  // success is strictly better than the no-kickstart baseline.
  std::vector<std::string> filtered;
  filtered.reserve(urls.size());
  for (const auto& u : urls) {
    if (u.empty()) continue;
    if (!IsRemoteUrlAllowed(u)) continue;
    filtered.push_back(u);
  }
  if (filtered.empty()) return false;

  if (maxConcurrent <= 0) maxConcurrent = 16;
  if (timeoutSeconds <= 0.0) timeoutSeconds = 10.0;

  const uint64_t startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);

  // Diagnostic seed — we record the first URL purely so the log line
  // has a recognizable anchor when the user is correlating with their
  // server-side `[hmr-ws][update] file=...` line.
  const std::string diagSeed = filtered.front();
  const size_t requestedCount = filtered.size();

  auto ctx = std::make_shared<KickstartContext>();
  ctx->group = dispatch_group_create();
  ctx->queue = dispatch_queue_create("com.nativescript.hmr.kickstart", DISPATCH_QUEUE_CONCURRENT);
  ctx->concurrency = dispatch_semaphore_create(maxConcurrent);

  KickstartScheduleUrls(ctx, std::move(filtered));

  // Cold-boot caller (JS thread, pre-bootstrap): poll `dispatch_group_wait`
  // in 50ms slices and pump the runloop between them so the placeholder
  // heartbeat keeps ticking. HMR-refresh caller (post-bootstrap or
  // off-thread): plain blocking wait — no bar to animate and the wait
  // is short.
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

  if (IsScriptLoadingLogEnabled()) {
    Log(@"[hmr-kickstart][list] first=%s urls=%lu fetched=%lu bytes=%lu ms=%llu status=%s concurrency=%d",
        diagSeed.c_str(),
        (unsigned long)requestedCount,
        (unsigned long)fetched,
        (unsigned long)bytes,
        (unsigned long long)elapsedMs,
        timedOut == 0 ? "drained" : "timeout",
        maxConcurrent);
  }

  return timedOut == 0;
}

void CleanupHMRGlobals() {
  // Drop any kickstart-prewarmed module sources. These are plain
  // std::string buffers (no v8::Global), but flushing them on teardown
  // prevents stale source from leaking into a re-launched runtime in
  // the same process.
  ClearHttpModulePrefetchCache();
  ClearAllCacheBustMarks();
  // Reset the boot-complete flag so a re-launched runtime in the same
  // process starts in "cold boot" mode again (runloop pump armed).
  g_devSessionBootComplete.store(false, std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────
// Dev-loader JS-callable globals
//
// The runtime's dev surface is deliberately small: it exposes
// *mechanism* only (resolution config, registry eviction, parallel
// prewarm, registry introspection, boot-complete signal). All HMR
// *policy* — boot orchestration, `import.meta.hot`, full reload, CSS
// apply, WebSocket protocol — lives in the JS dev client
// (`@nativescript/vite`).

namespace {

// Sets the function name on the v8 Function for nicer stack traces and
// attaches it as a method of the `__NS_DEV__` namespace object.
void InstallDevFunction(v8::Isolate* isolate, v8::Local<v8::Context> context,
                        v8::Local<v8::Object> target, const char* name,
                        v8::FunctionCallback callback) {
  v8::Local<v8::FunctionTemplate> fnTpl =
      v8::FunctionTemplate::New(isolate, callback);
  v8::Local<v8::Function> fn = fnTpl->GetFunction(context).ToLocalChecked();
  fn->SetName(tns::ToV8String(isolate, name));
  target->CreateDataProperty(context, tns::ToV8String(isolate, name), fn)
      .Check();
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
        Log(@"[__NS_DEV__.configureRuntime] import map set (%zu bytes)", jsonStr.size());
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
        Log(@"[__NS_DEV__.configureRuntime] %zu volatile patterns set", patterns.size());
      }
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

//
// `__NS_DEV__.kickstartPrefetch(urls, options?)` lets the HMR client tell
// the runtime "the next (re-)import will walk this module set — please
// pre-fill the loader cache with every listed body before V8 starts
// walking". The list is always server-computed (the dev server owns the
// module graph: eviction closures for HMR, entry-graph crawls for cold
// boot); the runtime performs no graph discovery of its own. A single
// string argument is accepted as a one-element list.
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
    Log(@"[__NS_DEV__.kickstartPrefetch] expected (urls: string[], options?) or (url: string, options?)");
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

  std::vector<std::string> urls;
  if (info[0]->IsArray()) {
    v8::Local<v8::Array> arr = info[0].As<v8::Array>();
    const uint32_t len = arr->Length();
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
  } else {
    v8::String::Utf8Value u8(isolate, info[0]);
    if (*u8) {
      std::string s(*u8);
      if (!s.empty()) urls.push_back(std::move(s));
    }
  }

  if (urls.empty()) {
    buildResult(false, 0, 0);
    return;
  }

  size_t fetched = 0;
  uint64_t elapsedMs = 0;
  bool ok = tns::KickstartHmrPrefetchUrlsSync(urls, maxConcurrent, timeoutSeconds, &fetched, &elapsedMs);
  buildResult(ok, fetched, elapsedMs);
}

// `__NS_DEV__.seedModuleBodies(entries)` — batch prewarm-cache seeding.
//
// The JS bootstrap downloads `/__ns_dev__/boot-archive` (NDJSON of
// {url, body} lines) and hands the parsed entries here. Each entry lands in
// the one-shot prewarm cache (`g_prefetchCache`, consumed by `HttpFetchText`
// during V8's synchronous module walk), behind the same gates as a kickstart
// fetch. Mechanism only: the dev server computed the closure and produced
// the bodies; the runtime just stores them.
//
// Accepts Array<{ url, body }>. Returns { ok, seeded, bytes }; callers fall
// back to `kickstartPrefetch(urls)` when nothing was seeded.
void SeedModuleBodiesCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  v8::HandleScope scope(isolate);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();

  auto buildResult = [&](bool ok, size_t seeded, size_t bytes) {
    v8::Local<v8::Object> result = v8::Object::New(isolate);
    result->Set(ctx, tns::ToV8String(isolate, "ok"), v8::Boolean::New(isolate, ok)).Check();
    result->Set(ctx, tns::ToV8String(isolate, "seeded"), v8::Integer::NewFromUnsigned(isolate, (uint32_t)seeded)).Check();
    result->Set(ctx, tns::ToV8String(isolate, "bytes"), v8::Number::New(isolate, (double)bytes)).Check();
    info.GetReturnValue().Set(result);
  };

  if (info.Length() < 1 || !info[0]->IsArray()) {
    if (tns::IsScriptLoadingLogEnabled()) {
      Log(@"[__NS_DEV__.seedModuleBodies] expected Array<{url, body}>");
    }
    buildResult(false, 0, 0);
    return;
  }

  v8::Local<v8::Array> arr = info[0].As<v8::Array>();
  const uint32_t len = arr->Length();
  v8::Local<v8::String> urlKey = tns::ToV8String(isolate, "url");
  v8::Local<v8::String> bodyKey = tns::ToV8String(isolate, "body");

  size_t seeded = 0;
  size_t bytes = 0;
  for (uint32_t i = 0; i < len; i++) {
    v8::Local<v8::Value> elemVal;
    if (!arr->Get(ctx, i).ToLocal(&elemVal) || !elemVal->IsObject()) continue;
    v8::Local<v8::Object> elem = elemVal.As<v8::Object>();

    v8::Local<v8::Value> urlVal;
    if (!elem->Get(ctx, urlKey).ToLocal(&urlVal) || !urlVal->IsString()) continue;
    v8::String::Utf8Value urlU8(isolate, urlVal);
    if (!*urlU8) continue;
    std::string url(*urlU8);
    if (url.empty()) continue;

    // Same gates a kickstart fetch passes before it may populate the
    // prewarm cache (scheme, JS-source shape, remote-URL allowlist).
    if (!StartsWith(url, "http://") && !StartsWith(url, "https://")) continue;
    if (!LooksLikeJsSourceUrl(url)) continue;
    if (!IsRemoteUrlAllowed(url)) continue;

    v8::Local<v8::Value> bodyVal;
    if (!elem->Get(ctx, bodyKey).ToLocal(&bodyVal) || !bodyVal->IsString()) continue;
    v8::String::Utf8Value bodyU8(isolate, bodyVal);
    if (!*bodyU8) continue;
    std::string body(*bodyU8);
    if (body.empty()) continue;

    const size_t bodySize = body.size();
    // Overwrite unconditionally — the archive body is the authoritative
    // fresh copy, mirroring the kickstart's overwrite semantics.
    {
      std::lock_guard<std::mutex> lock(g_prefetchMutex);
      g_prefetchCache[url] = std::move(body);
    }
    seeded++;
    bytes += bodySize;
  }

  if (tns::IsScriptLoadingLogEnabled()) {
    Log(@"[__NS_DEV__.seedModuleBodies] seeded=%lu bytes=%lu of %u entries",
        (unsigned long)seeded, (unsigned long)bytes, len);
  }

  buildResult(seeded > 0, seeded, bytes);
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

// `__NS_DEV__.setDevBootComplete(value?: boolean)` — the JS dev client calls
// this (with `true`, or no argument) once the real app root view has
// committed. It flips both the JS-visible `__NS_HMR_BOOT_COMPLETE__`
// global and the native atomic that disarms the cold-boot runloop pump
// and the kickstart pump-wait. The client may also pass `false` before
// a full JS-realm reload to re-arm the boot-time behaviors.
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

void InitializeHmrDevGlobals(v8::Isolate* isolate, v8::Local<v8::Context> context,
                             bool isWorker) {
  // The dev host API lives here: `__NS_DEV__`.
  v8::Local<v8::Object> dev = v8::Object::New(isolate);

  InstallDevFunction(isolate, context, dev, "configureRuntime", ConfigureDevRuntimeCallback);
  InstallDevFunction(isolate, context, dev, "invalidateModules", InvalidateModulesCallback);
  InstallDevFunction(isolate, context, dev, "kickstartPrefetch", KickstartHmrPrefetchCallback);
  InstallDevFunction(isolate, context, dev, "seedModuleBodies", SeedModuleBodiesCallback);
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
        std::string key =
            CanonicalizeHttpUrlKey(*u ? std::string(*u) : std::string());
        info.GetReturnValue().Set(tns::ToV8String(iso, key.c_str()));
      };
      v8::Local<v8::Function> fn =
          v8::Function::New(context, canonicalizeCb).ToLocalChecked();
      fn->SetName(tns::ToV8String(isolate, "canonicalizeHttpUrlKey"));
      dev->CreateDataProperty(
             context, tns::ToV8String(isolate, "canonicalizeHttpUrlKey"), fn)
          .Check();
    } catch (...) {
      // Don't crash if debug-diagnostic setup fails
    }
  }

  context->Global()
      ->Set(context, tns::ToV8String(isolate, "__NS_DEV__"), dev)
      .FromMaybe(false);
  MirrorGlobalOnGlobalThis(isolate, context, "__NS_DEV__");
}

} // namespace tns
