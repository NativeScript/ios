#include "ModuleInternal.h"
#include <Foundation/Foundation.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>
#include <string>
#include "Caches.h"
#include "Helpers.h"
#include "ModuleInternalCallbacks.h"  // for ResolveModuleCallback
#include "NativeScriptException.h"
#include "Runtime.h"  // for GetAppConfigValue
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

// Helper function to check if a module name looks like an optional external module
bool IsLikelyOptionalModule(const std::string& moduleName) {
  // Check if it's a bare module name (no path separators) that could be an npm package
  if (moduleName.find('/') == std::string::npos && moduleName.find('\\') == std::string::npos &&
      moduleName[0] != '.' && moduleName[0] != '~' && moduleName[0] != '/') {
    return true;
  }
  return false;
}

ModuleInternal::ModuleInternal(Local<Context> context) {
  std::string requireFactoryScript = "(function() { "
                                     "    function require_factory(requireInternal, dirName) { "
                                     "        return function require(modulePath) { "
                                     "            if(global.__pauseOnNextRequire) {  debugger; "
                                     "global.__pauseOnNextRequire = false; }"
                                     "            return requireInternal(modulePath, dirName); "
                                     "        } "
                                     "    } "
                                     "    return require_factory; "
                                     "})()";

  Isolate* isolate = context->GetIsolate();
  Local<Object> global = context->Global();
  Local<Script> script;
  TryCatch tc(isolate);
  if (!Script::Compile(context, tns::ToV8String(isolate, requireFactoryScript.c_str()))
           .ToLocal(&script) &&
      tc.HasCaught()) {
    tns::LogError(isolate, tc);
    tns::Assert(false, isolate);
  }
  tns::Assert(!script.IsEmpty(), isolate);

  Local<Value> result;
  if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
    tns::LogError(isolate, tc);
    tns::Assert(false, isolate);
  }
  tns::Assert(!result.IsEmpty() && result->IsFunction(), isolate);

  this->requireFactoryFunction_ =
      std::make_unique<Persistent<v8::Function>>(isolate, result.As<v8::Function>());

  Local<FunctionTemplate> requireFuncTemplate =
      FunctionTemplate::New(isolate, RequireCallback, External::New(isolate, this));
  this->requireFunction_ = std::make_unique<Persistent<v8::Function>>(
      isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

  Local<v8::Function> globalRequire = GetRequireFunction(isolate, RuntimeConfig.ApplicationPath);
  bool success =
      global->Set(context, tns::ToV8String(isolate, "require"), globalRequire).FromMaybe(false);
  tns::Assert(success, isolate);
}

bool ModuleInternal::RunModule(Isolate* isolate, std::string path) {
  // Debug: Log module loading
  printf("ModuleInternal::RunModule: Loading module: %s\n", path.c_str());

  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
  Local<Object> globalObject = context->Global();
  // Ensure global.__dirname is defined so ESM/CommonJS shims relying on it work.
  {
    Local<Value> dirVal;
    bool hasDir = globalObject->Get(context, ToV8String(isolate, "__dirname")).ToLocal(&dirVal);
    if (!hasDir || dirVal->IsUndefined()) {
      bool setDir = globalObject
                        ->Set(context, ToV8String(isolate, "__dirname"),
                              ToV8String(isolate, RuntimeConfig.ApplicationPath))
                        .FromMaybe(false);
      tns::Assert(setDir, isolate);
    }
  }
  Local<Value> requireObj;
  bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
  tns::Assert(success && requireObj->IsFunction(), isolate);
  Local<v8::Function> requireFunc = requireObj.As<v8::Function>();
  Local<Value> args[] = {ToV8String(isolate, path)};
  Local<Value> result;
  success = requireFunc->Call(context, globalObject, 1, args).ToLocal(&result);
  return success;
}

