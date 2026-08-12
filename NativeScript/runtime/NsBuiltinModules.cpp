#include "NsBuiltinModules.h"

#include <vector>

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Console.h"
#include "Helpers.h"
#include "HttpLoader.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

namespace {

constexpr const char* kNsPrefix = "ns:";
constexpr const char* kNodePrefix = "node:";

struct Registration {
  const char* specifier;
  BuiltinId builtin;
};

// The v1 registry (docs/ns-builtin-modules.md). One specifier, one source
// file: a `node:` shim is its own builtin that requires the `ns:` module it
// adapts, so the two module objects stay distinct and the standard module
// never carries compatibility code.
constexpr Registration kRegistry[] = {
    {"ns:module", BuiltinId::kNsModule},
    {"ns:runtime", BuiltinId::kNsRuntime},
    {"ns:util", BuiltinId::kNsUtil},
    {"node:util", BuiltinId::kNodeUtil},
};

// ns:runtime config keys. Each key defines its value domain and scope here;
// process-wide keys (see Helpers.h) affect every isolate, so writes are
// restricted to the main isolate. Remote-module security
// (`security.allowRemoteModules`, `security.remoteModuleAllowlist`) is
// deliberately not registered — it is boot-time nativescript.config only.
constexpr const char* kReleasedObjectPolicyKey = "releasedObjectPolicy";
constexpr const char* kLogScriptLoadingKey = "logScriptLoading";
constexpr const char* kHttpFetchUrlLogKey = "httpFetchUrlLog";

void ThrowTypeError(Isolate* isolate, const std::string& message) {
  isolate->ThrowException(
      Exception::TypeError(tns::ToV8String(isolate, message)));
}

bool EnsureMainIsolateWrite(Isolate* isolate, const std::string& key) {
  if (Runtime::IsWorker()) {
    ThrowTypeError(isolate, "'" + key +
                                "' is process-wide and can only be set from the main "
                                "isolate");
    return false;
  }
  return true;
}

bool ParseBooleanValue(Isolate* isolate, const FunctionCallbackInfo<Value>& info,
                       const std::string& key, bool* out) {
  if (!info[1]->IsBoolean()) {
    ThrowTypeError(isolate, "'" + key + "' must be a boolean");
    return false;
  }
  *out = info[1].As<v8::Boolean>()->Value();
  return true;
}

void SetConfigCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 2 || !info[0]->IsString()) {
    ThrowTypeError(isolate, "setConfig expects (key: string, value)");
    return;
  }
  std::string key = tns::ToString(isolate, info[0]);
  if (key == kReleasedObjectPolicyKey) {
    if (!EnsureMainIsolateWrite(isolate, key)) {
      return;
    }
    std::string value =
        info[1]->IsString() ? tns::ToString(isolate, info[1]) : std::string();
    if (value == "report") {
      tns::SetReleasedObjectPolicy(tns::ReleasedObjectPolicy::kReport);
    } else if (value == "throw") {
      tns::SetReleasedObjectPolicy(tns::ReleasedObjectPolicy::kThrow);
    } else {
      ThrowTypeError(isolate, "'" + key + "' must be 'report' or 'throw'");
    }
    return;
  }
  if (key == kLogScriptLoadingKey) {
    if (!EnsureMainIsolateWrite(isolate, key)) {
      return;
    }
    bool value = false;
    if (!ParseBooleanValue(isolate, info, key, &value)) {
      return;
    }
    tns::SetScriptLoadingLogEnabled(value);
    return;
  }
  if (key == kHttpFetchUrlLogKey) {
    if (!EnsureMainIsolateWrite(isolate, key)) {
      return;
    }
    bool value = false;
    if (!ParseBooleanValue(isolate, info, key, &value)) {
      return;
    }
    tns::SetHttpFetchUrlLogEnabled(value);
    return;
  }
  ThrowTypeError(isolate, "Unknown runtime config key: '" + key + "'");
}

void GetConfigCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1 || !info[0]->IsString()) {
    ThrowTypeError(isolate, "getConfig expects (key: string)");
    return;
  }
  std::string key = tns::ToString(isolate, info[0]);
  if (key == kReleasedObjectPolicyKey) {
    const char* value =
        tns::GetReleasedObjectPolicy() == tns::ReleasedObjectPolicy::kThrow
            ? "throw"
            : "report";
    info.GetReturnValue().Set(tns::ToV8String(isolate, value));
    return;
  }
  if (key == kLogScriptLoadingKey) {
    info.GetReturnValue().Set(
        v8::Boolean::New(isolate, tns::IsScriptLoadingLogEnabled()));
    return;
  }
  if (key == kHttpFetchUrlLogKey) {
    info.GetReturnValue().Set(
        v8::Boolean::New(isolate, tns::IsHttpFetchUrlLogEnabled()));
    return;
  }
  ThrowTypeError(isolate, "Unknown runtime config key: '" + key + "'");
}

const Registration* Find(const std::string& specifier) {
  for (const Registration& registration : kRegistry) {
    if (specifier == registration.specifier) {
      return &registration;
    }
  }
  return nullptr;
}

