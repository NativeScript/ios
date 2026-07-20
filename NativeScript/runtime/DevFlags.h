#pragma once

#include <string>

// Centralized development/runtime flags helpers usable across runtime sources.
// These read from app package.json via Runtime::GetAppConfigValue and other
// runtime configuration to determine behavior of dev features.

namespace tns {

// Returns true when verbose script/module loading logs should be emitted.
// Controlled by package.json setting: "logScriptLoading": true|false
bool IsScriptLoadingLogEnabled();

// Logs (behind IsScriptLoadingLogEnabled) that a native->JS callback was
// dropped because the isolate that created it has been disposed (e.g. after
// NativeScriptRuntime.reloadApplication / restartWithConfig). Without this,
// UIKit dispatch to instances of classes built by a previous isolate (such as
// a JS-extended UIApplicationDelegate or UISceneDelegate) silently no-ops.
// `target` is an ObjC `id` and `selector` a `SEL`; either may be null when
// the callback is a block or C function pointer rather than a method.
void LogDroppedDeadIsolateCallback(void* target, void* selector);

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
