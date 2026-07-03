#pragma once

#include <string>

// Centralized development/runtime flags helpers usable across runtime sources.
// These read from app package.json via Runtime::GetAppConfigValue and other
// runtime configuration to determine behavior of dev features.

namespace tns {

// Returns true when verbose script/module loading logs should be emitted.
// Controlled by package.json setting: "logScriptLoading": true|false
bool IsScriptLoadingLogEnabled();

// HTTP module loader flags
//
// Returns true when one log line should be emitted per HTTP fetch URL.
// Default OFF because the volume is high (one line per fetch, hundreds per
// cold boot, hundreds per HMR refresh). Opt in via package.json /
// nativescript.config: "httpFetchUrlLog": true|false
bool IsHttpFetchUrlLogEnabled();

// Security config

// In debug mode (RuntimeConfig.IsDebug): always returns true.
// checks "security.allowRemoteModules" from nativescript.config.
bool IsRemoteModulesAllowed();

// "security.remoteModuleAllowlist" array from nativescript.config.
// If no allowlist is configured but allowRemoteModules is true, all URLs are allowed.
bool IsRemoteUrlAllowed(const std::string& url);

// Init security configuration
void InitializeSecurityConfig();

} // namespace tns
