#include "ModuleInternal.h"
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>
#include <string>
#include "Caches.h"
#include "Helpers.h"
#include "ModuleInternalCallbacks.h"  // for ResolveModuleCallback
#include "NativeScriptException.h"
#include "DevFlags.h"
#include "Runtime.h"  // for GetAppConfigValue
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

// External flag from Runtime.mm to track JavaScript errors
extern bool jsErrorOccurred;

// Helper function to check if a module name looks like an optional external module
bool IsLikelyOptionalModule(const std::string& moduleName) {
  // Check if it's a bare module name (no path separators) that could be an npm package
  if (moduleName.find('/') == std::string::npos && moduleName.find('\\') == std::string::npos &&
      moduleName[0] != '.' && moduleName[0] != '~' && moduleName[0] != '/') {
    return true;
  }
  return false;
}

// Helper function to check if a file path is an ES module (.mjs) but not a source map (.mjs.map)
bool IsESModule(const std::string& path) {
  return path.size() >= 4 && path.compare(path.size() - 4, 4, ".mjs") == 0 &&
         !(path.size() >= 8 && path.compare(path.size() - 8, 8, ".mjs.map") == 0);
}

// Normalize file system paths to a canonical representation so lookups in
// g_moduleRegistry remain consistent regardless of how the path was provided.
static std::string NormalizePath(const std::string& path) {
  if (path.empty()) {
    return path;
  }

  NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
  if (nsPath == nil) {
    return path;
  }

  NSString* standardized = [nsPath stringByStandardizingPath];
  if (standardized == nil) {
    return path;
  }

  return std::string([standardized UTF8String]);
}

// Helper function to resolve main entry from package.json with proper extension handling
std::string ResolveMainEntryFromPackageJson(const std::string& baseDir) {
  // Get the main value from package.json
  id mainValue = Runtime::GetAppConfigValue("main");
  NSString* mainEntry = nil;

  if (mainValue && [mainValue isKindOfClass:[NSString class]]) {
    mainEntry = (NSString*)mainValue;
  } else {
    // Fallback to "index" if no main field found
    mainEntry = @"index";
  }

  // Try the main entry with different extensions
  NSString* basePath =
      [[NSString stringWithUTF8String:baseDir.c_str()] stringByAppendingPathComponent:mainEntry];

  // Check if file exists as-is
  if (tns::Exists([basePath fileSystemRepresentation])) {
    return std::string([basePath UTF8String]);
  }
  // Try with .js extension
  else if (tns::Exists(
               [[basePath stringByAppendingPathExtension:@"js"] fileSystemRepresentation])) {
    return std::string([[basePath stringByAppendingPathExtension:@"js"] UTF8String]);
  }
  // Try with .mjs extension
  else if (tns::Exists(
               [[basePath stringByAppendingPathExtension:@"mjs"] fileSystemRepresentation])) {
    return std::string([[basePath stringByAppendingPathExtension:@"mjs"] UTF8String]);
  } else {
    // If none found, default to .js (let the loading system handle the error)
    return std::string([[basePath stringByAppendingPathExtension:@"js"] UTF8String]);
  }
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
    Log(@"FATAL: Failed to compile require factory script");
    return;
  }

  Local<Value> result;
  if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
    tns::LogError(isolate, tc);
    Log(@"FATAL: Failed to run require factory script");
    return;
  }
  if (result.IsEmpty() || !result->IsFunction()) {
    Log(@"FATAL: Require factory script did not return a function");
    return;
  }

  this->requireFactoryFunction_ =
      std::make_unique<Persistent<v8::Function>>(isolate, result.As<v8::Function>());

  Local<FunctionTemplate> requireFuncTemplate =
      FunctionTemplate::New(isolate, RequireCallback, External::New(isolate, this));
  this->requireFunction_ = std::make_unique<Persistent<v8::Function>>(
      isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

  // Use shortened path for global require function to avoid V8 parsing issues
  std::string globalRequirePath = "/app";

  Local<v8::Function> globalRequire = GetRequireFunction(isolate, globalRequirePath);
  bool success =
      global->Set(context, tns::ToV8String(isolate, "require"), globalRequire).FromMaybe(false);
  if (!success) {
    Log(@"FATAL: Failed to set global require function");
  }

}