Local<v8::Function> ModuleInternal::GetRequireFunction(Isolate* isolate,
                                                       const std::string& dirName) {
  Local<v8::Function> requireFuncFactory = requireFactoryFunction_->Get(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> requireInternalFunc = this->requireFunction_->Get(isolate);
  Local<Value> args[2]{requireInternalFunc, tns::ToV8String(isolate, dirName.c_str())};

  Local<Value> result;
  Local<Object> thiz = Object::New(isolate);
  bool success = requireFuncFactory->Call(context, thiz, 2, args).ToLocal(&result);
  tns::Assert(success && !result.IsEmpty() && result->IsFunction(), isolate);

  return result.As<v8::Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  // Declare these outside try block so they're available in catch
  std::string moduleName;
  std::string callingModuleDirName;
  NSString* fullPath = nil;

  try {
    ModuleInternal* moduleInternal =
        static_cast<ModuleInternal*>(info.Data().As<External>()->Value());

    moduleName = tns::ToString(isolate, info[0].As<v8::String>());
    callingModuleDirName = tns::ToString(isolate, info[1].As<v8::String>());
    if (moduleName.length() > 0 && moduleName[0] != '/') {
      if (moduleName[0] == '.') {
        fullPath = [[NSString stringWithUTF8String:callingModuleDirName.c_str()]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];
      } else if (moduleName[0] == '~') {
        moduleName = moduleName.substr(2);
        fullPath = [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];
      } else {
        NSString* tnsModulesPath =
            [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
                stringByAppendingPathComponent:@"tns_modules"];
        fullPath = [tnsModulesPath
            stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];

        const char* path1 = [fullPath fileSystemRepresentation];
        const char* path2 =
            [[fullPath stringByAppendingPathExtension:@"mjs"] fileSystemRepresentation];

        if (!tns::Exists(path1) && !tns::Exists(path2)) {
          fullPath = [tnsModulesPath stringByAppendingPathComponent:@"tns-core-modules"];
          fullPath = [fullPath
              stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];
        }
      }
    } else {
      fullPath = [NSString stringWithUTF8String:moduleName.c_str()];
    }

    NSString* fileNameOnly = [fullPath lastPathComponent];
    NSString* pathOnly = [fullPath stringByDeletingLastPathComponent];

    bool isData = false;
    Local<Object> moduleObj =
        moduleInternal->LoadImpl(isolate, [fileNameOnly UTF8String], [pathOnly UTF8String], isData);
    if (moduleObj.IsEmpty()) {
      return;
    }

    if (isData) {
      tns::Assert(!moduleObj.IsEmpty(), isolate);
      info.GetReturnValue().Set(moduleObj);
    } else {
      Local<Context> context = isolate->GetCurrentContext();
      Local<Value> exportsObj;
      bool success =
          moduleObj->Get(context, tns::ToV8String(isolate, "exports")).ToLocal(&exportsObj);
      tns::Assert(success, isolate);
      info.GetReturnValue().Set(exportsObj);
    }
  } catch (NativeScriptException& ex) {
    // Add context about the require call
    std::string contextMsg = "Error in require() call:";
    contextMsg += "\n  Requested module: '" + moduleName + "'";
    contextMsg += "\n  Called from: " + callingModuleDirName;
    if (fullPath != nil) {
      contextMsg += "\n  Resolved path: " + std::string([fullPath UTF8String]);
    }

    // Add JavaScript stack trace to show who called require
    Local<StackTrace> stackTrace =
        StackTrace::CurrentStackTrace(isolate, 10, StackTrace::StackTraceOptions::kDetailed);
    std::string jsStackTrace = "";
    if (!stackTrace.IsEmpty()) {
      for (int i = 0; i < stackTrace->GetFrameCount(); i++) {
        Local<StackFrame> frame = stackTrace->GetFrame(isolate, i);
        Local<v8::String> scriptName = frame->GetScriptName();
        Local<v8::String> functionName = frame->GetFunctionName();
        int lineNumber = frame->GetLineNumber();
        int columnNumber = frame->GetColumn();

        jsStackTrace += "\n    at ";
        std::string funcName = tns::ToString(isolate, functionName);
        std::string scriptNameStr = tns::ToString(isolate, scriptName);

        if (!funcName.empty()) {
          jsStackTrace += funcName + " (";
        } else {
          jsStackTrace += "<anonymous> (";
        }
        jsStackTrace += scriptNameStr + ":" + std::to_string(lineNumber) + ":" +
                        std::to_string(columnNumber) + ")";
      }
    }

    contextMsg += "\n\nJavaScript stack trace:" + jsStackTrace;
    contextMsg += "\n\nOriginal error:\n" + ex.getMessage();

    // Include original stack trace if available
    if (!ex.getStackTrace().empty()) {
      contextMsg += "\n\nOriginal stack trace:\n" + ex.getStackTrace();
    }

    NativeScriptException contextEx(isolate, contextMsg);
    contextEx.ReThrowToV8(isolate);
  }
}

Local<Object> ModuleInternal::LoadImpl(Isolate* isolate, const std::string& moduleName,
                                       const std::string& baseDir, bool& isData) {
  size_t lastIndex = moduleName.find_last_of(".");
  std::string moduleNameWithoutExtension =
      (lastIndex == std::string::npos) ? moduleName : moduleName.substr(0, lastIndex);
  std::string cacheKey = baseDir + "*" + moduleNameWithoutExtension;
  auto it = this->loadedModules_.find(cacheKey);

  if (it != this->loadedModules_.end()) {
    return it->second->Get(isolate);
  }

  Local<Object> moduleObj;
  Local<Value> exportsObj;
  std::string path;

  try {
    path = this->ResolvePath(isolate, baseDir, moduleName);
  } catch (NativeScriptException& ex) {
    // Add context about the module resolution
    std::string contextMsg = "Failed to resolve module: '" + moduleName + "'";
    contextMsg += "\n  Base directory: " + baseDir;
    contextMsg += "\n  Module name: " + moduleName;
    contextMsg += "\n\nOriginal error:\n" + ex.getMessage();

    throw NativeScriptException(isolate, contextMsg);
  }

  if (path.empty()) {
    // Create placeholder module for optional modules
    if (IsLikelyOptionalModule(moduleName)) {
      return this->CreatePlaceholderModule(isolate, moduleName, cacheKey);
    }
    return Local<Object>();
  }

  NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
  NSString* extension = [pathStr pathExtension];
  if ([extension isEqualToString:@"json"]) {
    isData = true;
  }

  auto it2 = this->loadedModules_.find(path);
  if (it2 != this->loadedModules_.end()) {
    return it2->second->Get(isolate);
  }

  if ([extension isEqualToString:@"mjs"]) {
    moduleObj = this->LoadModule(isolate, path, cacheKey);
  } else if ([extension isEqualToString:@"json"]) {
    moduleObj = this->LoadData(isolate, path);
  } else {
    // TODO: throw an error for unsupported file extension
    tns::Assert(false, isolate);
  }

  return moduleObj;
}

Local<Object> ModuleInternal::LoadModule(Isolate* isolate, const std::string& modulePath,
                                         const std::string& cacheKey) {
  Local<Object> moduleObj = Object::New(isolate);
  Local<Object> exportsObj = Object::New(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  bool success =
      moduleObj->Set(context, tns::ToV8String(isolate, "exports"), exportsObj).FromMaybe(false);
  tns::Assert(success, isolate);

  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);

  Local<v8::String> fileName = tns::ToV8String(isolate, modulePath);
  success =
      moduleObj->DefineOwnProperty(context, tns::ToV8String(isolate, "id"), fileName, readOnlyFlags)
          .FromMaybe(false);
  tns::Assert(success, isolate);

  std::shared_ptr<Persistent<Object>> poModuleObj =
      std::make_shared<Persistent<Object>>(isolate, moduleObj);
  TempModule tempModule(this, modulePath, cacheKey, poModuleObj);

  // Compile/load the JavaScript/ESM source
  Local<Value> scriptValue = LoadScript(isolate, modulePath);

  bool isESM = modulePath.size() >= 4 && modulePath.compare(modulePath.size() - 4, 4, ".mjs") == 0;

  // Debug: Log ES module detection
  printf("LoadModule: Module path: %s, isESM: %s\n", modulePath.c_str(), isESM ? "true" : "false");

  if (isESM) {
    // For ES modules the returned value is the module namespace object, not a
    // factory function. Wire it as the exports and skip CommonJS invocation.
    printf("LoadModule: Processing as ES module\n");
    if (!scriptValue->IsObject()) {
      printf("LoadModule: ES module failed - scriptValue is not an object\n");
      throw NativeScriptException(isolate, "Failed to load ES module " + modulePath);
    }
    printf("LoadModule: ES module loaded successfully\n");

    // Debug: Check if we're in a worker context and if self.onmessage is set
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache->isWorker) {
      printf("LoadModule: In worker context, checking self.onmessage\n");
      Local<Context> context = isolate->GetCurrentContext();
      Local<Object> global = context->Global();

      // Check if self exists
      Local<Value> selfValue;
      if (global->Get(context, ToV8String(isolate, "self")).ToLocal(&selfValue)) {
        printf("LoadModule: self exists: %s\n", selfValue->IsObject() ? "object" : "not object");
        if (selfValue->IsObject()) {
          Local<Object> selfObj = selfValue.As<Object>();
          Local<Value> onmessageValue;
          if (selfObj->Get(context, ToV8String(isolate, "onmessage")).ToLocal(&onmessageValue)) {
            printf("LoadModule: self.onmessage exists: %s\n",
                   onmessageValue->IsFunction() ? "function" : "not function");
          } else {
            printf("LoadModule: self.onmessage does not exist\n");
          }
        }
      } else {
        printf("LoadModule: self does not exist\n");
      }
    }

    exportsObj = scriptValue.As<Object>();
    bool succ =
        moduleObj->Set(context, tns::ToV8String(isolate, "exports"), exportsObj).FromMaybe(false);
    tns::Assert(succ, isolate);

    tempModule.SaveToCache();
    return moduleObj;
  }

  // Classic CommonJS path – expect a factory function.
  if (!scriptValue->IsFunction()) {
    throw NativeScriptException(isolate,
                                "Expected module factory to be a function for " + modulePath);
  }
  v8::Local<v8::Function> moduleFunc = scriptValue.As<v8::Function>();

  {
    TryCatch tc(isolate);
    // moduleFunc = script->Run(context).ToLocalChecked().As<v8::Function>();
    if (tc.HasCaught()) {
      throw NativeScriptException(isolate, tc, "Error running script " + modulePath);
    }
  }

  std::string parentDir = [[[NSString stringWithUTF8String:modulePath.c_str()]
      stringByDeletingLastPathComponent] UTF8String];
  Local<v8::Function> require = GetRequireFunction(isolate, parentDir);
  Local<Value> requireArgs[5]{moduleObj, exportsObj, require,
                              tns::ToV8String(isolate, modulePath.c_str()),
                              tns::ToV8String(isolate, parentDir.c_str())};

  success = moduleObj->Set(context, tns::ToV8String(isolate, "require"), require).FromMaybe(false);
  tns::Assert(success, isolate);

  {
    TryCatch tc(isolate);
    Local<Value> result;
    Local<Object> thiz = Object::New(isolate);
    success =
        moduleFunc->Call(context, thiz, sizeof(requireArgs) / sizeof(Local<Value>), requireArgs)
            .ToLocal(&result);
    if (!success || tc.HasCaught()) {
      throw NativeScriptException(isolate, tc, "Error calling module function");
    }
  }

  tempModule.SaveToCache();
  return moduleObj;
}

