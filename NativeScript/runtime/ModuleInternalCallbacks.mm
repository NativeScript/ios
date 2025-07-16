// ModuleInternalCallbacks.mm
#include "ModuleInternalCallbacks.h"
#include <sys/stat.h>
#include <v8.h>
#include <queue>
#include <string>
#include <unordered_map>
#include "Helpers.h"         // for tns::Exists
#include "ModuleInternal.h"  // for LoadScript(...)
#include "NativeScriptException.h"
#include "Runtime.h"  // for GetAppConfigValue
#include "RuntimeConfig.h"

// Do NOT pull all v8 symbols into namespace here; String would clash with
// other typedefs inside the NativeScript codebase. We refer to v8 symbols
// with explicit `v8::` qualification to avoid ambiguities.

namespace tns {

// ────────────────────────────────────────────────────────────────────────────
// Helper function to check if script loading logging is enabled
// This reads the "logScriptLoading" boolean option from nativescript.config (aka, package.json in
// the app bundle). Usage: Add "logScriptLoading": true to your nativescript.config to enable
// verbose logging of module resolution and dynamic imports for debugging.
static bool IsScriptLoadingLogEnabled() {
  id value = Runtime::GetAppConfigValue("logScriptLoading");
  return value ? [value boolValue] : false;
}

// ────────────────────────────────────────────────────────────────────────────
// Simple in-process registry: maps absolute file paths → compiled Module handles
std::unordered_map<std::string, v8::Global<v8::Module>> g_moduleRegistry;

// Callback invoked by V8 to resolve `import X from 'specifier';`
v8::MaybeLocal<v8::Module> ResolveModuleCallback(v8::Local<v8::Context> context,
                                                 v8::Local<v8::String> specifier,
                                                 v8::Local<v8::FixedArray> import_assertions,
                                                 v8::Local<v8::Module> referrer) {
  v8::Isolate* isolate = context->GetIsolate();

  // 1) Turn the specifier literal into a std::string:
  v8::String::Utf8Value specUtf8(isolate, specifier);
  std::string spec = *specUtf8 ? *specUtf8 : "";
  if (spec.empty()) {
    return v8::MaybeLocal<v8::Module>();
  }

  // 2) Find which filepath the referrer was compiled under
  std::string referrerPath;
  for (auto& kv : g_moduleRegistry) {
    v8::Local<v8::Module> registered = kv.second.Get(isolate);
    if (registered == referrer) {
      referrerPath = kv.first;
      break;
    }
  }
  // If we couldn't identify the referrer (e.g. coming from a dynamic import
  // where the embedder did not pass the compiled Module), we can still proceed
  // for absolute and application-rooted specifiers. Only bail out early when
  // the specifier is clearly relative (starts with "./" or "../") and we
  // would need the referrer's directory to resolve it.
  bool specIsRelative = !spec.empty() && spec[0] == '.';
  if (referrerPath.empty() && specIsRelative) {
    // Unable to resolve a relative path without knowing the base directory.
    return v8::MaybeLocal<v8::Module>();
  }

  // 3) Compute its directory
  size_t slash = referrerPath.find_last_of("/\\");
  std::string baseDir = slash == std::string::npos ? "" : referrerPath.substr(0, slash + 1);

  // 4) Resolve the import specifier relative to that directory.
  //    The incoming specifier may omit the file extension (e.g. "./foo") or
  //    point to a directory.  Try to follow Node-style resolution rules for
  //    the most common cases so that we locate the actual .mjs file on disk
  //    before handing the path to LoadScript.

  // ────────────────────────────────────────────────
  // Build initial absolute path candidates
  // ────────────────────────────────────────────────

  std::vector<std::string> candidateBases;

  if (!spec.empty() && spec[0] == '.') {
    // Relative import (./ or ../)
    std::string cleanSpec = spec.rfind("./", 0) == 0 ? spec.substr(2) : spec;
    candidateBases.push_back(baseDir + cleanSpec);
  } else if (spec.rfind("file://", 0) == 0) {
    // Absolute file URL, e.g. file:///app/path/to/chunk.mjs
    std::string tail = spec.substr(7);  // strip file://
    if (tail.rfind("/", 0) != 0) {
      tail = "/" + tail;
    }
    // If starts with /app/... drop the leading /app
    const std::string appPrefix = "/app/";
    std::string tailNoApp = tail;
    if (tail.rfind(appPrefix, 0) == 0) {
      tailNoApp = tail.substr(appPrefix.size());
    }
    // Candidate that keeps /app/ prefix stripped
    std::string baseNoApp = RuntimeConfig.ApplicationPath + "/" + tailNoApp;
    candidateBases.push_back(baseNoApp);

    // Also try path with original tail (includes /app/...) directly under application dir
    std::string baseWithApp = RuntimeConfig.ApplicationPath + tail;  // tail already begins with '/'
    candidateBases.push_back(baseWithApp);
  } else if (!spec.empty() && spec[0] == '~') {
    // Alias to application root using ~/path
    std::string tail = spec.size() >= 2 && spec[1] == '/' ? spec.substr(2) : spec.substr(1);
    std::string base = RuntimeConfig.ApplicationPath + "/" + tail;
    candidateBases.push_back(base);
  } else if (!spec.empty() && spec[0] == '/') {
    // Absolute path within the bundle
    candidateBases.push_back(spec);
  } else {
    // Bare specifier – resolve relative to the application root directory
    std::string base = RuntimeConfig.ApplicationPath + "/" + spec;
    candidateBases.push_back(base);

    // Additional heuristic: Webpack encodes path separators as underscores in
    // chunk IDs (e.g. "src_app_components_foo_bar_ts.mjs").  Try converting
    // those underscores back to slashes and look for that file as well.
    std::string withSlashes = spec;
    std::replace(withSlashes.begin(), withSlashes.end(), '_', '/');
    std::string baseSlashes = RuntimeConfig.ApplicationPath + "/" + withSlashes;
    if (baseSlashes != base) {
      candidateBases.push_back(baseSlashes);
    }
  }

  // We'll iterate these bases and attempt to resolve to an actual file
  std::string absPath;

  // Utility: returns true iff `p` exists AND is a regular file (not directory)
  auto isFile = [](const std::string& p) -> bool {
    struct stat st;
    if (stat(p.c_str(), &st) != 0) {
      return false;
    }
    return (st.st_mode & S_IFMT) == S_IFREG;
  };

  // Helper to append extension if missing
  auto withExt = [](const std::string& p, const std::string& ext) -> std::string {
    if (p.size() >= ext.size() && p.compare(p.size() - ext.size(), ext.size(), ext) == 0) {
      return p;
    }
    return p + ext;
  };

  //  ── Resolution attempts ───────────────────────────────────────
  // Iterate base candidates until we find a file match
  for (const std::string& baseCandidate : candidateBases) {
    absPath = baseCandidate;

    bool existsNow = isFile(absPath);
    if (IsScriptLoadingLogEnabled()) {
      NSLog(@"[resolver] %s -> %s", absPath.c_str(), existsNow ? "file" : "missing");
    }

    if (!existsNow) {
      // 1) Try adding .mjs, .js
      const char* exts[] = {".mjs", ".js"};
      bool found = false;
      for (const char* e : exts) {
        std::string cand = withExt(absPath, e);
        if (isFile(cand)) {
          absPath = cand;
          found = true;
          break;
        }
      }
      if (!found) {
        // 2) If absPath is directory, look for index files
        const char* idxExts[] = {"/index.mjs", "/index.js"};
        for (const char* idx : idxExts) {
          std::string cand = absPath + idx;
          if (isFile(cand)) {
            absPath = cand;
            found = true;
            break;
          }
        }
      }
      if (found) {
        break;
      }
    }
    if (isFile(absPath)) {
      break;  // stop at first hit
    }
  }

  // At this point, absPath is either a valid file or last attempted candidate.

  // If we still didn’t resolve to an actual file, surface an exception instead
  // of letting ReadModule() assert while trying to open a directory.
  if (!isFile(absPath)) {
    std::string msg = "Cannot find module " + spec + " (tried " + absPath + ")";
    isolate->ThrowException(v8::Exception::Error(tns::ToV8String(isolate, msg)));
    return v8::MaybeLocal<v8::Module>();
  }

  // Special handling for JSON imports (e.g. import data from './foo.json' assert {type:'json'})
  if (absPath.size() >= 5 && absPath.compare(absPath.size() - 5, 5, ".json") == 0) {
    // Read file contents
    std::string jsonText = tns::ReadText(absPath);

    // Build a small ES module that just exports the parsed JSON as default
    std::string moduleSource = "export default " + jsonText + ";";

    v8::Local<v8::String> sourceText = tns::ToV8String(isolate, moduleSource);
    // Build URL for stack traces
    std::string base = ReplaceAll(absPath, RuntimeConfig.BaseDir, "");
    std::string url = "file://" + base;

    v8::ScriptOrigin origin(
        isolate,
        v8::String::NewFromUtf8(isolate, url.c_str(), v8::NewStringType::kNormal).ToLocalChecked(),
        0, 0, false, -1, v8::Local<v8::Value>(), false, false, true /* is_module */);

    v8::ScriptCompiler::Source src(sourceText, origin);

    v8::Local<v8::Module> jsonModule;
    if (!v8::ScriptCompiler::CompileModule(isolate, &src).ToLocal(&jsonModule)) {
      isolate->ThrowException(
          v8::Exception::SyntaxError(tns::ToV8String(isolate, "Failed to compile JSON module")));
      return v8::MaybeLocal<v8::Module>();
    }

    // No imports inside this module, so instantiate directly
    if (!jsonModule->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
      return v8::MaybeLocal<v8::Module>();
    }

    // Evaluate immediately so namespace is populated
    v8::MaybeLocal<v8::Value> evalResult = jsonModule->Evaluate(context);
    if (evalResult.IsEmpty()) {
      return v8::MaybeLocal<v8::Module>();
    }

    // Store in registry and return
    g_moduleRegistry[absPath].Reset(isolate, jsonModule);
    return v8::MaybeLocal<v8::Module>(jsonModule);
  }

  // 5) If we’ve already compiled that module (non-JSON case), return it
  auto it = g_moduleRegistry.find(absPath);
  if (it != g_moduleRegistry.end()) {
    return v8::MaybeLocal<v8::Module>(it->second.Get(isolate));
  }

  // 6) Otherwise, compile & register it
  try {
    tns::ModuleInternal::LoadScript(isolate, absPath);
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    return v8::MaybeLocal<v8::Module>();
  }
  // LoadScript will have added it into g_moduleRegistry under absPath
  auto it2 = g_moduleRegistry.find(absPath);
  if (it2 == g_moduleRegistry.end()) {
    // something went wrong
    return v8::MaybeLocal<v8::Module>();
  }
  return v8::MaybeLocal<v8::Module>(it2->second.Get(isolate));
}

// ────────────────────────────────────────────────────────────────────────────
// Dynamic import() host callback
v8::MaybeLocal<v8::Promise> ImportModuleDynamicallyCallback(
    v8::Local<v8::Context> context, v8::Local<v8::ScriptOrModule> referrer,
    v8::Local<v8::String> specifier, v8::Local<v8::FixedArray> import_assertions) {
  v8::Isolate* isolate = context->GetIsolate();
  // Diagnostic: log every dynamic import attempt.
  v8::String::Utf8Value specUtf8(isolate, specifier);
  const char* cSpec = (*specUtf8) ? *specUtf8 : "<invalid>";
  NSString* specStr = [NSString stringWithUTF8String:cSpec];
  if (IsScriptLoadingLogEnabled()) {
    NSLog(@"[dyn-import] → %@", specStr);
  }
  v8::EscapableHandleScope scope(isolate);

  // Create a Promise resolver we'll resolve/reject synchronously for now.
  v8::Local<v8::Promise::Resolver> resolver = v8::Promise::Resolver::New(context).ToLocalChecked();

  // Re-use the static resolver to locate / compile the module.
  try {
    // Pass empty referrer since this V8 version doesn't expose GetModule() on
    // ScriptOrModule. The resolver will fall back to absolute-path heuristics.
    v8::Local<v8::Module> refMod;

    v8::MaybeLocal<v8::Module> maybeModule =
        ResolveModuleCallback(context, specifier, import_assertions, refMod);

    v8::Local<v8::Module> module;
    if (!maybeModule.ToLocal(&module)) {
      // ResolveModuleCallback already threw; forward the V8 exception
      return scope.Escape(resolver->GetPromise());
    }

    // If not yet instantiated/evaluated, do it now
    if (module->GetStatus() == v8::Module::kUninstantiated) {
      if (!module->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false)) {
        if (IsScriptLoadingLogEnabled()) {
          NSLog(@"[dyn-import] ✗ instantiate failed %@", specStr);
        }
        resolver
            ->Reject(context,
                     v8::Exception::Error(tns::ToV8String(isolate, "Failed to instantiate module")))
            .Check();
        return scope.Escape(resolver->GetPromise());
      }
    }

    if (module->GetStatus() != v8::Module::kEvaluated) {
      if (module->Evaluate(context).IsEmpty()) {
        if (IsScriptLoadingLogEnabled()) {
          NSLog(@"[dyn-import] ✗ evaluation failed %@", specStr);
        }
        v8::Local<v8::Value> ex =
            v8::Exception::Error(tns::ToV8String(isolate, "Evaluation failed"));
        resolver->Reject(context, ex).Check();
        return scope.Escape(resolver->GetPromise());
      }
    }

    // Special handling for webpack chunks: check if this is a webpack chunk and install it
    v8::Local<v8::Value> namespaceObj = module->GetModuleNamespace();
    if (namespaceObj->IsObject()) {
      v8::Local<v8::Object> nsObj = namespaceObj.As<v8::Object>();

      // Check if this is a webpack chunk (has __webpack_ids__ export)
      v8::Local<v8::String> webpackIdsKey = tns::ToV8String(isolate, "__webpack_ids__");
      v8::Local<v8::Value> webpackIds;
      if (nsObj->Get(context, webpackIdsKey).ToLocal(&webpackIds) && !webpackIds->IsUndefined()) {
        if (IsScriptLoadingLogEnabled()) {
          NSLog(@"[dyn-import] Detected webpack chunk %@", specStr);
        }
        // This is a webpack chunk, get the webpack runtime from the runtime module
        try {
          // Import the runtime module to get __webpack_require__
          // For import assertions, we need to pass an empty FixedArray
          // Use the empty fixed array from the isolate's roots
          v8::Local<v8::FixedArray> empty_assertions = v8::Local<v8::FixedArray>();
          v8::MaybeLocal<v8::Module> maybeRuntimeModule =
              ResolveModuleCallback(context, tns::ToV8String(isolate, "file:///app/runtime.mjs"),
                                    empty_assertions, v8::Local<v8::Module>());

          v8::Local<v8::Module> runtimeModule;
          if (maybeRuntimeModule.ToLocal(&runtimeModule)) {
            v8::Local<v8::Value> runtimeNamespace = runtimeModule->GetModuleNamespace();
            if (runtimeNamespace->IsObject()) {
              v8::Local<v8::Object> runtimeObj = runtimeNamespace.As<v8::Object>();
              v8::Local<v8::String> defaultKey = tns::ToV8String(isolate, "default");
              v8::Local<v8::Value> webpackRequire;

              if (runtimeObj->Get(context, defaultKey).ToLocal(&webpackRequire) &&
                  webpackRequire->IsObject()) {
                if (IsScriptLoadingLogEnabled()) {
                  NSLog(@"[dyn-import] Found runtime module default export");
                }
                v8::Local<v8::String> installKey = tns::ToV8String(isolate, "C");
                v8::Local<v8::Value> installFn;
                if (webpackRequire.As<v8::Object>()->Get(context, installKey).ToLocal(&installFn) &&
                    installFn->IsFunction()) {
                  if (IsScriptLoadingLogEnabled()) {
                    NSLog(@"[dyn-import] Calling webpack installChunk function");
                  }
                  // Call webpack's installChunk function with the module namespace
                  v8::Local<v8::Value> args[] = {namespaceObj};
                  v8::Local<v8::Value> result;
                  if (!installFn.As<v8::Function>()
                           ->Call(context, v8::Undefined(isolate), 1, args)
                           .ToLocal(&result)) {
                    // If the call fails, we can ignore it since this is just a helper for webpack
                    // chunks
                    if (IsScriptLoadingLogEnabled()) {
                      NSLog(@"[dyn-import] ✗ webpack installChunk call failed");
                    }
                  } else {
                    if (IsScriptLoadingLogEnabled()) {
                      NSLog(@"[dyn-import] ✓ webpack installChunk call succeeded");
                    }
                  }
                } else {
                  if (IsScriptLoadingLogEnabled()) {
                    NSLog(@"[dyn-import] ✗ webpack installChunk function not found");
                  }
                }
              } else {
                if (IsScriptLoadingLogEnabled()) {
                  NSLog(@"[dyn-import] ✗ runtime module default export not found");
                }
              }
            }
          } else {
            if (IsScriptLoadingLogEnabled()) {
              NSLog(@"[dyn-import] ✗ runtime module not found");
            }
          }
        } catch (...) {
          if (IsScriptLoadingLogEnabled()) {
            NSLog(@"[dyn-import] ✗ exception while accessing runtime module");
          }
        }
      }
    }

    resolver->Resolve(context, module->GetModuleNamespace()).Check();
    if (IsScriptLoadingLogEnabled()) {
      NSLog(@"[dyn-import] ✓ resolved %@", specStr);
    }
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
    if (IsScriptLoadingLogEnabled()) {
      NSLog(@"[dyn-import] ✗ native failed %@", specStr);
    }
    resolver
        ->Reject(context, v8::Exception::Error(
                              tns::ToV8String(isolate, "Native error during dynamic import")))
        .Check();
  }

  return scope.Escape(resolver->GetPromise());
}
}