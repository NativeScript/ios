// ModuleInternalCallbacks.mm
#include "ModuleInternalCallbacks.h"
#include <sys/stat.h>
#include <v8.h>
#include <string>
#include <unordered_map>
#include "Helpers.h"         // for tns::Exists
#include "ModuleInternal.h"  // for LoadScript(...)
#include "NativeScriptException.h"
#include "RuntimeConfig.h"

// Do NOT pull all v8 symbols into namespace here; String would clash with
// other typedefs inside the NativeScript codebase. We refer to v8 symbols
// with explicit `v8::` qualification to avoid ambiguities.

namespace tns {

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
  if (referrerPath.empty()) {
    // we never compiled this referrer
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
  } else if (!spec.empty() && spec[0] == '~') {
    // App root alias "~/" → <ApplicationPath>/
    std::string tail = spec.size() >= 2 && spec[1] == '/' ? spec.substr(2) : spec.substr(1);
    std::string base = RuntimeConfig.ApplicationPath + "/" + tail;
    candidateBases.push_back(base);
  } else if (!spec.empty() && spec[0] == '/') {
    // Absolute path within the bundle
    candidateBases.push_back(spec);
  } else {
    // Bare specifier – look inside tns_modules like the CommonJS resolver
    NSString* tnsModulesPath =
        [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:@"tns_modules"];

    std::string base1 = std::string([tnsModulesPath UTF8String]) + "/" + spec;
    candidateBases.push_back(base1);

    // Fallback to tns-core-modules/<spec>
    std::string base2 = base1 + "/tns-core-modules/" + spec;
    candidateBases.push_back(base2);
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

    if (!isFile(absPath)) {
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
}