Local<Object> ModuleInternal::LoadData(Isolate* isolate, const std::string& modulePath) {
  Local<Object> json;

  std::string jsonData = tns::ReadText(modulePath);

  Local<v8::String> jsonStr = tns::ToV8String(isolate, jsonData);

  Local<Context> context = isolate->GetCurrentContext();
  TryCatch tc(isolate);
  MaybeLocal<Value> maybeValue = JSON::Parse(context, jsonStr);
  if (maybeValue.IsEmpty() || tc.HasCaught()) {
    std::string errMsg = "Cannot parse JSON file " + modulePath;
    throw NativeScriptException(isolate, tc, errMsg);
  }

  Local<Value> value = maybeValue.ToLocalChecked();
  if (!value->IsObject()) {
    std::string errMsg = "JSON is not valid, file=" + modulePath;
    throw NativeScriptException(errMsg);
  }

  json = value.As<Object>();

  this->loadedModules_.emplace(modulePath, std::make_shared<Persistent<Object>>(isolate, json));

  return json;
}

Local<Value> ModuleInternal::LoadScript(Isolate* isolate, const std::string& path) {
  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".mjs") == 0) {
    // Treat all .mjs files as standard ES modules.
    return ModuleInternal::LoadESModule(isolate, path);
  }

  Local<Script> script = ModuleInternal::LoadClassicScript(isolate, path);
  // run it and return the value
  return script->Run(isolate->GetCurrentContext()).ToLocalChecked();
}