bool HasPrefix(const std::string& specifier, const char* prefix) {
  return specifier.rfind(prefix, 0) == 0;
}

MaybeLocal<Object> BuildBinding(Local<Context> context, BuiltinId builtin) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> binding = Object::New(isolate);

  switch (builtin) {
    case BuiltinId::kNsModule: {
      // The HTTP-loader control surface (HttpLoader.mm). The binding builder
      // decides build-dependent membership; ns-module.js only shapes
      // and freezes whatever arrives.
      if (!BuildNsModuleBinding(context, binding)) {
        return MaybeLocal<Object>();
      }
      break;
    }
    case BuiltinId::kNsRuntime: {
      Local<v8::Function> setConfig, getConfig;
      if (!v8::Function::New(context, SetConfigCallback).ToLocal(&setConfig) ||
          !v8::Function::New(context, GetConfigCallback).ToLocal(&getConfig) ||
          !binding
               ->Set(context, tns::ToV8String(isolate, "setConfig"), setConfig)
               .FromMaybe(false) ||
          !binding
               ->Set(context, tns::ToV8String(isolate, "getConfig"), getConfig)
               .FromMaybe(false)) {
        return MaybeLocal<Object>();
      }
      break;
    }
    case BuiltinId::kNsUtil: {
      // The console formatter is built once per realm; ns:util re-exports that
      // instance instead of creating a second one.
      Console::InitInspect(context);
      std::shared_ptr<Caches> cache = Caches::Get(isolate);
      if (cache->InspectFunc == nullptr) {
        return MaybeLocal<Object>();
      }
      if (!binding
               ->Set(context, tns::ToV8String(isolate, "inspect"),
                     cache->InspectFunc->Get(isolate))
               .FromMaybe(false)) {
        return MaybeLocal<Object>();
      }
      break;
    }
    default:
      break;
  }

  return binding;
}

// Runs a module's builtin and caches its exports. Always leaves an exception
// pending when it returns false.
bool Instantiate(Local<Context> context, const Registration& requested) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Caches> cache = Caches::Get(isolate);

  // A shim reaches its ns: module through the builtin require, so the graph is
  // walked while a module is still being built; a cycle would otherwise
  // recurse until the stack runs out.
  if (cache->BuiltinModulesInProgress.count(requested.specifier) > 0) {
    isolate->ThrowException(Exception::Error(
        tns::ToV8String(isolate, "Circular require of built-in module: " +
                                     std::string(requested.specifier))));
    return false;
  }
  cache->BuiltinModulesInProgress.emplace(requested.specifier);

  TryCatch tc(isolate);
  Local<Object> binding;
  Local<Value> result;
  bool built = BuildBinding(context, requested.builtin).ToLocal(&binding) &&
               BuiltinLoader::RunBuiltin(context, requested.builtin, binding)
                   .ToLocal(&result) &&
               result->IsObject();
  cache->BuiltinModulesInProgress.erase(requested.specifier);

  if (built) {
    cache->BuiltinModuleExports[requested.specifier] =
        std::make_unique<Persistent<Object>>(isolate, result.As<Object>());
    return true;
  }

  if (tc.HasCaught()) {
    tc.ReThrow();
    return false;
  }
  isolate->ThrowException(Exception::Error(
      tns::ToV8String(isolate, "Failed to initialize built-in module '" +
                                   std::string(requested.specifier) + "'")));
  return false;
}

// The exports a synthetic module re-exports by name, in the order used both
// when declaring the export names and when populating them.
MaybeLocal<v8::Array> ExportKeys(Local<Context> context,
                                 Local<Object> exports) {
  return exports->GetOwnPropertyNames(context, PropertyFilter::ONLY_ENUMERABLE,
                                      KeyConversionMode::kConvertToString);
}

MaybeLocal<Module> NoDependencies(Local<Context> context,
                                  Local<v8::String> specifier,
                                  Local<FixedArray> import_attributes,
                                  Local<Module> referrer) {
  // Synthetic modules never request anything.
  return MaybeLocal<Module>();
}

MaybeLocal<Value> PopulateSyntheticModule(Local<Context> context,
                                          Local<Module> module) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  // The specifier was handed to CreateSyntheticModule as the module name,
  // which is how these steps find the exports object again.
  std::string specifier = tns::ToString(isolate, module->GetResourceName());

  Local<Object> exports;
  if (!NsBuiltinModules::GetExports(context, specifier).ToLocal(&exports)) {
    return MaybeLocal<Value>();
  }

  Local<v8::String> defaultName = tns::ToV8String(isolate, "default");
  if (module->SetSyntheticModuleExport(isolate, defaultName, exports)
          .IsNothing()) {
    return MaybeLocal<Value>();
  }

  Local<v8::Array> keys;
  if (!ExportKeys(context, exports).ToLocal(&keys)) {
    return MaybeLocal<Value>();
  }
  for (uint32_t i = 0; i < keys->Length(); i++) {
    Local<Value> key;
    Local<Value> value;
    if (!keys->Get(context, i).ToLocal(&key) || !key->IsString()) {
      return MaybeLocal<Value>();
    }
    if (key.As<v8::String>()->StringEquals(defaultName)) {
      continue;
    }
    if (!exports->Get(context, key).ToLocal(&value) ||
        module->SetSyntheticModuleExport(isolate, key.As<v8::String>(), value)
            .IsNothing()) {
      return MaybeLocal<Value>();
    }
  }

  Local<Promise::Resolver> resolver;
  if (!Promise::Resolver::New(context).ToLocal(&resolver) ||
      !resolver->Resolve(context, v8::Undefined(isolate)).FromMaybe(false)) {
    return MaybeLocal<Value>();
  }
  return resolver->GetPromise();
}

}  // namespace

