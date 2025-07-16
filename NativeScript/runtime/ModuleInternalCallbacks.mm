// ModuleInternalCallbacks.mm
#include "ModuleInternalCallbacks.h"
#include <v8.h>
#include <string>
#include <unordered_map>
#include "Helpers.h"         // for tns::Exists
#include "ModuleInternal.h"  // for LoadScript(...)

using namespace v8;

namespace tns {

// ────────────────────────────────────────────────────────────────────────────
// Simple in-process registry: maps absolute file paths → compiled Module handles
std::unordered_map<std::string, Global<Module>> g_moduleRegistry;

// Callback invoked by V8 to resolve `import X from 'specifier';`
MaybeLocal<Module> ResolveModuleCallback(Local<Context> context, Local<String> specifier,
                                         Local<FixedArray> import_assertions,
                                         Local<Module> referrer) {
  Isolate* isolate = context->GetIsolate();

  // 1) Turn the specifier literal into a std::string:
  v8::String::Utf8Value specUtf8(isolate, specifier);
  std::string spec = *specUtf8 ? *specUtf8 : "";
  if (spec.empty()) {
    return MaybeLocal<Module>();
  }

  // 2) Find which filepath the referrer was compiled under
  std::string referrerPath;
  for (auto& kv : g_moduleRegistry) {
    Local<Module> registered = kv.second.Get(isolate);
    if (registered == referrer) {
      referrerPath = kv.first;
      break;
    }
  }
  if (referrerPath.empty()) {
    // we never compiled this referrer
    return MaybeLocal<Module>();
  }

  // 3) Compute its directory
  size_t slash = referrerPath.find_last_of("/\\");
  std::string baseDir = slash == std::string::npos ? "" : referrerPath.substr(0, slash + 1);

  // 4) Resolve the import specifier relative to that directory.
  //    The incoming specifier may omit the file extension (e.g. "./foo") or
  //    point to a directory.  Try to follow Node-style resolution rules for
  //    the most common cases so that we locate the actual .mjs file on disk
  //    before handing the path to LoadScript.

  std::string absPath = baseDir + spec;

  auto ensureMjsPath = [](const std::string& p) {
    if (p.size() >= 4 && p.compare(p.size() - 4, 4, ".mjs") == 0) {
      return p;  // already has extension
    }
    return p + ".mjs";
  };

  // If the path doesn't exist as-is, attempt to append ".mjs" or look for an
  // index file inside a directory.  We keep the first match that exists.
  if (!tns::Exists(absPath.c_str())) {
    std::string tryFile = ensureMjsPath(absPath);
    if (tns::Exists(tryFile.c_str())) {
      absPath = tryFile;
    } else {
      // try /index.mjs inside the directory
      std::string tryIndex = absPath + "/index.mjs";
      if (tns::Exists(tryIndex.c_str())) {
        absPath = tryIndex;
      }
    }
  }

  // 5) If we’ve already compiled that module, return it
  auto it = g_moduleRegistry.find(absPath);
  if (it != g_moduleRegistry.end()) {
    return MaybeLocal<Module>(it->second.Get(isolate));
  }

  // 6) Otherwise, compile & register it
  ModuleInternal::LoadScript(isolate, absPath);
  // LoadScript will have added it into g_moduleRegistry under absPath
  it = g_moduleRegistry.find(absPath);
  if (it == g_moduleRegistry.end()) {
    // something went wrong
    return MaybeLocal<Module>();
  }
  return MaybeLocal<Module>(it->second.Get(isolate));
}
}