bool ModuleInternal::RunModule(Isolate* isolate, std::string path) {
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
      if (!setDir) {
        Log(@"Warning: Failed to set __dirname on global object");
      }
    }
  }

  // ES module fast path
  if (IsESModule(path)) {
    TryCatch tc(isolate);
    Local<Value> moduleNamespace;
    try {
      moduleNamespace = ModuleInternal::LoadESModule(isolate, path);
    } catch (const NativeScriptException& ex) {
      if (RuntimeConfig.IsDebug) {
        Log(@"***** JavaScript exception occurred - detailed stack trace follows *****");
        Log(@"Error loading ES module: %s", path.c_str());
        Log(@"Exception: %s", ex.getMessage().c_str());
        Log(@"***** End stack trace - continuing execution *****");
        Log(@"Debug mode - ES module loading failed, but telling iOS it succeeded to prevent app termination");
        return true;  // avoid termination in debug
      } else {
        return false;
      }
    }
    if (moduleNamespace.IsEmpty()) {
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - ES module returned empty namespace, but telling iOS it succeeded");
        return true;
      } else {
        return false;
      }
    }
    return true;  // success
  }

  // CommonJS / classic path
  Local<Value> requireObj;
  bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
  if (!success || !requireObj->IsFunction()) {
    Log(@"Warning: Failed to get require function from global object");
    return false;
  }
  Local<v8::Function> requireFunc = requireObj.As<v8::Function>();
  Local<Value> args[] = {ToV8String(isolate, path)};
  Local<Value> result;

  // Add TryCatch to handle any exceptions from the require call
  TryCatch tc(isolate);
  success = requireFunc->Call(context, globalObject, 1, args).ToLocal(&result);

  if (!success || tc.HasCaught()) {
    if (RuntimeConfig.IsDebug) {
      Log(@"***** JavaScript exception occurred - detailed stack trace follows *****");
      Log(@"Error in require() call:");
      Log(@"  Requested module: '%s'", path.c_str());
      Log(@"  Called from: %s", RuntimeConfig.ApplicationPath.c_str());

      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }

      Log(@"***** End stack trace - continuing execution *****");
      Log(@"Debug mode - Main script execution failed, but telling iOS it succeeded to prevent "
          @"app termination");

      // Add a small delay to ensure error modal has time to render before we return
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            Log(@"🛡️ Debug mode - Crash prevention complete, app should remain stable");
          });

      return true;  // LIE TO iOS - return success to prevent app termination
    } else {
      // In release mode, still fail as before
      return false;
    }
  }

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

  TryCatch tc(isolate);
  bool success = requireFuncFactory->Call(context, thiz, 2, args).ToLocal(&result);
  if (!success || tc.HasCaught()) {
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }
    Log(@"FATAL: Failed to call require factory function");
    // Return a dummy function to avoid further crashes
    result = v8::Function::New(context, [](const v8::FunctionCallbackInfo<v8::Value>& info) {
               if (RuntimeConfig.IsDebug) {
                 Log(@"Debug mode - Require function unavailable (factory failed)");
                 info.GetReturnValue().SetUndefined();
               } else {
                 info.GetIsolate()->ThrowException(v8::Exception::Error(
                     tns::ToV8String(info.GetIsolate(), "Require function unavailable")));
               }
             }).ToLocalChecked();
  }

  if (result.IsEmpty() || !result->IsFunction()) {
    Log(@"FATAL: Require factory did not return a function");
    // Return a dummy function
    result = v8::Function::New(context, [](const v8::FunctionCallbackInfo<v8::Value>& info) {
               if (RuntimeConfig.IsDebug) {
                 Log(@"Debug mode - Require function unavailable (no function returned)");
                 info.GetReturnValue().SetUndefined();
               } else {
                 info.GetIsolate()->ThrowException(v8::Exception::Error(
                     tns::ToV8String(info.GetIsolate(), "Require function unavailable")));
               }
             }).ToLocalChecked();
  }

  return result.As<v8::Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  // Declare these outside try block so they're available in catch
  std::string moduleName;
  std::string callingModuleDirName;
  NSString* fullPath = nil;

  try {
    // Guard: URL-based modules must be loaded via dynamic import() in dev HTTP ESM mode.
    if (info.Length() > 0 && info[0]->IsString()) {
      v8::String::Utf8Value s(isolate, info[0]);
      if (*s) {
        moduleName.assign(*s, s.length());
        if (moduleName.rfind("http://", 0) == 0 || moduleName.rfind("https://", 0) == 0) {
          std::string msg = std::string("NativeScript: require() of URL module is not supported: ") + moduleName + ". Use dynamic import() instead.";
          throw NativeScriptException(msg.c_str());
        }
      }
    }
    ModuleInternal* moduleInternal =
        static_cast<ModuleInternal*>(info.Data().As<External>()->Value());

    moduleName = tns::ToString(isolate, info[0].As<v8::String>());
    callingModuleDirName = tns::ToString(isolate, info[1].As<v8::String>());

    // Expand shortened paths back to full paths for file resolution
    if (callingModuleDirName.length() > 0 && callingModuleDirName.substr(0, 4) == "/app") {
      std::string expandedPath = RuntimeConfig.ApplicationPath + callingModuleDirName.substr(4);
      callingModuleDirName = expandedPath;
    }

    // Special handling for "./" - resolve to main entry point from package.json
    if (moduleName == "./") {
      std::string mainEntryPath = ResolveMainEntryFromPackageJson(RuntimeConfig.ApplicationPath);
      fullPath = [NSString stringWithUTF8String:mainEntryPath.c_str()];
    } else if (moduleName.length() > 0 && moduleName[0] != '/') {
      if (moduleName[0] == '.') {
        NSString* callingDirNS = [NSString stringWithUTF8String:callingModuleDirName.c_str()];
        NSString* moduleNameNS = [NSString stringWithUTF8String:moduleName.c_str()];
        fullPath =
            [[callingDirNS stringByAppendingPathComponent:moduleNameNS] stringByStandardizingPath];
      } else if (moduleName[0] == '~') {
        moduleName = moduleName.substr(2);
        fullPath = [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];
      } else {
        // Default: resolve in tns_modules (shared folder override removed)
        NSString* tnsModulesPath =
            [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
                stringByAppendingPathComponent:@"tns_modules"];
        fullPath = [tnsModulesPath
            stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];

        const char* path1 = [fullPath fileSystemRepresentation];
        const char* path2 =
            [[fullPath stringByAppendingPathExtension:@"js"] fileSystemRepresentation];
        const char* path3 =
            [[fullPath stringByAppendingPathExtension:@"mjs"] fileSystemRepresentation];

        if (!tns::Exists(path1) && !tns::Exists(path2) && !tns::Exists(path3)) {
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
      // moduleObj is guaranteed to be non-empty here due to check above
      info.GetReturnValue().Set(moduleObj);
    } else {
      Local<Context> context = isolate->GetCurrentContext();
      Local<Value> exportsObj;
      bool success =
          moduleObj->Get(context, tns::ToV8String(isolate, "exports")).ToLocal(&exportsObj);
      if (success) {
        info.GetReturnValue().Set(exportsObj);
      } else {
        Log(@"Warning: Failed to get exports from module object");
      }
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

    NativeScriptException contextEx(isolate, contextMsg, "Error");
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

    throw NativeScriptException(isolate, contextMsg, "Error");
  }

  if (path.empty()) {
    // For absolute paths (where baseDir is "/"), always throw an error instead of creating
    // placeholder
    bool isAbsolutePath = (baseDir == "/");

    // Create placeholder module only for likely optional modules that aren't absolute paths
    if (!isAbsolutePath && IsLikelyOptionalModule(moduleName)) {
      return this->CreatePlaceholderModule(isolate, moduleName, cacheKey);
    }

    // For absolute paths or non-optional modules, throw an error
    std::string errorMsg = "Module not found: '" + moduleName + "'";
    if (isAbsolutePath) {
      errorMsg = "Cannot find module '" + baseDir + moduleName + "'";
    }
    throw NativeScriptException(isolate, errorMsg, "Error");
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

  if ([extension isEqualToString:@"mjs"] || [extension isEqualToString:@"js"]) {
    moduleObj = this->LoadModule(isolate, path, cacheKey);
  } else if ([extension isEqualToString:@"json"]) {
    moduleObj = this->LoadData(isolate, path);
  } else {
    // Throw an error for unsupported file extension instead of crashing
    std::string errorMsg = "Unsupported file extension: " + std::string([extension UTF8String]);
    throw NativeScriptException(errorMsg);
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
  if (!success) {
    Log(@"Warning: Failed to set exports property on module object");
  }

  const PropertyAttribute readOnlyFlags =
      static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);

  Local<v8::String> fileName = tns::ToV8String(isolate, modulePath);
  success =
      moduleObj->DefineOwnProperty(context, tns::ToV8String(isolate, "id"), fileName, readOnlyFlags)
          .FromMaybe(false);
  if (!success) {
    Log(@"Warning: Failed to set id property on module object");
  }

  std::shared_ptr<Persistent<Object>> poModuleObj =
      std::make_shared<Persistent<Object>>(isolate, moduleObj);
  TempModule tempModule(this, modulePath, cacheKey, poModuleObj);

  // Compile/load the JavaScript/ESM source
  Local<Value> scriptValue = LoadScript(isolate, modulePath);

  // Check if script loading failed (debug mode graceful returns)
  if (scriptValue.IsEmpty()) {
    if (RuntimeConfig.IsDebug) {
      // NSLog(@"Debug mode - Script loading returned empty value, returning gracefully: %s",
      //       modulePath.c_str());
      return Local<Object>();
    } else {
      throw NativeScriptException(isolate, "Script loading failed for " + modulePath);
    }
  }

  // Check if this is an ES module
  bool isESM = IsESModule(modulePath);
  std::shared_ptr<Caches> cache = Caches::Get(isolate);

  if (isESM) {
    // For ES modules, the returned value is the namespace object

    // First check if scriptValue is empty (from debug mode graceful returns)
    if (scriptValue.IsEmpty()) {
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - ES module returned empty value, returning gracefully: %s",
            modulePath.c_str());
        return Local<Object>();
      } else {
        throw NativeScriptException(isolate, "ES module load returned empty value " + modulePath);
      }
    }

    if (!scriptValue->IsObject()) {
      if (RuntimeConfig.IsDebug) {
        Log(@"Debug mode - ES module load failed, returning gracefully: %s", modulePath.c_str());
        // Return empty module object to prevent crashes
        return Local<Object>();
      } else {
        throw NativeScriptException(isolate, "Failed to load ES module " + modulePath);
      }
    }

    // Debug: Check if we're in a worker context and if self.onmessage is set
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    if (cache->isWorker) {
      Local<Context> context = isolate->GetCurrentContext();
      Local<Object> global = context->Global();

      // Check if self exists
      Local<Value> selfValue;
      if (global->Get(context, ToV8String(isolate, "self")).ToLocal(&selfValue)) {
        if (selfValue->IsObject()) {
          Local<Object> selfObj = selfValue.As<Object>();
          Local<Value> onmessageValue;
          if (selfObj->Get(context, ToV8String(isolate, "onmessage")).ToLocal(&onmessageValue)) {
            // onmessage exists
          }
        }
      }
    }

    // Handle exports differently for ES modules vs worker scripts
    if (isESM) {
      exportsObj = scriptValue.As<Object>();
    } else {
      // For worker scripts, create an empty exports object since they don't export anything
      // They work through global scope (self.onmessage, etc.)
      exportsObj = Object::New(isolate);
    }

    bool succ =
        moduleObj->Set(context, tns::ToV8String(isolate, "exports"), exportsObj).FromMaybe(false);
    if (!succ) {
      Log(@"Warning: Failed to set exports property after module execution");
    }

    tempModule.SaveToCache();
    return moduleObj;
  }

  // Check if this is the main application bundle (webpack-style IIFE)
  std::string appPath = RuntimeConfig.ApplicationPath;
  std::string bundlePath = appPath + "/bundle.js";

  if (modulePath == bundlePath) {
    // Main application bundle is a webpack-style IIFE that executes immediately
    // It doesn't return a function, so we just create an empty exports object
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

  // Shorten the parentDir for GetRequireFunction to avoid V8 parsing issues with long paths
  std::string shortParentDir = "/app" + parentDir.substr(RuntimeConfig.ApplicationPath.length());

  Local<v8::Function> require = GetRequireFunction(isolate, shortParentDir);
  // Use full paths for __filename and __dirname to match module.id
  Local<Value> requireArgs[5]{moduleObj, exportsObj, require,
                              tns::ToV8String(isolate, modulePath.c_str()),
                              tns::ToV8String(isolate, parentDir.c_str())};

  success = moduleObj->Set(context, tns::ToV8String(isolate, "require"), require).FromMaybe(false);
  if (!success) {
    Log(@"Warning: Failed to set require property on module object");
  }

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
  std::string canonicalPath = NormalizePath(path);

  if (IsESModule(canonicalPath)) {
    // Treat all .mjs files as standard ES modules.
    return ModuleInternal::LoadESModule(isolate, canonicalPath);
  }

  Local<Script> script = ModuleInternal::LoadClassicScript(isolate, canonicalPath);

  // Check if script compilation failed (debug mode graceful returns)
  if (script.IsEmpty()) {
    if (RuntimeConfig.IsDebug) {
      Log(@"Debug mode - Classic script compilation returned empty, returning gracefully: %s",
          canonicalPath.c_str());
      return Local<Value>();
    } else {
      throw NativeScriptException(isolate, "Classic script compilation failed for " + canonicalPath);
    }
  }

  // run it and return the value with proper exception handling
  Local<Context> context = isolate->GetCurrentContext();
  TryCatch tc(isolate);
  Local<Value> result;

  if (!script->Run(context).ToLocal(&result)) {
    // Script execution failed, throw a proper exception instead of aborting V8
    if (RuntimeConfig.IsDebug) {
      // Mark that a JavaScript error occurred
      jsErrorOccurred = true;

      // Log the detailed JavaScript error with full stack trace
      Log(@"***** JavaScript exception occurred - detailed stack trace follows *****");
      Log(@"Error executing script: %s", canonicalPath.c_str());
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }
      Log(@"***** End stack trace - continuing execution *****");
      Log(@"Debug mode - Script execution failed, returning gracefully: %s", path.c_str());

      std::string errorTitle = "Uncaught JavaScript Exception";
      std::string errorMessage = "Error executing script.";

      // Extract error message for modal when available
      if (tc.HasCaught()) {
        Local<Value> exception = tc.Exception();
        if (!exception.IsEmpty()) {
          Local<Context> ctx = isolate->GetCurrentContext();
          Local<v8::String> excStr;
          if (exception->ToString(ctx).ToLocal(&excStr)) {
            std::string excMsg = tns::ToString(isolate, excStr);
            if (!excMsg.empty()) {
              errorMessage = excMsg;
            }
          }
        }
      }

      std::string stackTrace = tns::GetSmartStackTrace(isolate, &tc, tc.Exception());

      NativeScriptException::ShowErrorModal(isolate, errorTitle, errorMessage, stackTrace);
      return Local<Value>();
    } else {
      if (tc.HasCaught()) {
        throw NativeScriptException(isolate, tc, "Cannot execute script " + canonicalPath);
      } else {
        throw NativeScriptException(isolate, "Script execution failed for " + canonicalPath);
      }
    }
  }

  return result;
}

Local<Script> ModuleInternal::LoadClassicScript(Isolate* isolate, const std::string& path) {
  std::string canonicalPath = NormalizePath(path);

  // Ensure the resolved path maps to an actual regular file before attempting
  // to read/compile it.  This prevents `ReadModule` from aborting the process
  // when given a directory or non-existent path.
  struct stat st;
  if (stat(canonicalPath.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
    throw NativeScriptException("Cannot find module " + canonicalPath);
  }

  auto context = isolate->GetCurrentContext();
  // build URL
  std::string base = ReplaceAll(canonicalPath, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;

  // wrap & cache lookup
  Local<v8::String> sourceText = ModuleInternal::WrapModuleContent(isolate, canonicalPath);
  auto* cacheData = ModuleInternal::LoadScriptCache(canonicalPath);

  // note: is_module=false here
  Local<v8::String> urlString;
  if (!v8::String::NewFromUtf8(isolate, url.c_str(), NewStringType::kNormal).ToLocal(&urlString)) {
    throw NativeScriptException(isolate, "Failed to create URL string for script " + canonicalPath);
  }

  ScriptOrigin origin(isolate, urlString,
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
    if (RuntimeConfig.IsDebug) {
      // Mark that a JavaScript error occurred
      jsErrorOccurred = true;

      // Log the detailed JavaScript error with full stack trace
      Log(@"***** JavaScript exception occurred - detailed stack trace follows *****");
      Log(@"Error compiling classic script: %s", canonicalPath.c_str());
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }
      Log(@"***** End stack trace - continuing execution *****");
      Log(@"Debug mode - Script compilation failed, returning gracefully: %s", canonicalPath.c_str());
      // Return empty script to prevent crashes
      return Local<Script>();
    } else {
      throw NativeScriptException(isolate, tc, "Cannot compile script " + canonicalPath);
    }
  }

  if (cacheData == nullptr) {
    ModuleInternal::SaveScriptCache(script, canonicalPath);
  }

  return script;
}

Local<Value> ModuleInternal::LoadESModule(Isolate* isolate, const std::string& path) {
  std::string canonicalPath = NormalizePath(path);
  auto context = isolate->GetCurrentContext();

  // 1) Prepare URL & source
  std::string base = ReplaceAll(canonicalPath, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;
  v8::Local<v8::String> sourceText = ModuleInternal::WrapModuleContent(isolate, canonicalPath);
  auto* cacheData = ModuleInternal::LoadScriptCache(canonicalPath);

  Local<v8::String> urlString;
  if (!v8::String::NewFromUtf8(isolate, url.c_str(), NewStringType::kNormal).ToLocal(&urlString)) {
    throw NativeScriptException(isolate, "Failed to create URL string for ES module " + canonicalPath);
  }

  ScriptOrigin origin(isolate, urlString, 0, 0, false, -1, Local<Value>(), false, false,
                      true  // ← is_module
  );
  ScriptCompiler::Source source(sourceText, origin, cacheData);

  // 2) Compile with its own TryCatch
  // Phase diagnostics helper (local lambda) – only active in debug builds when logScriptLoading is enabled
  auto logPhase = [&](const char* phase, const char* status, const char* classification = "", const char* extra = "") {
    if (RuntimeConfig.IsDebug && IsScriptLoadingLogEnabled()) {
      if (classification && classification[0] != '\0') {
        if (extra && extra[0] != '\0') {
          Log(@"[esm][%s][%s][%s] %s %s", phase, status, classification, canonicalPath.c_str(), extra);
        } else {
          Log(@"[esm][%s][%s][%s] %s", phase, status, classification, canonicalPath.c_str());
        }
      } else {
        if (extra && extra[0] != '\0') {
          Log(@"[esm][%s][%s] %s %s", phase, status, canonicalPath.c_str(), extra);
        } else {
          Log(@"[esm][%s][%s] %s", phase, status, canonicalPath.c_str());
        }
      }
    }
  };
  logPhase("compile", "begin");
  Local<Module> module;
  {
    TryCatch tcCompile(isolate);
    MaybeLocal<Module> maybeMod = ScriptCompiler::CompileModule(
        isolate, &source,
        cacheData ? ScriptCompiler::kConsumeCodeCache : ScriptCompiler::kNoCompileOptions);

    if (!maybeMod.ToLocal(&module)) {
      // Attempt classification heuristics
      const char* classification = "unknown";
      if (tcCompile.HasCaught()) {
        Local<Message> msg = tcCompile.Message();
        if (!msg.IsEmpty()) {
          v8::String::Utf8Value w(isolate, msg->Get());
          if (*w) {
            std::string m(*w);
            if (m.find("Unexpected token") != std::string::npos || m.find("SyntaxError") != std::string::npos) classification = "syntax";
            else if (m.find("Cannot use import statement outside a module") != std::string::npos) classification = "not-a-module";
          }
        }
      }
      logPhase("compile", "fail", classification);
      // V8 threw a syntax error or similar
      if (RuntimeConfig.IsDebug) {
        // Log the detailed JavaScript error with full stack trace
        Log(@"***** JavaScript exception occurred *****");
        Log(@"Error compiling ES module: %s", canonicalPath.c_str());
        if (tcCompile.HasCaught()) {
          tns::LogError(isolate, tcCompile);
        }
        Log(@"***** Debug mode - continuing execution *****");
        Log(@"ES module compilation failed: %s", canonicalPath.c_str());
        // Return empty to prevent crashes
        return Local<Value>();
      } else {
        throw NativeScriptException(isolate, tcCompile, "Cannot compile ES module " + canonicalPath);
      }
    }
  }
  logPhase("compile", "ok");

  // 3) Register for resolution callback
  extern std::unordered_map<std::string, Global<Module>> g_moduleRegistry;

  // Safe Global handle management: Clear any existing entry first
  auto it = g_moduleRegistry.find(canonicalPath);
  if (it != g_moduleRegistry.end()) {
    // Clear the existing Global handle before replacing it
    it->second.Reset();
  }

  // Now safely set the new module handle
  g_moduleRegistry[canonicalPath].Reset(isolate, module);

  // 4) Save cache if first time
  if (cacheData == nullptr) {
    Local<UnboundModuleScript> unbound = module->GetUnboundModuleScript();
    auto* generatedCache = ScriptCompiler::CreateCodeCache(unbound);
    ModuleInternal::SaveScriptCache(generatedCache, canonicalPath);
  }

  // 5) Instantiate (link) with its own TryCatch
  logPhase("instantiate", "begin");
  {
    TryCatch tcLink(isolate);
    bool linked = module->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false);

    if (!linked) {
      RemoveModuleFromRegistry(canonicalPath);
      const char* classification = "unknown";
      if (tcLink.HasCaught()) {
        Local<Message> msg = tcLink.Message();
        if (!msg.IsEmpty()) {
          v8::String::Utf8Value w(isolate, msg->Get());
          if (*w) {
            std::string m(*w);
            if (m.find("Cannot find module") != std::string::npos || m.find("failed to resolve module specifier") != std::string::npos) classification = "resolve";
            else if (m.find("does not provide an export named") != std::string::npos) classification = "link-export";
          }
        }
      }
      logPhase("instantiate", "fail", classification);
      if (RuntimeConfig.IsDebug) {
        // Log the detailed JavaScript error with full stack trace
        Log(@"***** JavaScript exception occurred *****");
  Log(@"Error instantiating module: %s", canonicalPath.c_str());
        if (tcLink.HasCaught()) {
          tns::LogError(isolate, tcLink);
        }
        Log(@"***** Debug mode - continuing execution *****");
        Log(@"Module instantiation failed: %s", canonicalPath.c_str());
        return Local<Value>();
      } else {
        if (tcLink.HasCaught()) {
          throw NativeScriptException(isolate, tcLink, "Cannot instantiate module " + canonicalPath);
        } else {
          // V8 gave no exception object—throw plain text
          throw NativeScriptException(isolate, "Cannot instantiate module " + canonicalPath);
        }
      }
    }
  }
  logPhase("instantiate", "ok");

  // 6) Evaluate with its own TryCatch
  logPhase("evaluate", "begin");
  Local<Value> result;
  {
    TryCatch tcEval(isolate);
    // Keep existing debug print minimal; phase logger already outputs
    if (!module->Evaluate(context).ToLocal(&result)) {
      RemoveModuleFromRegistry(canonicalPath);
      const char* classification = "unknown";
      if (tcEval.HasCaught()) {
        Local<Message> msg = tcEval.Message();
        if (!msg.IsEmpty()) {
          v8::String::Utf8Value w(isolate, msg->Get());
          if (*w) {
            std::string m(*w);
            if (m.find("is not defined") != std::string::npos) classification = "reference";
            else if (m.find("TypeError") != std::string::npos) classification = "type";
            else if (m.find("Cannot read properties") != std::string::npos) classification = "type-nullish";
          }
        }
      }
      logPhase("evaluate", "fail", classification);
      if (RuntimeConfig.IsDebug) {
        // Log the detailed JavaScript error with full stack trace
        Log(@"***** JavaScript exception occurred *****");
        Log(@"Error evaluating ES module: %s", canonicalPath.c_str());
        if (tcEval.HasCaught()) {
          tns::LogError(isolate, tcEval);
        }
        Log(@"***** Debug mode - continuing execution *****");
        Log(@"Module evaluation failed: %s", canonicalPath.c_str());
        return Local<Value>();
      } else {
        throw NativeScriptException(isolate, tcEval, "Cannot evaluate module " + canonicalPath);
      }
    }
    logPhase("evaluate", "ok");

    // Handle the case where evaluation returns a Promise (for top-level await)
    // Only perform microtask processing & detailed diagnostics in debug builds.
    if (RuntimeConfig.IsDebug && result->IsPromise()) {
      logPhase("evaluate", "promise");
      TryCatch promiseTc(isolate);
      Local<Promise> promise = result.As<Promise>();
      // Limited attempts to resolve quickly while in debug mode
      int maxAttempts = 100;
      int attempts = 0;
      while (attempts < maxAttempts && !promiseTc.HasCaught()) {
        isolate->PerformMicrotaskCheckpoint();
        if (promiseTc.HasCaught()) {
          break;
        }
        Promise::PromiseState state = promise->State();
        if (state != Promise::kPending) {
          if (state == Promise::kRejected) {
            RemoveModuleFromRegistry(canonicalPath);
            logPhase("evaluate", "promise-rejected");
            // In debug mode, show modal and continue without throwing
            jsErrorOccurred = true;
            Local<Value> reason = promise->Result();
            std::string errorMessage = "Module evaluation promise rejected";
            std::string stackTrace = "";
            if (!reason.IsEmpty()) {
              if (reason->IsObject()) {
                Local<Context> context = isolate->GetCurrentContext();
                Local<Object> errorObj = reason.As<Object>();
                auto messageKey = tns::ToV8String(isolate, "message");
                Local<Value> messageVal;
                if (errorObj->Get(context, messageKey).ToLocal(&messageVal) && messageVal->IsString()) {
                  v8::String::Utf8Value messageUtf8(isolate, messageVal);
                  if (*messageUtf8) errorMessage = std::string(*messageUtf8);
                }
                auto stackKey = tns::ToV8String(isolate, "stack");
                Local<Value> stackVal;
                if (errorObj->Get(context, stackKey).ToLocal(&stackVal) && stackVal->IsString()) {
                  v8::String::Utf8Value stackUtf8(isolate, stackVal);
                  if (*stackUtf8) {
                    stackTrace = std::string(*stackUtf8);
                    stackTrace = ReplaceAll(stackTrace, RuntimeConfig.BaseDir, "");
                  }
                }

                // Log the extracted error information
                Log(@"NativeScript encountered a fatal error: %s", errorMessage.c_str());
                // Reverted: do not remap before logging/displaying
                if (!stackTrace.empty()) {
                  Log(@"JavaScript stack trace:\n%s", stackTrace.c_str());
                }
              }

              // Also check if TryCatch caught anything
              if (promiseTc.HasCaught()) {
                tns::LogError(isolate, promiseTc);
              }

              Log(@"***** End stack trace - Fix to continue *****");

              // Ensure we have a stack for the modal
              if (stackTrace.empty()) {
                stackTrace = tns::GetSmartStackTrace(isolate);
              } else {
                stackTrace = tns::RemapStackTraceIfAvailable(isolate, stackTrace);
              }

              NativeScriptException::ShowErrorModal(isolate, errorTitle, errorMessage, stackTrace);

              // In debug mode, don't throw any exceptions - just return empty value
              return Local<Value>();
            } else {
              // Release mode - throw exceptions as before
              if (!promiseTc.HasCaught()) {
                Local<Value> reason = promise->Result();
                isolate->ThrowException(reason);
              }
              throw NativeScriptException(isolate, promiseTc, "Module evaluation promise rejected");
            }
            if (IsScriptLoadingLogEnabled()) {
              // Emit a concise summary of the rejection for diagnostics
              std::string stackPreview = stackTrace.size() > 240 ? stackTrace.substr(0, 240) + "…" : stackTrace;
              Log(@"[esm][evaluate][promise-rejected:detail] path=%s message=%s stack=%s",
                  canonicalPath.c_str(), errorMessage.c_str(), stackPreview.c_str());
            }
            NativeScriptException::ShowErrorModal("Uncaught JavaScript Exception", errorMessage, stackTrace);
            logPhase("evaluate", "promise-rejected-handled");
            return Local<Value>();
          }
          break;
        }
        attempts++;
        usleep(100);
      }
      // Timeout: continue; the host event loop will settle microtasks later
    }
  }

  tns::UpdateModuleFallback(isolate, canonicalPath, module);

  // 7) Return the namespace
  return module->GetModuleNamespace();
}

MaybeLocal<Value> ModuleInternal::RunScriptString(Isolate* isolate, Local<Context> context,
                                                  const std::string scriptString) {
  ScriptCompiler::CompileOptions options = ScriptCompiler::kNoCompileOptions;
  ScriptCompiler::Source source(tns::ToV8String(isolate, scriptString));
  TryCatch tc(isolate);

  // Handle script compilation safely
  Local<Script> script;
  if (!ScriptCompiler::Compile(context, &source, options).ToLocal(&script)) {
    // Compilation failed - return empty MaybeLocal to indicate failure
    return MaybeLocal<Value>();
  }

  MaybeLocal<Value> result = script->Run(context);
  return result;
}

void ModuleInternal::RunScript(Isolate* isolate, std::string script) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
  Local<Object> globalObject = context->Global();
  Local<Value> requireObj;
  bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
  if (!success || !requireObj->IsFunction()) {
    Log(@"Warning: Failed to get require function from global object in RunScript");
    return;
  }
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

  // Check if we're in a worker context
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  bool isWorkerContext = cache && cache->isWorker;

  // Check if this is an .mjs file but NOT a .mjs.map file
  if (IsESModule(path)) {
    // Read raw text without wrapping.
    std::string sourceText = tns::ReadText(path);

    // For ES modules in worker context, we need to provide access to global objects
    // since ES modules run in their own scope
    if (isWorkerContext) {
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

  // Check if this is the main application bundle (webpack-style IIFE)
  // Main bundles typically end with "bundle.js" and are in the app root
  std::string appPath = RuntimeConfig.ApplicationPath;
  std::string bundlePath = appPath + "/bundle.js";

  if (path == bundlePath) {
    // Main application bundle should not be wrapped in CommonJS factory
    // as it's typically a webpack-style IIFE that executes immediately
    std::string sourceText = tns::ReadText(path);
    return tns::ToV8String(isolate, sourceText);
  }

  // Worker .js files should use CommonJS wrapping like regular .js files
  // This ensures proper runtime context and global object setup

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

  // If the exact path exists as a file (not directory), return it immediately
  if (exists == YES && isDirectory == NO) {
    return [fullPath UTF8String];
  }

  // Priority 1: Check for file with .js extension
  NSString* originalFullPath = fullPath;
  NSString* jsPath = [fullPath stringByAppendingPathExtension:@"js"];
  if ([fileManager fileExistsAtPath:jsPath isDirectory:&isDirectory] && isDirectory == NO) {
    return [jsPath UTF8String];
  }

  // Priority 2: Check for file with .mjs extension
  NSString* mjsPath = [originalFullPath stringByAppendingPathExtension:@"mjs"];
  if ([fileManager fileExistsAtPath:mjsPath isDirectory:&isDirectory] && isDirectory == NO) {
    return [mjsPath UTF8String];
  }

  // Priority 3: Only now check if it exists as a directory
  if (exists == YES && isDirectory == YES) {
    // For directories, check package.json first (Node.js always validates package.json if present)
    NSString* packageJson = [fullPath stringByAppendingPathComponent:@"package.json"];
    if ([fileManager fileExistsAtPath:packageJson]) {
      bool error = false;
      std::string entry = this->ResolvePathFromPackageJson([packageJson UTF8String], error);
      if (error) {
        throw NativeScriptException(
            isolate, "Unable to locate main entry in " + std::string([packageJson UTF8String]),
            "Error");
      }

      if (!entry.empty()) {
        return entry;
      }
    }

    // Fall back to index.js first, then index.mjs
    NSString* indexJsPath = [fullPath stringByAppendingPathComponent:@"index.js"];
    BOOL indexIsDir;
    if ([fileManager fileExistsAtPath:indexJsPath isDirectory:&indexIsDir] && indexIsDir == NO) {
      return [indexJsPath UTF8String];
    }

    NSString* indexMjsPath = [fullPath stringByAppendingPathComponent:@"index.mjs"];
    if ([fileManager fileExistsAtPath:indexMjsPath isDirectory:&indexIsDir] && indexIsDir == NO) {
      return [indexMjsPath UTF8String];
    }
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
        "\n    - " + std::string([[originalPath stringByAppendingPathExtension:@"js"] UTF8String]);
    errorMsg +=
        "\n    - " + std::string([[originalPath stringByAppendingPathExtension:@"mjs"] UTF8String]);

    throw NativeScriptException(isolate, errorMsg, "Error");
  }

  if (isDirectory == NO) {
    return [fullPath UTF8String];
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
    main = @"index";  // Fallback to "index" if no main field found
  }

  NSString* baseDir = [packageJsonStr stringByDeletingLastPathComponent];
  NSString* basePath = [[baseDir stringByAppendingPathComponent:main] stringByStandardizingPath];

  // Check if file exists as-is (but only if it's a file, not directory)
  BOOL isFile;
  if ([fileManager fileExistsAtPath:basePath isDirectory:&isFile] && isFile == NO) {
    return std::string([basePath UTF8String]);
  }
  // Try with .js extension
  else if ([fileManager fileExistsAtPath:[basePath stringByAppendingPathExtension:@"js"]
                             isDirectory:&isFile] &&
           isFile == NO) {
    NSString* jsPath = [basePath stringByAppendingPathExtension:@"js"];
    return std::string([jsPath UTF8String]);
  }
  // Try with .mjs extension
  else if ([fileManager fileExistsAtPath:[basePath stringByAppendingPathExtension:@"mjs"]
                             isDirectory:&isFile] &&
           isFile == NO) {
    NSString* mjsPath = [basePath stringByAppendingPathExtension:@"mjs"];
    return std::string([mjsPath UTF8String]);
  }

  // Check if it's a directory and recurse
  exists = [fileManager fileExistsAtPath:basePath isDirectory:&isDirectory];

  if (exists == YES && isDirectory == YES) {
    // First check for nested package.json
    packageJsonStr = [basePath stringByAppendingPathComponent:@"package.json"];
    exists = [fileManager fileExistsAtPath:packageJsonStr isDirectory:&isDirectory];
    if (exists == YES && isDirectory == NO) {
      return this->ResolvePathFromPackageJson([packageJsonStr UTF8String], error);
    }

    // If no package.json, fall back to index.js then index.mjs
    NSString* indexJsPath = [basePath stringByAppendingPathComponent:@"index.js"];

    if (tns::Exists([indexJsPath fileSystemRepresentation])) {
      return std::string([indexJsPath UTF8String]);
    }

    NSString* indexMjsPath = [basePath stringByAppendingPathComponent:@"index.mjs"];

    if (tns::Exists([indexMjsPath fileSystemRepresentation])) {
      return std::string([indexMjsPath UTF8String]);
    }
  }

  // If none found, default to .js (let the loading system handle the error)
  return std::string([[basePath stringByAppendingPathExtension:@"js"] UTF8String]);
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
      if (!success) {
        Log(@"Warning: Failed to set exports property on proxy module object");
      }
    }
  }

  // Set up the module object
  bool success = moduleObj
                     ->Set(context, tns::ToV8String(isolate, "id"),
                           tns::ToV8String(isolate, moduleName.c_str()))
                     .FromMaybe(false);
  if (!success) {
    Log(@"Warning: Failed to set id property on module object");
  }

  success =
      moduleObj->Set(context, tns::ToV8String(isolate, "loaded"), v8::Boolean::New(isolate, true))
          .FromMaybe(false);
  if (!success) {
    Log(@"Warning: Failed to set loaded property on module object");
  }

  // Cache the placeholder module
  this->loadedModules_[cacheKey] = std::make_shared<Persistent<Object>>(isolate, moduleObj);

  return moduleObj;
}

ScriptCompiler::CachedData* ModuleInternal::LoadScriptCache(const std::string& path) {
  std::string canonicalPath = NormalizePath(path);
  if (RuntimeConfig.IsDebug) {
    return nullptr;
  }

  long length = 0;
  std::string cachePath = ModuleInternal::GetCacheFileName(canonicalPath + ".cache");

  struct stat result;
  if (stat(cachePath.c_str(), &result) == 0) {
    auto cacheLastModifiedTime = result.st_mtime;
    if (stat(canonicalPath.c_str(), &result) == 0) {
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
  std::string canonicalPath = NormalizePath(path);
  std::string cachePath = ModuleInternal::GetCacheFileName(canonicalPath + ".cache");

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
  if (stat(canonicalPath.c_str(), &result) == 0) {
    auto jsLastModifiedTime = result.st_mtime;
    new_times.modtime = jsLastModifiedTime;
  }
  utime(cachePath.c_str(), &new_times);
}

void ModuleInternal::SaveScriptCache(const Local<Script> script, const std::string& path) {
  if (RuntimeConfig.IsDebug) {
    return;
  }

  std::string canonicalPath = NormalizePath(path);

  Local<UnboundScript> unboundScript = script->GetUnboundScript();
  // CachedData returned by this function should be owned by the caller (v8 docs)
  ScriptCompiler::CachedData* cachedData = ScriptCompiler::CreateCodeCache(unboundScript);

  int length = cachedData->length;
  std::string cachePath = ModuleInternal::GetCacheFileName(canonicalPath + ".cache");
  tns::WriteBinary(cachePath, cachedData->data, length);
  delete cachedData;

  // make sure cache and js file have the same modification date
  struct stat result;
  struct utimbuf new_times;
  new_times.actime = time(nullptr);
  new_times.modtime = time(nullptr);
  if (stat(canonicalPath.c_str(), &result) == 0) {
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
