#import <Foundation/Foundation.h>

#include "DevFlags.h"
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include <vector>
#include <mutex>

namespace tns {

bool IsScriptLoadingLogEnabled() {
  id value = Runtime::GetAppConfigValue("logScriptLoading");
  return value ? [value boolValue] : false;
}

// HTTP module loader flags

// Reads `httpModulePrefetch` from app config (default: DISABLED).
//
// Apps that want to opt in for testing can set:
//
//   // nativescript.config.ts
//   export default {
//     httpModulePrefetch: true,
//   } as NativeScriptConfig;
//
// Returning false here short-circuits both the cache lookup and the prefetch
// wave in HttpFetchText, restoring the pre-prefetcher behavior bit-for-bit.
bool IsHttpModulePrefetchEnabled() {
  static std::once_flag s_initFlag;
  static bool s_enabled = false;
  std::call_once(s_initFlag, []() {
    @autoreleasepool {
      id value = Runtime::GetAppConfigValue("httpModulePrefetch");
      if (value && [value respondsToSelector:@selector(boolValue)]) {
        s_enabled = [value boolValue];
      }
    }
    // Startup banner. Gated on the logScriptLoading flag so it stays silent
    // by default — flip the flag in nativescript.config.ts when diagnosing
    // why prefetch is or isn't engaging.
    //
    //   [http-loader] prefetch=disabled   ← expected default
    //   [http-loader] prefetch=enabled    ← only if config opt-in
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader] prefetch=%s shared-session=on hmr-kickstart=on",
          s_enabled ? "enabled" : "disabled");
    }
  });
  return s_enabled;
}

// Default OFF because the volume is high (one line per fetch, hundreds per
// cold boot, hundreds per HMR refresh). Opt in via `nativescript.config.ts`:
//
//     export default {
//       httpFetchUrlLog: true,   // turn on for diagnosis only
//       …
//     };
bool IsHttpFetchUrlLogEnabled() {
  static std::once_flag s_initFlag;
  static bool s_enabled = false;
  std::call_once(s_initFlag, []() {
    @autoreleasepool {
      id value = Runtime::GetAppConfigValue("httpFetchUrlLog");
      if (value && [value respondsToSelector:@selector(boolValue)]) {
        s_enabled = [value boolValue];
      }
    }
    if (IsScriptLoadingLogEnabled()) {
      Log(@"[http-loader] fetch-url-log=%s",
          s_enabled ? "enabled" : "disabled");
    }
  });
  return s_enabled;
}

// Security config

static std::once_flag s_securityConfigInitFlag;
static bool s_allowRemoteModules = false;
static std::vector<std::string> s_remoteModuleAllowlist;

// Helper to check if a URL starts with a given prefix
static bool UrlStartsWith(const std::string& url, const std::string& prefix) {
  if (prefix.size() > url.size()) return false;
  return url.compare(0, prefix.size(), prefix) == 0;
}

void InitializeSecurityConfig() {
  std::call_once(s_securityConfigInitFlag, []() {
    @autoreleasepool {
      // Get the security configuration object
      id securityValue = Runtime::GetAppConfigValue("security");
      if (!securityValue || ![securityValue isKindOfClass:[NSDictionary class]]) {
        // No security config: defaults remain (remote modules disabled in production)
        return;
      }
      
      NSDictionary* security = (NSDictionary*)securityValue;
      
      // Check allowRemoteModules
      id allowRemote = security[@"allowRemoteModules"];
      if (allowRemote && [allowRemote respondsToSelector:@selector(boolValue)]) {
        s_allowRemoteModules = [allowRemote boolValue];
      }
      
      // Parse remoteModuleAllowlist
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
  
  // Check if URL matches any allowlist prefix
  for (const std::string& prefix : s_remoteModuleAllowlist) {
    if (UrlStartsWith(url, prefix)) {
      return true;
    }
  }
  
  return false;
}

} // namespace tns