bool NsBuiltinModules::IsBuiltinScheme(const std::string& specifier) {
  return HasPrefix(specifier, kNsPrefix) || HasPrefix(specifier, kNodePrefix);
}

bool NsBuiltinModules::IsNsScheme(const std::string& specifier) {
  return HasPrefix(specifier, kNsPrefix);
}

bool NsBuiltinModules::IsRegistered(const std::string& specifier) {
  return Find(specifier) != nullptr;
}

std::string NsBuiltinModules::NotFoundMessage(const std::string& specifier) {
  return "No such built-in module: " + specifier;
}

MaybeLocal<Object> NsBuiltinModules::GetExports(Local<Context> context,
                                                const std::string& specifier) {
  const Registration* registration = Find(specifier);
  if (registration == nullptr) {
    return MaybeLocal<Object>();
  }

  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  auto it = cache->BuiltinModuleExports.find(specifier);
  if (it == cache->BuiltinModuleExports.end()) {
    if (!Instantiate(context, *registration)) {
      return MaybeLocal<Object>();
    }
    it = cache->BuiltinModuleExports.find(specifier);
    if (it == cache->BuiltinModuleExports.end()) {
      return MaybeLocal<Object>();
    }
  }
  return it->second->Get(isolate);
}

MaybeLocal<Module> NsBuiltinModules::GetModule(Local<Context> context,
                                               const std::string& specifier) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Caches> cache = Caches::Get(isolate);

  auto it = cache->BuiltinModules.find(specifier);
  if (it != cache->BuiltinModules.end()) {
    Local<Module> cached = it->second->Get(isolate);
    if (!cached.IsEmpty() && cached->GetStatus() != Module::kErrored) {
      return cached;
    }
    cache->BuiltinModules.erase(it);
  }

  Local<Object> exports;
  if (!GetExports(context, specifier).ToLocal(&exports)) {
    return MaybeLocal<Module>();
  }

  Local<v8::String> defaultName = tns::ToV8String(isolate, "default");
  std::vector<Local<v8::String>> exportNames{defaultName};
  Local<v8::Array> keys;
  if (!ExportKeys(context, exports).ToLocal(&keys)) {
    return MaybeLocal<Module>();
  }
  for (uint32_t i = 0; i < keys->Length(); i++) {
    Local<Value> key;
    if (!keys->Get(context, i).ToLocal(&key) || !key->IsString()) {
      return MaybeLocal<Module>();
    }
    if (!key.As<v8::String>()->StringEquals(defaultName)) {
      exportNames.push_back(key.As<v8::String>());
    }
  }

  Local<Module> module = Module::CreateSyntheticModule(
      isolate, tns::ToV8String(isolate, specifier),
      MemorySpan<const Local<v8::String>>(exportNames.data(),
                                          exportNames.size()),
      PopulateSyntheticModule);
  // No dependencies and no user code, so the module can be driven to its final
  // state here; importers then only ever see an evaluated module.
  if (!module->InstantiateModule(context, &NoDependencies).FromMaybe(false)) {
    return MaybeLocal<Module>();
  }
  if (module->Evaluate(context).IsEmpty()) {
    return MaybeLocal<Module>();
  }

  cache->BuiltinModules[specifier] =
      std::make_unique<Persistent<Module>>(isolate, module);
  return module;
}

Local<v8::Function> NsBuiltinModules::GetFormatFunc(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache->FormatFunc != nullptr) {
    return cache->FormatFunc->Get(isolate);
  }
  if (cache->FormatFuncUnavailable) {
    return Local<v8::Function>();
  }

  TryCatch tc(isolate);
  Local<Object> exports;
  Local<Value> format;
  if (!GetExports(context, "ns:util").ToLocal(&exports) ||
      !exports->Get(context, tns::ToV8String(isolate, "format"))
           .ToLocal(&format) ||
      !format->IsFunction()) {
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }
    // One attempt per realm: a broken builtin must not make every log call
    // recompile it.
    cache->FormatFuncUnavailable = true;
    return Local<v8::Function>();
  }

  cache->FormatFunc = std::make_unique<Persistent<v8::Function>>(
      isolate, format.As<v8::Function>());
  return format.As<v8::Function>();
}

}  // namespace tns