Local<Script> ModuleInternal::LoadClassicScript(Isolate* isolate, const std::string& path) {
  // Ensure the resolved path maps to an actual regular file before attempting
  // to read/compile it.  This prevents `ReadModule` from aborting the process
  // when given a directory or non-existent path.
  struct stat st;
  if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
    throw NativeScriptException("Cannot find module " + path);
  }

  auto context = isolate->GetCurrentContext();
  // build URL
  std::string base = ReplaceAll(path, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;

  // wrap & cache lookup
  Local<v8::String> sourceText = ModuleInternal::WrapModuleContent(isolate, path);
  auto* cacheData = ModuleInternal::LoadScriptCache(path);

  // note: is_module=false here
  ScriptOrigin origin(
      isolate,
      v8::String::NewFromUtf8(isolate, url.c_str(), NewStringType::kNormal).ToLocalChecked(),
      0,      // line offset
      0,      // column offset
      false,  // shared_cross_origin
      -1,     // script_id
      Local<Value>(),
      false,  // is_opaque
      false,  // is_wasm
      false   // is_module
  );
  ScriptCompiler::Source source(sourceText, origin, cacheData);

  auto opts = cacheData ? ScriptCompiler::kConsumeCodeCache : ScriptCompiler::kNoCompileOptions;

  TryCatch tc(isolate);
  Local<Script> script;
  if (!ScriptCompiler::Compile(context, &source, opts).ToLocal(&script) || tc.HasCaught()) {
    throw NativeScriptException(isolate, tc, "Cannot compile script " + path);
  }

  if (cacheData == nullptr) {
    ModuleInternal::SaveScriptCache(script, path);
  }

  return script;
}

