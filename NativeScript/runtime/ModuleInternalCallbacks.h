// ModuleInternalCallbacks.h
#pragma once
#include <v8.h>

#include <string>
#include <unordered_map>

namespace tns {

// Export our registry so both LoadESModule and the callback see the same data:
extern std::unordered_map<std::string, v8::Global<v8::Module>> g_moduleRegistry;

// Resolve callback signature (with import‑assertions slot)
v8::MaybeLocal<v8::Module> ResolveModuleCallback(
    v8::Local<v8::Context> context, v8::Local<v8::String> specifier,
    v8::Local<v8::FixedArray> import_assertions,
    v8::Local<v8::Module> referrer);

}  // namespace tns
