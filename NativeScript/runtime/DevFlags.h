#pragma once

// Centralized development/runtime flags helpers usable across runtime sources.
// These read from app package.json via Runtime::GetAppConfigValue and other
// runtime configuration to determine behavior of dev features.

namespace tns {

// Returns true when verbose script/module loading logs should be emitted.
// Controlled by package.json setting: "logScriptLoading": true|false
bool IsScriptLoadingLogEnabled();

} // namespace tns
