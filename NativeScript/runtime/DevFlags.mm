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
static bool RemoteUrlMatchesAllowlistEntry(const std::string& url,
                                           const std::string& entry) {
  if (entry.empty()) return false;
  if (url.size() < entry.size()) return false;
  if (url.compare(0, entry.size(), entry) != 0) return false;
  if (url.size() == entry.size()) return true;  // exact match
  if (entry.back() == '/') return true;         // entry ended at a boundary
  const char next = url[entry.size()];
  return next == '/' || next == '?' || next == '#';
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
  
  // Check if URL matches any allowlist entry on a URL-component boundary.
  for (const std::string& entry : s_remoteModuleAllowlist) {
    if (RemoteUrlMatchesAllowlistEntry(url, entry)) {
      return true;
    }
  }
  
  return false;
}

} // namespace tns
