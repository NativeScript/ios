#include "ModuleInternal.h"
#include <Foundation/Foundation.h>
#include <sys/stat.h>
#include <time.h>
#include <utime.h>
#include <string>
#include "Caches.h"
#include "Helpers.h"
#include "NativeScriptException.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

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
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
  Local<Object> globalObject = context->Global();
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

  try {
    ModuleInternal* moduleInternal =
        static_cast<ModuleInternal*>(info.Data().As<External>()->Value());

    std::string moduleName = tns::ToString(isolate, info[0].As<v8::String>());
    std::string callingModuleDirName = tns::ToString(isolate, info[1].As<v8::String>());

    NSString* fullPath;
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
            [[fullPath stringByAppendingPathExtension:@"js"] fileSystemRepresentation];

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
    ex.ReThrowToV8(isolate);
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
  std::string path = this->ResolvePath(isolate, baseDir, moduleName);
  if (path.empty()) {
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

  if ([extension isEqualToString:@"js"]) {
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

  Local<Script> script = LoadScript(isolate, modulePath);

  Local<v8::Function> moduleFunc;
  {
    TryCatch tc(isolate);
    moduleFunc = script->Run(context).ToLocalChecked().As<v8::Function>();
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

Local<Script> ModuleInternal::LoadScript(Isolate* isolate, const std::string& path) {
  Local<Context> context = isolate->GetCurrentContext();
  std::string baseOrigin = tns::ReplaceAll(path, RuntimeConfig.BaseDir, "");
  std::string fullRequiredModulePathWithSchema = "file://" + baseOrigin;
  ScriptOrigin origin(isolate, tns::ToV8String(isolate, fullRequiredModulePathWithSchema));
  Local<v8::String> scriptText = WrapModuleContent(isolate, path);
  ScriptCompiler::CachedData* cacheData = LoadScriptCache(path);
  ScriptCompiler::Source source(scriptText, origin, cacheData);

  ScriptCompiler::CompileOptions options = ScriptCompiler::kNoCompileOptions;

  if (cacheData != nullptr) {
    options = ScriptCompiler::kConsumeCodeCache;
  }

  Local<Script> script;
  TryCatch tc(isolate);
  bool success = ScriptCompiler::Compile(context, &source, options).ToLocal(&script);
  if (!success || tc.HasCaught()) {
    throw NativeScriptException(isolate, tc, "Cannot compile " + path);
  }

  if (cacheData == nullptr) {
    SaveScriptCache(script, path);
  }

  return script;
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

Local<v8::String> ModuleInternal::WrapModuleContent(Isolate* isolate, const std::string& path) {
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
    NSString* jsFile = [fullPath stringByAppendingPathExtension:@"js"];
    BOOL isDir;
    if ([fileManager fileExistsAtPath:jsFile isDirectory:&isDir] && isDir == NO) {
      return [jsFile UTF8String];
    }
  }

  if (exists == NO) {
    fullPath = [fullPath stringByAppendingPathExtension:@"js"];
    exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
  }

  if (exists == NO) {
    throw NativeScriptException("The specified module does not exist: " + moduleName);
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
    fullPath = [fullPath stringByAppendingPathExtension:@"js"];
  } else {
    fullPath = [fullPath stringByAppendingPathComponent:@"index.js"];
  }

  exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
  if (exists == NO) {
    throw NativeScriptException("The specified module does not exist: " + moduleName);
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

ScriptCompiler::CachedData* ModuleInternal::LoadScriptCache(const std::string& path) {
  if (RuntimeConfig.IsDebug) {
    return nullptr;
  }

  long length = 0;
  std::string cachePath = GetCacheFileName(path + ".cache");

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

void ModuleInternal::SaveScriptCache(const Local<Script> script, const std::string& path) {
  if (RuntimeConfig.IsDebug) {
    return;
  }

  Local<UnboundScript> unboundScript = script->GetUnboundScript();
  // CachedData returned by this function should be owned by the caller (v8 docs)
  ScriptCompiler::CachedData* cachedData = ScriptCompiler::CreateCodeCache(unboundScript);

  int length = cachedData->length;
  std::string cachePath = GetCacheFileName(path + ".cache");
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