Local<Value> ModuleInternal::LoadESModule(Isolate* isolate, const std::string& path) {
  auto context = isolate->GetCurrentContext();

  // 1) Prepare URL & source
  std::string base = ReplaceAll(path, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;
  v8::Local<v8::String> sourceText = ModuleInternal::WrapModuleContent(isolate, path);
  auto* cacheData = ModuleInternal::LoadScriptCache(path);

  ScriptOrigin origin(
      isolate,
      v8::String::NewFromUtf8(isolate, url.c_str(), NewStringType::kNormal).ToLocalChecked(), 0, 0,
      false, -1, Local<Value>(), false, false,
      true  // ← is_module
  );
  ScriptCompiler::Source source(sourceText, origin, cacheData);

  // 2) Compile with its own TryCatch
  Local<Module> module;
  {
    TryCatch tcCompile(isolate);
    MaybeLocal<Module> maybeMod = ScriptCompiler::CompileModule(
        isolate, &source,
        cacheData ? ScriptCompiler::kConsumeCodeCache : ScriptCompiler::kNoCompileOptions);

    if (!maybeMod.ToLocal(&module)) {
      // V8 threw a syntax error or similar
      throw NativeScriptException(isolate, tcCompile, "Cannot compile ES module " + path);
    }
  }

  // 3) Register for resolution callback
  extern std::unordered_map<std::string, Global<Module>> g_moduleRegistry;
  g_moduleRegistry[path].Reset(isolate, module);

  // 4) Save cache if first time
  if (cacheData == nullptr) {
    Local<UnboundModuleScript> unbound = module->GetUnboundModuleScript();
    auto* generatedCache = ScriptCompiler::CreateCodeCache(unbound);
    ModuleInternal::SaveScriptCache(generatedCache, path);
  }

  // 5) Instantiate (link) with its own TryCatch
  {
    TryCatch tcLink(isolate);
    bool linked = module->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false);

    if (!linked) {
      if (tcLink.HasCaught()) {
        throw NativeScriptException(isolate, tcLink, "Cannot instantiate module " + path);
      } else {
        // V8 gave no exception object—throw plain text
        throw NativeScriptException(isolate, "Cannot instantiate module " + path);
      }
    }
  }

  // 6) Evaluate with its own TryCatch
  Local<Value> result;
  {
    TryCatch tcEval(isolate);
    printf("LoadESModule: About to evaluate module: %s\n", path.c_str());
    if (!module->Evaluate(context).ToLocal(&result)) {
      printf("LoadESModule: Evaluation failed for module: %s\n", path.c_str());
      throw NativeScriptException(isolate, tcEval, "Cannot evaluate module " + path);
    }
    printf("LoadESModule: Evaluation completed successfully for module: %s\n", path.c_str());

    // Handle the case where evaluation returns a Promise (for top-level await)
    if (result->IsPromise()) {
      printf("LoadESModule: Module evaluation returned a Promise, waiting for resolution\n");
      Local<Promise> promise = result.As<Promise>();

      // For worker context, we need to wait for the promise to resolve
      // This is important for modules that use top-level await or have async initialization
      std::shared_ptr<Caches> cache = Caches::Get(isolate);
      if (cache->isWorker) {
        printf("LoadESModule: In worker context, processing promise resolution\n");

        // Run the microtask queue to allow the promise to resolve
        while (promise->State() == Promise::kPending) {
          isolate->PerformMicrotaskCheckpoint();
          // Add a small delay to prevent busy waiting
          usleep(1000);  // 1ms
        }

        if (promise->State() == Promise::kRejected) {
          printf("LoadESModule: Promise was rejected\n");
          Local<Value> reason = promise->Result();
          isolate->ThrowException(reason);
          throw NativeScriptException(isolate, tcEval, "Module evaluation promise rejected");
        }

        printf("LoadESModule: Promise resolved successfully\n");
      }
    }
  }

  // 7) Return the namespace
  return module->GetModuleNamespace();
}

