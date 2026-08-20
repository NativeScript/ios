#include "HttpLoader.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <cstring>

#include <atomic>
#include <mutex>
#include <string>
#include <vector>
#include "Caches.h"
#include "Helpers.h"
#include "ModuleInternal.h"
#include "ModuleInternalCallbacks.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "robin_hood.h"

namespace tns {

static inline bool StartsWith(const std::string& s, const char* prefix) {
  size_t n = strlen(prefix);
  return s.size() >= n && s.compare(0, n, prefix) == 0;
}

// ─────────────────────────────────────────────────────────────
// Remote-module security gate
//
// Boot-time only: values come from nativescript.config / package.json
// (`security.allowRemoteModules`, `security.remoteModuleAllowlist`) and
// are never registered on ns:runtime getConfig/setConfig.

static std::once_flag s_securityConfigInitFlag;
static bool s_allowRemoteModules = false;
static std::vector<std::string> s_remoteModuleAllowlist;

// Returns true when `url` is authorized by allowlist `entry`.
//
// This is intentionally stricter than a raw string-prefix test: after the
// matched entry text, the next character in `url` must be a URL-component
// boundary ('/', '?', or '#'), the URL must end exactly at the entry, or the
// entry must itself end in '/'. That refuses lookalike-host and lookalike-port
// bypasses — an entry of "https://cdn.example.com" must NOT authorize
// "https://cdn.example.com.attacker.com/x.js" or
// "https://cdn.example.com:9999/x.js". To allow a specific port, include it in
// the allowlist entry (deny-by-default for anything not explicitly listed).
static bool RemoteUrlMatchesAllowlistEntry(const std::string& url, const std::string& entry) {
  if (entry.empty()) return false;
  if (url.size() < entry.size()) return false;
  if (url.compare(0, entry.size(), entry) != 0) return false;
  if (url.size() == entry.size()) return true;  // exact match
  if (entry.back() == '/') return true;         // entry ended at a boundary
  const char next = url[entry.size()];
  return next == '/' || next == '?' || next == '#';
}

static void InitializeSecurityConfig() {
  std::call_once(s_securityConfigInitFlag, []() {
    @autoreleasepool {
      id securityValue = Runtime::GetAppConfigValue("security");
      if (!securityValue || ![securityValue isKindOfClass:[NSDictionary class]]) {
        return;
      }

      NSDictionary* security = (NSDictionary*)securityValue;

      id allowRemote = security[@"allowRemoteModules"];
      if (allowRemote && [allowRemote respondsToSelector:@selector(boolValue)]) {
        s_allowRemoteModules = [allowRemote boolValue];
      }

      id allowlist = security[@"remoteModuleAllowlist"];
      if (allowlist && [allowlist isKindOfClass:[NSArray class]]) {
        NSArray* list = (NSArray*)allowlist;
        for (id item in list) {
          if ([item isKindOfClass:[NSString class]]) {
            NSString* str = (NSString*)item;
            if (str.length > 0) {
              s_remoteModuleAllowlist.push_back(std::string([str UTF8String]));
            }
          }
        }
      }
    }
  });
}

bool IsRemoteModulesAllowed() {
  if (RuntimeConfig.IsDebug) {
    return true;
  }

  InitializeSecurityConfig();
  return s_allowRemoteModules;
}

bool IsRemoteUrlAllowed(const std::string& url) {
  if (RuntimeConfig.IsDebug) {
    return true;
  }

  InitializeSecurityConfig();
  if (!s_allowRemoteModules) {
    return false;
  }

  // If no allowlist is configured, allow all URLs (user explicitly enabled remote modules)
  if (s_remoteModuleAllowlist.empty()) {
    return true;
  }

  for (const std::string& entry : s_remoteModuleAllowlist) {
    if (RemoteUrlMatchesAllowlistEntry(url, entry)) {
      return true;
    }
  }

  return false;
}

// ─────────────────────────────────────────────────────────────
// Boot-evaluation flag
//
// ─────────────────────────────────────────────────────────────
// HTTP loader helpers

// URLs touched before the client configures anything (the local trampoline's
// clean `/ns/core/*` imports) carry no query, so they canonicalize identically
// under any vocabulary.
std::string RepairCollapsedUrlScheme(const std::string& url) {
  if (StartsWith(url, "http:/") && !StartsWith(url, "http://")) {
    std::string repaired = url;
    repaired.insert(5, "/");
    return repaired;
  }
  if (StartsWith(url, "https:/") && !StartsWith(url, "https://")) {
    std::string repaired = url;
    repaired.insert(6, "/");
    return repaired;
  }
  return url;
}

std::string CanonicalizeHttpUrlKey(const std::string& url) {
  // Per-isolate vocabulary, so this runs on the isolate's own thread. Fetch
  // threads never reach here — they carry keys computed for them.
  const CanonicalizationConfig* canonConfig = CanonicalizationConfigForCurrentIsolate();
  // Some loaders wrap HTTP module URLs as file://http(s)://...
  // Repaired before any scheme test, so a collapsed `http:/host` keys the same
  // as the URL it means rather than passing through untouched.
  std::string normalizedUrl = RepairCollapsedUrlScheme(url);
  // The wrapper is tested on the one-slash forms as well: a path join can
  // collapse the scheme INSIDE the wrapper (`file://http:/host/x`), which
  // matches neither the two-slash unwrap nor the repair above (whose prefix is
  // `file://`, not `http:/`) and would otherwise key as its own identity.
  if (StartsWith(normalizedUrl, "file://http:/") || StartsWith(normalizedUrl, "file://https:/")) {
    normalizedUrl = RepairCollapsedUrlScheme(normalizedUrl.substr(strlen("file://")));
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
  // ns:module `invalidateModules` (registry evict) plus the
  // eviction-driven fetch nonce in `PerformHttpFetchOnceSync`, never by URL
  // variation. There is deliberately no path-tag vocabulary to collapse here.
  //
  // Why `preserveQueryFor` exists (and is checked BEFORE the dev-endpoint
  // prefix test, so it covers endpoints nested under a dev prefix): for some
  // endpoints the query IS the identity. A framework that fetches recompiled
  // component metadata under a timestamped query is the motivating case —
  // stripping that timestamp would collapse every HMR fetch onto the boot-time
  // cache key, and the client would forever replay stale metadata.
  //
  // Until a client supplies that vocabulary, canonicalization is purely
  // mechanical: the fragment is gone and the query stays, because which params
  // are cache-busters and which paths are dev endpoints is knowledge only the
  // client has. Guessing would silently collapse two distinct modules onto one
  // registry key.
  if (canonConfig == nullptr) {
    return noHash;
  }

  {
    std::string pathOnly = originAndPath.substr(pathStart);
    for (const auto& p : canonConfig->preserveQueryPrefixes) {
      if (!p.empty() && pathOnly.find(p) != std::string::npos) {
        return noHash;  // query preserved verbatim (fragment already removed)
      }
    }
    bool isDevEndpoint = false;
    for (const auto& p : canonConfig->devPathPrefixes) {
      if (!p.empty() && StartsWith(pathOnly, p.c_str())) {
        isDevEndpoint = true;
        break;
      }
    }
    if (!isDevEndpoint) {
      return noHash;
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
      bool drop = std::find(canonConfig->stripParams.begin(), canonConfig->stripParams.end(),
                            name) != canonConfig->stripParams.end();
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
//
// Marks carry a generation rather than being plain set membership. A fetch
// records the generation it observed and clears only that one, so an
// invalidation raised while a fetch was already in flight survives that
// fetch's completion instead of being erased by it — which would have left the
// next fetch with no nonce and CFNetwork free to serve the body the
// invalidation was raised to discard.
//
// Generation 0 is reserved for "not marked", so a captured 0 clears nothing.
static std::mutex g_bustNextFetchMutex;
static robin_hood::unordered_map<std::string, uint64_t> g_bustNextFetchKeys;
static uint64_t g_bustNextFetchGeneration = 0;

void MarkKeysForCacheBust(const std::vector<std::string>& canonicalKeys) {
  if (canonicalKeys.empty()) return;
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  const uint64_t generation = ++g_bustNextFetchGeneration;
  for (const auto& key : canonicalKeys) {
    if (key.empty()) continue;
    if (!(StartsWith(key, "http://") || StartsWith(key, "https://"))) continue;
    // Assigned, not inserted: re-marking an already-marked key has to move it
    // to the new generation, or the in-flight fetch would clear it.
    g_bustNextFetchKeys[key] = generation;
  }
}

// Peek (do not consume) — the fetch may be retried on transient failure and the
// retry must still carry a nonce. Returns the generation to carry, or 0 when
// the key is not marked. Cleared on fetch success, by generation.
static uint64_t CacheBustGenerationForKey(const std::string& canonicalKey) {
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  if (g_bustNextFetchKeys.empty()) return 0;
  auto it = g_bustNextFetchKeys.find(canonicalKey);
  return it == g_bustNextFetchKeys.end() ? 0 : it->second;
}

// Clears the mark this fetch actually satisfied. A newer mark has a newer
// generation and is left standing for the fetch that will carry it.
static void ClearCacheBustForKey(const std::string& canonicalKey, uint64_t observedGeneration) {
  if (observedGeneration == 0) return;
  std::lock_guard<std::mutex> lock(g_bustNextFetchMutex);
  auto it = g_bustNextFetchKeys.find(canonicalKey);
  if (it != g_bustNextFetchKeys.end() && it->second == observedGeneration) {
    g_bustNextFetchKeys.erase(it);
  }
}

// ============================================================================
// HTTP module fetching
// ============================================================================
//
// Two fetch primitives back the HTTP ESM loader:
//   - `HttpFetchModule` — the synchronous fetch V8's ResolveModuleCallback
//     falls back to for anything the module-graph walk missed
//     (the callback is synchronous — still true as of 14.9.207.39 — so
//     this fallback must be native and blocking).
//   - `FetchModuleBodyAsync` — the NSURLSession-backed primitive behind
//     the module-graph walk (StartModuleGraphLoad), which fetches the
//     transitive closure concurrently off the JS thread before
//     instantiation begins.
//
// The two transports stay separate — the NSURLConnection deadlock note above
// PerformHttpFetchOnceSync is why — but they share both halves of the
// contract: BuildModuleFetchRequest shapes every request, and
// ClassifyModuleResponse judges every response. Neither can drift into its
// own idea of what a valid module response is.
//
// Concurrent per-module fetches overlap with on-device compile, which
// measured fastest on real apps (HMR_API_NECESSITY_REVIEW.md §8.3).

// Forward declarations — these helpers are defined below their first use,
// matching the existing convention in this file.
static bool PerformHttpFetchOnceSync(const std::string& url, const std::string& canonicalKey,
                                     std::string& out, std::string& contentType, int& status,
                                     uint64_t* outBustGeneration = nullptr);

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

// ── The module response policy ───────────────────────────────────────────────
//
// Module scripts are strict about MIME: the HTML spec's "fetch a single module
// script" fails the fetch outright for anything that is not a JavaScript or
// JSON MIME type, where a classic script would sniff and run it anyway. That
// strictness is the whole point — an SPA dev server answering an unknown path
// with `200 text/html` should say so, not hand HTML to the parser and produce
// `Unexpected token '<'` from somewhere deep in the graph.
//
// Both transports classify here, so the synchronous fallback and the async
// walk cannot disagree about what a response means.

// "text/javascript; charset=utf-8" → "text/javascript": parameters stripped,
// trimmed, lowercased.
static std::string MimeEssence(const std::string& contentType) {
  size_t semi = contentType.find(';');
  std::string essence = semi == std::string::npos ? contentType : contentType.substr(0, semi);
  size_t begin = essence.find_first_not_of(" \t");
  if (begin == std::string::npos) {
    return "";
  }
  size_t end = essence.find_last_not_of(" \t");
  essence = essence.substr(begin, end - begin + 1);
  for (char& c : essence) {
    c = (char)tolower((unsigned char)c);
  }
  return essence;
}

// The HTML spec's JavaScript MIME type essence list, verbatim.
static bool IsJavaScriptMimeEssence(const std::string& essence) {
  static const char* const kJavaScriptEssences[] = {"application/ecmascript",
                                                    "application/javascript",
                                                    "application/x-ecmascript",
                                                    "application/x-javascript",
                                                    "text/ecmascript",
                                                    "text/javascript",
                                                    "text/javascript1.0",
                                                    "text/javascript1.1",
                                                    "text/javascript1.2",
                                                    "text/javascript1.3",
                                                    "text/javascript1.4",
                                                    "text/javascript1.5",
                                                    "text/jscript",
                                                    "text/livescript",
                                                    "text/x-ecmascript",
                                                    "text/x-javascript"};
  for (const char* candidate : kJavaScriptEssences) {
    if (essence == candidate) {
      return true;
    }
  }
  return false;
}

// A JSON MIME type is application/json, text/json, or any `+json` subtype.
static bool IsJsonMimeEssence(const std::string& essence) {
  if (essence == "application/json" || essence == "text/json") {
    return true;
  }
  const std::string suffix = "+json";
  return essence.size() > suffix.size() &&
         essence.compare(essence.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// `transportOk` means a response arrived at all; everything else about it —
// status, MIME, emptiness — is policy decided here. `body` is moved into the
// result on success.
static void ClassifyModuleResponse(const std::string& url, bool transportOk, int status,
                                   const std::string& contentType, std::string& body,
                                   ModuleFetchResult& result) {
  result.status = status;
  result.contentType = contentType;

  if (!transportOk) {
    result.failureReason = "HTTP import failed: " + url + " (network error)";
    return;
  }
  if (status == 204 || status == 205) {
    // "No content" carries no module, which the web treats as a network error
    // for a module script rather than as an empty module.
    result.failureReason =
        "HTTP import failed: " + url + " (status=" + std::to_string(status) + ", no content)";
    return;
  }
  if (status < 200 || status >= 300) {
    result.failureReason =
        "HTTP import failed: " + url + " (status=" + std::to_string(status) + ")";
    return;
  }

  const std::string essence = MimeEssence(contentType);
  if (essence.empty()) {
    result.failureReason =
        "Expected a JavaScript module but '" + url + "' responded with no MIME type";
    return;
  }

  if (IsJsonMimeEssence(essence)) {
    if (body.empty()) {
      result.failureReason =
          "Expected a JSON module but '" + url + "' responded with an empty body";
      return;
    }
    result.kind = ModuleResponseKind::kJson;
  } else if (IsJavaScriptMimeEssence(essence)) {
    result.kind = ModuleResponseKind::kJavaScript;
    // An empty 2xx JavaScript body is a valid module: type-only TypeScript
    // modules transform to zero runtime code and dev servers serve them as
    // empty 200s. Failing here would kill the whole graph with a misleading
    // "status=200".
    if (body.empty()) {
      body = "export {};\n";
      TNS_DEBUG(Esm, "[http-loader] empty 2xx body for %s — serving canonical empty module",
                url.c_str());
    }
  } else {
    result.failureReason =
        "Expected a JavaScript module but '" + url + "' responded with MIME type '" + essence + "'";
    return;
  }

  result.ok = true;
  result.body = std::move(body);
}

bool HttpFetchModule(const std::string& url, const std::string& canonicalKey,
                     ModuleFetchResult& result) {
  result = ModuleFetchResult();

  // Security gate: the single point of enforcement for all HTTP module
  // loading, checked before any network turn.
  if (!IsRemoteUrlAllowed(url)) {
    result.status = 403;
    result.failureReason = "HTTP import blocked: remote module loading is not allowed for " + url;
    TNS_DEBUG(Esm, "[http-esm][security][blocked] %s", url.c_str());
    return false;
  }

  // Hoist the category check once per call so the branches below share a
  // single read.
  const bool traceFetch = tns::LogCategoryEnabled(tns::LogCategory::Fetch);

  // Time the network branch end-to-end so the per-URL log can attribute
  // milliseconds to each fetch. Measured here rather than inside
  // PerformHttpFetchOnceSync so the retry interval is billed to the URL too —
  // which is what the user sees as "this URL was slow".
  const uint64_t netStartUs =
      traceFetch ? (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0) : 0ull;

  std::string body;
  std::string contentType;
  int status = 0;
  uint64_t bustGeneration = 0;
  bool transportOk =
      PerformHttpFetchOnceSync(url, canonicalKey, body, contentType, status, &bustGeneration);
  if (!transportOk) {
    // One retry, and only for a transport error: an HTTP status is an answer,
    // not a failure to communicate, so asking again would just repeat it.
    TNS_DEBUG(Esm, "[http-loader] retrying %s after initial fetch error", url.c_str());
    usleep(120 * 1000);
    // The retry re-peeks, so the generation it carries — the one whose nonce is
    // on the wire for the body we end up with — replaces the first attempt's.
    transportOk =
        PerformHttpFetchOnceSync(url, canonicalKey, body, contentType, status, &bustGeneration);
  }
  // NOTE: no long dev-server-startup retry loop here on purpose. The CLI's
  // `compileWithWatch` gates app deploy/restart on its `vite serve`
  // readiness probe (bundler-compiler-service), so a connection-refused at
  // boot is a real failure, not a startup race — surface it immediately.

  ClassifyModuleResponse(url, transportOk, status, contentType, body, result);

  // The mark is spent only once a response classifies as a usable module. A
  // 2xx alone is not enough: an SPA fallback answering 200 text/html would
  // otherwise consume the eviction nonce and leave the next fetch cacheable.
  // Same rule as the async path.
  if (result.ok) {
    ClearCacheBustForKey(canonicalKey, bustGeneration);
  }

  if (!result.ok) {
    TNS_DEBUG(Esm, "[http-loader][fetch-sync][reject] %s", result.failureReason.c_str());
    return false;
  }

  if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
    const char* ctstr = result.contentType.empty() ? "<none>" : result.contentType.c_str();
    TNS_DEBUG(Esm, "[http-loader] fetched status=%d content-type=%s bytes=%llu", result.status,
              ctstr, (unsigned long long)result.body.size());
  }
  if (traceFetch) {
    const uint64_t netEndUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    const uint64_t netMs = netEndUs > netStartUs ? (netEndUs - netStartUs) / 1000ull : 0ull;
    TNS_DEBUG(Fetch, "[http-loader][fetch][network] %s bytes=%lu ms=%llu", url.c_str(),
              (unsigned long)result.body.size(), (unsigned long long)netMs);
  }

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
// unparseable URLs) and reports via `outBustGeneration` which mark the URL was
// marked for an eviction-driven cache-bust nonce (the caller clears the
// mark once a fresh body actually arrives).
static NSMutableURLRequest* BuildModuleFetchRequest(const std::string& url,
                                                    const std::string& canonicalKey,
                                                    uint64_t* outBustGeneration) {
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
  // by `InvalidateModules` (via `MarkKeysForCacheBust`), append a
  // unique nonce query parameter so CFNetwork sees a different URL
  // and cannot satisfy the request from any cache layer. The dev
  // server ignores unknown query params on module routes, so the
  // response body is unchanged. First-touch fetches don't need
  // busting — nothing has cached them yet — so unmarked URLs go out
  // verbatim (some Vite virtual routes require exact-match URLs and
  // 404 on unknown query params).
  std::string fetchUrl = url;
  const uint64_t bustGeneration = CacheBustGenerationForKey(canonicalKey);
  if (outBustGeneration) *outBustGeneration = bustGeneration;
  if (bustGeneration != 0) {
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

static bool PerformHttpFetchOnceSync(const std::string& url, const std::string& canonicalKey,
                                     std::string& out, std::string& contentType, int& status,
                                     uint64_t* outBustGeneration) {
  @autoreleasepool {
    uint64_t bustGeneration = 0;
    NSMutableURLRequest* request = BuildModuleFetchRequest(url, canonicalKey, &bustGeneration);
    if (outBustGeneration) *outBustGeneration = bustGeneration;
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
    if (syncCount > 0 && syncCount % kFetchSyncSummaryEvery == 0 &&
        tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
      const size_t fast = g_fetchSyncFast.load(std::memory_order_relaxed);
      const size_t medium = g_fetchSyncMedium.load(std::memory_order_relaxed);
      const size_t slow = g_fetchSyncSlow.load(std::memory_order_relaxed);
      const uint64_t totalMs = g_fetchSyncTotalMs.load(std::memory_order_relaxed);
      const uint64_t avgMs = syncCount ? totalMs / (uint64_t)syncCount : 0;
      TNS_DEBUG(Esm,
                "[http-loader][fetch-sync][summary] count=%lu avg=%llums fast(<10ms)=%lu "
                "medium=%lu slow(>=100ms)=%lu",
                (unsigned long)syncCount, (unsigned long long)avgMs, (unsigned long)fast,
                (unsigned long)medium, (unsigned long)slow);
    }

    status = (int)httpStatusLocal;
    contentType = contentTypeLocal;
    // Pure transport: true means a response arrived. Whether that response is
    // a usable module — status, MIME, emptiness — is ClassifyModuleResponse's
    // call, so both fetch paths answer it the same way.
    if (err != nil) {
      if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
        NSString* desc = err.localizedDescription ?: @"<no description>";
        NSString* domain = err.domain ?: @"<no domain>";
        TNS_DEBUG(Esm,
                  "[http-loader][fetch-error] url=%s domain=%s code=%ld desc=%s status=%ld "
                  "bodyEmpty=%d ms=%llu",
                  url.c_str(), domain.UTF8String, (long)err.code, desc.UTF8String,
                  (long)httpStatusLocal, bodyLocal.empty() ? 1 : 0, (unsigned long long)fetchMs);
      }
      return false;
    }
    out.swap(bodyLocal);
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
    const std::string& url, const std::string& canonicalKey, int attempt,
    std::function<void(ModuleFetchResult result)>* completionHeap) {
  @autoreleasepool {
    uint64_t bustGeneration = 0;
    NSMutableURLRequest* request = BuildModuleFetchRequest(url, canonicalKey, &bustGeneration);
    if (!request) {
      ModuleFetchResult failed;
      failed.failureReason = "HTTP import failed: " + url + " (malformed request URL)";
      (*completionHeap)(std::move(failed));
      delete completionHeap;
      return;
    }

    const std::string urlCopy = url;
    const std::string keyCopy = canonicalKey;
    const uint64_t bust = bustGeneration;
    const uint64_t startUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
    NSURLSessionDataTask* task = [ModuleFetchSession()
        dataTaskWithRequest:request
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            // NSURLSession invokes this block, so a C++ exception leaving it is
            // an std::terminate rather than a failure anyone can report. Nothing
            // here runs JS — the compile is posted to the isolate's own thread —
            // so an escape could only come from an allocation failure, but the
            // containment is structural on purpose: the graph load must hear
            // back exactly once or it waits out its entire deadline.
            bool retrying = false;
            ModuleFetchResult result;
            try {
              int status = 0;
              std::string contentType;
              if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
                status = (int)[httpResp statusCode];
                NSString* ct = [httpResp allHeaderFields][@"Content-Type"];
                if (ct) {
                  const char* utf8 = [ct UTF8String];
                  if (utf8) contentType = std::string(utf8);
                }
              }
              std::string body;
              if (data && [data length] > 0) {
                body.assign(static_cast<const char*>([data bytes]),
                            static_cast<size_t>([data length]));
              }

              // Transport error → one retry, the same single-retry policy the
              // sync path applies, without blocking any thread.
              if (error != nil && attempt == 0) {
                TNS_DEBUG(Esm, "[http-loader][fetch-async] retrying %s after transport error: %s",
                          urlCopy.c_str(),
                          (error.localizedDescription ?: @"<no description>").UTF8String);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                 // Background thread: the carried key is the
                                 // only way this attempt can consult the bust set.
                                 PerformModuleFetchAsyncAttempt(urlCopy, keyCopy, 1,
                                                                completionHeap);
                               });
                // Set only once the retry is actually queued: it now owns the
                // completion, and this attempt must not settle it too.
                retrying = true;
              } else {
                ClassifyModuleResponse(urlCopy, error == nil, status, contentType, body, result);

                if (result.ok) {
                  ClearCacheBustForKey(keyCopy, bust);
                }
                if (!result.ok) {
                  TNS_DEBUG(Esm, "[http-loader][fetch-async][reject] attempt=%d %s", attempt,
                            result.failureReason.c_str());
                } else if (tns::LogCategoryEnabled(tns::LogCategory::Fetch)) {
                  const uint64_t endUs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0 * 1000.0);
                  const uint64_t ms = endUs > startUs ? (endUs - startUs) / 1000ull : 0ull;
                  TNS_DEBUG(Fetch, "[http-loader][fetch][async] %s bytes=%lu ms=%llu",
                            urlCopy.c_str(), (unsigned long)result.body.size(),
                            (unsigned long long)ms);
                }
              }
            } catch (...) {
              if (retrying) {
                // The retry owns the completion and will settle it; nothing to
                // report from here.
                return;
              }
              result = ModuleFetchResult();
              result.failureReason =
                  "HTTP import failed: " + urlCopy + " (internal error handling the response)";
            }

            if (retrying) {
              return;
            }
            // Guarded for the same reason: the completion posts to the
            // isolate's loop, and a throw on the way out would cross the
            // ObjC boundary instead of failing the load.
            try {
              (*completionHeap)(std::move(result));
            } catch (...) {
              Log(@"NativeScript: module fetch completion threw for %s", urlCopy.c_str());
            }
            delete completionHeap;
          }];
    [task resume];
  }
}

void FetchModuleBodyAsync(const std::string& url, const std::string& canonicalKey,
                          std::function<void(ModuleFetchResult result)> completion) {
  // Security gate: single point of enforcement, same as HttpFetchModule.
  if (!IsRemoteUrlAllowed(url)) {
    TNS_DEBUG(Esm, "[http-esm][security][blocked] %s", url.c_str());
    ModuleFetchResult blocked;
    blocked.status = 403;
    blocked.failureReason = "HTTP import blocked: remote module loading is not allowed for " + url;
    completion(std::move(blocked));
    return;
  }

  auto* completionHeap = new std::function<void(ModuleFetchResult)>(std::move(completion));
  PerformModuleFetchAsyncAttempt(url, canonicalKey, 0, completionHeap);
}

// Cold-boot JS-thread runloop pump.
//

}  // namespace tns