MaybeLocal<Value> ModuleInternal::RunScriptString(Isolate* isolate, Local<Context> context,
                                                  const std::string scriptString) {
  ScriptCompiler::CompileOptions options = ScriptCompiler::kNoCompileOptions;
  ScriptCompiler::Source source(tns::ToV8String(isolate, scriptString));
  TryCatch tc(isolate);
  Local<Script> script = ScriptCompiler::Compile(context, &source, options).ToLocalChecked();
  MaybeLocal<Value> result = script->Run(context);
  return result;
}

void ModuleInternal::RunScript(Isolate* isolate, std::string script) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
  Local<Object> globalObject = context->Global();
  Local<Value> requireObj;
  bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
  tns::Assert(success && requireObj->IsFunction(), isolate);
  Local<Value> result;
  this->RunScriptString(isolate, context, script);
}

v8::Local<v8::String> ModuleInternal::WrapModuleContent(v8::Isolate* isolate,
                                                        const std::string& path) {
  // For classical scripts we wrap the source into the CommonJS factory function
  // but for ES modules (".mjs") we must leave the source intact so that the
  // V8 parser can recognise the "export"/"import" syntax. Wrapping an ES module
  // in a function expression would turn those top-level keywords into syntax
  // errors (e.g. `export *` → "Unexpected token '*'").

  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".mjs") == 0) {
    // Read raw text without wrapping.
    std::string sourceText = tns::ReadText(path);

    // For ES modules in worker context, we need to provide access to global objects
    // since ES modules run in their own scope
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache && cache->isWorker) {
      // Prepend global declarations to make worker globals available in ES module scope
      std::string globalDeclarations = "const self = globalThis.self || globalThis;\n"
                                       "const postMessage = globalThis.postMessage;\n"
                                       "const close = globalThis.close;\n"
                                       "const importScripts = globalThis.importScripts;\n"
                                       "const console = globalThis.console;\n"
                                       "\n";

      sourceText = globalDeclarations + sourceText;
    }

    return tns::ToV8String(isolate, sourceText);
  }

  return tns::ReadModule(isolate, path);
}

std::string ModuleInternal::ResolvePath(Isolate* isolate, const std::string& baseDir,
                                        const std::string& moduleName) {
  NSString* baseDirStr = [NSString stringWithUTF8String:baseDir.c_str()];
  NSString* moduleNameStr = [NSString stringWithUTF8String:moduleName.c_str()];
  NSString* fullPath =
      [[baseDirStr stringByAppendingPathComponent:moduleNameStr] stringByStandardizingPath];

  NSFileManager* fileManager = [NSFileManager defaultManager];
  BOOL isDirectory;
  BOOL exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];

  if (exists == YES && isDirectory == YES) {
    NSString* jsFile = [fullPath stringByAppendingPathExtension:@"mjs"];
    BOOL isDir;
    if ([fileManager fileExistsAtPath:jsFile isDirectory:&isDir] && isDir == NO) {
      return [jsFile UTF8String];
    }
  }

  if (exists == NO) {
    fullPath = [fullPath stringByAppendingPathExtension:@"mjs"];
    exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
  }

  if (exists == NO) {
    // Check if this looks like an optional module
    if (IsLikelyOptionalModule(moduleName)) {
      // Return empty string to indicate optional module not found
      return std::string();
    }

    // Create a detailed error message with context
    std::string errorMsg = "Module not found: '" + moduleName + "'";
    errorMsg += "\n  Base directory: " + baseDir;
    errorMsg += "\n  Attempted paths:";

    // Show the original path attempt
    NSString* originalPath =
        [[baseDirStr stringByAppendingPathComponent:moduleNameStr] stringByStandardizingPath];
    errorMsg += "\n    - " + std::string([originalPath UTF8String]);
    errorMsg +=
        "\n    - " + std::string([[originalPath stringByAppendingPathExtension:@"mjs"] UTF8String]);

    throw NativeScriptException(isolate, errorMsg);
  }

  if (isDirectory == NO) {
    return [fullPath UTF8String];
  }

  // Try to resolve module from main entry in package.json
  NSString* packageJson = [fullPath stringByAppendingPathComponent:@"package.json"];
  bool error = false;
  std::string entry = this->ResolvePathFromPackageJson([packageJson UTF8String], error);
  if (error) {
    throw NativeScriptException("Unable to locate main entry in " +
                                std::string([packageJson UTF8String]));
  }

  if (!entry.empty()) {
    fullPath = [NSString stringWithUTF8String:entry.c_str()];
  }

  exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
  if (exists == YES && isDirectory == NO) {
    return [fullPath UTF8String];
  }

  if (exists == NO) {
    fullPath = [fullPath stringByAppendingPathExtension:@"mjs"];
  } else {
    fullPath = [fullPath stringByAppendingPathComponent:@"index.mjs"];
  }

  exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
  if (exists == NO) {
    // Check if this looks like an optional module
    if (IsLikelyOptionalModule(moduleName)) {
      // Return empty string to indicate optional module not found
      return std::string();
    }

    // Create a detailed error message with context for package.json resolution
    std::string errorMsg = "Module not found: '" + moduleName + "'";
    errorMsg += "\n  Base directory: " + baseDir;
    errorMsg += "\n  Attempted final paths:";
    errorMsg += "\n    - " + std::string([fullPath UTF8String]);

    throw NativeScriptException(isolate, errorMsg);
  }

  return [fullPath UTF8String];
}

std::string ModuleInternal::ResolvePathFromPackageJson(const std::string& packageJson,
                                                       bool& error) {
  NSString* packageJsonStr = [NSString stringWithUTF8String:packageJson.c_str()];

  NSFileManager* fileManager = [NSFileManager defaultManager];
  BOOL isDirectory;
  BOOL exists = [fileManager fileExistsAtPath:packageJsonStr isDirectory:&isDirectory];
  if (exists == NO || isDirectory == YES) {
    return std::string();
  }

  NSData* data = [NSData dataWithContentsOfFile:packageJsonStr];
  if (data == nil) {
    return std::string();
  }

  NSDictionary* dic = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
  if (dic == nil) {
    error = true;
    return std::string();
  }

  NSString* main = [dic objectForKey:@"main"];
  if (main == nil) {
    return std::string();
  }

  NSString* path = [[[packageJsonStr stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:main] stringByStandardizingPath];
  exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];

  if (exists == YES && isDirectory == YES) {
    packageJsonStr = [path stringByAppendingPathComponent:@"package.json"];
    exists = [fileManager fileExistsAtPath:packageJsonStr isDirectory:&isDirectory];
    if (exists == YES && isDirectory == NO) {
      return this->ResolvePathFromPackageJson([packageJsonStr UTF8String], error);
    }
  }

  return [path UTF8String];
}

Local<Object> ModuleInternal::CreatePlaceholderModule(Isolate* isolate,
                                                      const std::string& moduleName,
                                                      const std::string& cacheKey) {
  Local<Context> context = isolate->GetCurrentContext();

  // Create a module object with exports that throws when accessed
  Local<Object> moduleObj = Object::New(isolate);

  // Create a Proxy that throws an error when any property is accessed
  std::string errorMessage =
      "Module '" + moduleName + "' is not available. This is an optional module.";
  std::string proxyCode = "(function() {"
                          "  const error = new Error('" +
                          errorMessage +
                          "');"
                          "  return new Proxy({}, {"
                          "    get: function(target, prop) {"
                          "      throw error;"
                          "    },"
                          "    set: function(target, prop, value) {"
                          "      throw error;"
                          "    },"
                          "    has: function(target, prop) {"
                          "      return false;"
                          "    },"
                          "    ownKeys: function(target) {"
                          "      return [];"
                          "    },"
                          "    getPrototypeOf: function(target) {"
                          "      return null;"
                          "    }"
                          "  });"
                          "})()";

  Local<Script> proxyScript;
  if (Script::Compile(context, tns::ToV8String(isolate, proxyCode.c_str())).ToLocal(&proxyScript)) {
    Local<Value> proxyObject;
    if (proxyScript->Run(context).ToLocal(&proxyObject)) {
      // Set the exports to the proxy object
      bool success = moduleObj->Set(context, tns::ToV8String(isolate, "exports"), proxyObject)
                         .FromMaybe(false);
      tns::Assert(success, isolate);
    }
  }

  // Set up the module object
  bool success = moduleObj
                     ->Set(context, tns::ToV8String(isolate, "id"),
                           tns::ToV8String(isolate, moduleName.c_str()))
                     .FromMaybe(false);
  tns::Assert(success, isolate);

  success =
      moduleObj->Set(context, tns::ToV8String(isolate, "loaded"), v8::Boolean::New(isolate, true))
          .FromMaybe(false);
  tns::Assert(success, isolate);

  // Cache the placeholder module
  this->loadedModules_[cacheKey] = std::make_shared<Persistent<Object>>(isolate, moduleObj);

  return moduleObj;
}

ScriptCompiler::CachedData* ModuleInternal::LoadScriptCache(const std::string& path) {
  if (RuntimeConfig.IsDebug) {
    return nullptr;
  }

  long length = 0;
  std::string cachePath = ModuleInternal::GetCacheFileName(path + ".cache");

  struct stat result;
  if (stat(cachePath.c_str(), &result) == 0) {
    auto cacheLastModifiedTime = result.st_mtime;
    if (stat(path.c_str(), &result) == 0) {
      auto jsLastModifiedTime = result.st_mtime;
      if (jsLastModifiedTime != cacheLastModifiedTime) {
        // files have different dates, ignore the cache file (this is enforced by the
        // SaveScriptCache function)
        return nullptr;
      }
    }
  }

  bool isNew = false;
  uint8_t* data = tns::ReadBinary(cachePath, length, isNew);
  if (!data) {
    return nullptr;
  }

  return new ScriptCompiler::CachedData(
      data, (int)length,
      isNew ? ScriptCompiler::CachedData::BufferOwned : ScriptCompiler::CachedData::BufferNotOwned);
}

void ModuleInternal::SaveScriptCache(const ScriptCompiler::CachedData* cache,
                                     const std::string& path) {
  std::string cachePath = ModuleInternal::GetCacheFileName(path + ".cache");

  // std::ofstream ofs(cachePath, std::ios::binary);
  // if (!ofs) return;  // or throw

  // ofs.write(reinterpret_cast<const char*>(cache->data),
  //           cache->length);
  // ofs.close();

  int length = cache->length;
  tns::WriteBinary(cachePath, cache->data, length);
  delete cache;

  // make sure cache and js file have the same modification date
  struct stat result;
  struct utimbuf new_times;
  new_times.actime = time(nullptr);
  new_times.modtime = time(nullptr);
  if (stat(path.c_str(), &result) == 0) {
    auto jsLastModifiedTime = result.st_mtime;
    new_times.modtime = jsLastModifiedTime;
  }
  utime(cachePath.c_str(), &new_times);
}

void ModuleInternal::SaveScriptCache(const Local<Script> script, const std::string& path) {
  if (RuntimeConfig.IsDebug) {
    return;
  }

  Local<UnboundScript> unboundScript = script->GetUnboundScript();
  // CachedData returned by this function should be owned by the caller (v8 docs)
  ScriptCompiler::CachedData* cachedData = ScriptCompiler::CreateCodeCache(unboundScript);

  int length = cachedData->length;
  std::string cachePath = ModuleInternal::GetCacheFileName(path + ".cache");
  tns::WriteBinary(cachePath, cachedData->data, length);
  delete cachedData;

  // make sure cache and js file have the same modification date
  struct stat result;
  struct utimbuf new_times;
  new_times.actime = time(nullptr);
  new_times.modtime = time(nullptr);
  if (stat(path.c_str(), &result) == 0) {
    auto jsLastModifiedTime = result.st_mtime;
    new_times.modtime = jsLastModifiedTime;
  }
  utime(cachePath.c_str(), &new_times);
}

std::string ModuleInternal::GetCacheFileName(const std::string& path) {
  std::string key = path.substr(RuntimeConfig.ApplicationPath.size() + 1);
  std::replace(key.begin(), key.end(), '/', '-');

  NSArray* paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString* cachesPath = [paths objectAtIndex:0];
  NSString* result =
      [cachesPath stringByAppendingPathComponent:[NSString stringWithUTF8String:key.c_str()]];

  return [result UTF8String];
}

}  // namespace tns
