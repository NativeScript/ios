#include "ModuleInternal.h"
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>
#include <cstring>
#include <string>
#include "BuiltinLoader.h"
#include "Caches.h"
#include "Helpers.h"
#include "HttpLoader.h"
#include "ModuleInternalCallbacks.h"  // for ResolveModuleCallback
#include "NativeScriptException.h"
#include "napi/NapiModules.h"
#include "NsBuiltinModules.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

// Helper function to check if a file path is an ES module (.mjs) but not a source map (.mjs.map)
bool IsESModule(const std::string& path) {
  return path.size() >= 4 && path.compare(path.size() - 4, 4, ".mjs") == 0 &&
         !(path.size() >= 8 && path.compare(path.size() - 8, 8, ".mjs.map") == 0);
}

// A package-style specifier: neither a path nor a scheme, so it may be claimed
// by a registry rather than resolved on disk.
static bool IsBareSpecifier(const std::string& specifier) {
  if (specifier.empty() || specifier[0] == '.' || specifier[0] == '/' ||
      specifier[0] == '~') {
    return false;
  }

  return specifier.find(':') == std::string::npos;
}

static std::string NormalizePath(const std::string& path);

// How an entry module's graph settles. For local modules the bound is a yield,
// not a timeout: only nestable V8 tasks can run while these JS frames are on
// the stack, so a TLA parked on a non-nestable foreground task can never settle
// in-pump — give it one short window, then return and let the real event loop
// finish it after the turn (the Node shape; EventLoopTests pins this). HTTP
// entries must settle in-pump — the dev client needs the rejection reason
// synchronously — so they get the full deadline and the runloop slices their
// transport needs.
static ModuleEvaluationOptions BootEntryEvaluationOptions(bool isHttpModule) {
  ModuleEvaluationOptions options;
  options.policy = ModuleEvaluationPolicy::kSyncPumping;
  options.deadlineSeconds = isHttpModule ? kModuleEvaluateDeadlineSeconds : 1.0;
  options.timeoutBehavior = isHttpModule ? ModuleEvaluationOptions::TimeoutBehavior::kThrow
                                         : ModuleEvaluationOptions::TimeoutBehavior::kReturnPending;
  options.pumpRunLoop = isHttpModule;
  return options;
}

// How a graph reached through require() settles. A pumping require must settle
// or throw — handing back a half-initialized namespace is what the strict
// policy exists to prevent — so it gets the full deadline. It never slices the
// Cocoa runloop: outside boot the loop belongs to the app, and re-entering
// arbitrary runloop sources from the middle of a require would run UI callbacks
// underneath JS frames.
static ModuleEvaluationOptions RequireEvaluationOptions(ModuleEvaluationPolicy policy) {
  ModuleEvaluationOptions options;
  options.policy = policy;
  if (policy == ModuleEvaluationPolicy::kSyncPumping) {
    options.deadlineSeconds = kModuleEvaluateDeadlineSeconds;
    options.timeoutBehavior = ModuleEvaluationOptions::TimeoutBehavior::kThrow;
    options.pumpRunLoop = false;
  }
  return options;
}

static inline bool StartsWith(const std::string& value, const char* prefix) {
  size_t n = strlen(prefix);
  return value.size() >= n && value.compare(0, n, prefix) == 0;
}

static std::string NormalizeHttpModuleUrl(const std::string& path) {
  if (path.empty()) {
    return path;
  }

  std::string normalized = path;
  if (StartsWith(normalized, "file://http://") || StartsWith(normalized, "file://https://")) {
    normalized = normalized.substr(strlen("file://"));
  }

  if (normalized.rfind("http:/", 0) == 0 && normalized.rfind("http://", 0) != 0) {
    normalized.insert(5, "/");
  } else if (normalized.rfind("https:/", 0) == 0 && normalized.rfind("https://", 0) != 0) {
    normalized.insert(6, "/");
  }

  return normalized;
}

static bool IsHttpModulePath(const std::string& path) {
  std::string normalized = NormalizeHttpModuleUrl(path);
  return StartsWith(normalized, "http://") || StartsWith(normalized, "https://");
}

static std::string CanonicalizeModulePath(const std::string& path) {
  if (IsHttpModulePath(path)) {
    return CanonicalizeHttpUrlKey(NormalizeHttpModuleUrl(path));
  }

  return NormalizePath(path);
}

// Normalize file system paths to a canonical representation so lookups in
// registry remain consistent regardless of how the path was provided.
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
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();
  TryCatch tc(isolate);
  Local<Value> result;
  if (!BuiltinLoader::RunBuiltin(context, BuiltinId::kRequireFactory).ToLocal(&result)) {
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }
    Log(@"FATAL: Failed to run require factory script");
    return;
  }
  if (result.IsEmpty() || !result->IsFunction()) {
    Log(@"FATAL: Require factory script did not return a function");
    return;
  }

  this->requireFactoryFunction_ =
      std::make_unique<Persistent<v8::Function>>(isolate, result.As<v8::Function>());

  Local<FunctionTemplate> requireFuncTemplate = FunctionTemplate::New(
      isolate, RequireCallback, External::New(isolate, this, v8::kExternalPointerTypeTagDefault));
  this->requireFunction_ = std::make_unique<Persistent<v8::Function>>(
      isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

  // Use shortened path for global require function to avoid V8 parsing issues
  std::string globalRequirePath = "/app";

  Local<v8::Function> globalRequire = GetRequireFunction(
      isolate, globalRequirePath, RequireEvaluationOptions(ModuleEvaluationPolicy::kSyncStrict));
  bool success =
      global->Set(context, tns::ToV8String(isolate, "require"), globalRequire).FromMaybe(false);
  if (!success) {
    Log(@"FATAL: Failed to set global require function");
  }
}

void ModuleInternal::RunModule(Isolate* isolate, std::string path) {
  // Entry evaluation is this thread's boot window: while it is active, the
  // yield inside synchronous HTTP fetches may pump the runloop (nothing else
  // owns it yet). Balanced on every exit path.
  struct BootEvalScope {
    BootEvalScope() { SetBootEvaluationActive(true); }
    ~BootEvalScope() { SetBootEvaluationActive(false); }
  } bootEvalScope;

  // The app entry arrives as "./"; resolve it before deciding how to run it so
  // an ES module entry takes the module path instead of being require()d. A
  // required entry would evaluate under the strict policy, which refuses a
  // top-level-await graph outright — so this is what makes `import`/`export`,
  // and a TLA entry, legal in an app's main module. Resolved with the same
  // function the boot backstop's probe uses, so the evaluated module and the
  // probe agree on the registry key. A CommonJS entry keeps "./" and the
  // global-require route it has always taken.
  if (path == "./") {
    std::string mainEntry = ResolveMainEntryFromPackageJson(RuntimeConfig.ApplicationPath);
    if (IsESModule(mainEntry) || IsHttpModulePath(mainEntry)) {
      path = mainEntry;
    }
  }

  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
  // The ES module branch compiles and links against isolate->GetCurrentContext(),
  // and a caller that enters the isolate through a fresh Isolate::Scope
  // (RunMainScript) has no current context: the one Runtime::Init entered was
  // popped with Init's own scope. The require branch never needed this because
  // Function::Call enters the context it is handed.
  Context::Scope context_scope(context);
  Local<Object> globalObject = context->Global();
  bool isHttpModule = IsHttpModulePath(path);
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
  if (IsESModule(path) || isHttpModule) {
    Local<Value> moduleNamespace;
    if (isHttpModule) {
      TNS_DEBUG(Esm, "run-module http-esm begin %s", NormalizeHttpModuleUrl(path).c_str());
    }
    try {
      // The entry runs before this thread's event loop does, so its graph can
      // only make progress from the pump inside LoadESModule.
      moduleNamespace =
          ModuleInternal::LoadESModule(isolate, path, BootEntryEvaluationOptions(isHttpModule));
    } catch (const NativeScriptException& ex) {
      if (RuntimeConfig.IsDebug) {
        Log(@"***** JavaScript exception occurred *****");
        Log(@"Error loading ES module: %s", path.c_str());
        Log(@"Exception: %s", ex.getMessage().c_str());
      }
      throw;
    }
    if (moduleNamespace.IsEmpty()) {
      // `LoadESModule` returned an empty value without throwing. Provide a
      // directional hint; this is the only case with no actual reason text.
      throw NativeScriptException(
          std::string("ES module returned empty namespace for ") + path +
          " — likely a top-level await that never settled; check the device "
          "console for the matching [esm][evaluate][promise-timeout] entry.");
    }
    if (isHttpModule) {
      TNS_DEBUG(Esm, "run-module http-esm ok %s", NormalizeHttpModuleUrl(path).c_str());
    }
    return;
  }

  // For CommonJS modules (.js), use the traditional require() approach
  Local<Value> requireObj;
  bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
  if (!success || !requireObj->IsFunction()) {
    throw NativeScriptException("require function unavailable on globalThis");
  }
  Local<v8::Function> requireFunc = requireObj.As<v8::Function>();
  Local<Value> args[] = {ToV8String(isolate, path)};
  Local<Value> result;

  TryCatch tc(isolate);
  success = requireFunc->Call(context, globalObject, 1, args).ToLocal(&result);

  if (!success || tc.HasCaught()) {
    if (RuntimeConfig.IsDebug) {
      Log(@"***** JavaScript exception occurred *****");
      Log(@"Error in require() call:");
      Log(@"  Requested module: '%s'", path.c_str());
      Log(@"  Called from: %s", RuntimeConfig.ApplicationPath.c_str());
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }
    }
    // The TryCatch form captures the V8 exception, so a worker boundary can
    // re-arm it on the isolate (ReThrowToV8) and route it to worker.onerror.
    if (tc.HasCaught()) {
      throw NativeScriptException(isolate, tc, std::string("require() failed for module ") + path);
    }
    throw NativeScriptException(std::string("require() failed for module ") + path);
  }
}

void ModuleInternal::CreateRequireCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1 || !info[0]->IsString()) {
    isolate->ThrowException(Exception::TypeError(
        tns::ToV8String(isolate, "createRequire expects a base directory string")));
    return;
  }

  Runtime* runtime = Runtime::GetRuntime(isolate);
  ModuleInternal* moduleInternal = runtime != nullptr ? runtime->GetModuleInternal() : nullptr;
  if (moduleInternal == nullptr) {
    isolate->ThrowException(Exception::Error(tns::ToV8String(
        isolate, "createRequire is unavailable: this isolate has no module loader")));
    return;
  }

  std::string dirName = tns::ToString(isolate, info[0].As<v8::String>());
  const bool pumping = info.Length() > 1 && info[1]->BooleanValue(isolate);
  ModuleEvaluationOptions options = RequireEvaluationOptions(
      pumping ? ModuleEvaluationPolicy::kSyncPumping : ModuleEvaluationPolicy::kSyncStrict);

  // ns-module.js has already validated these and passes undefined for anything
  // the caller left out, so each present value simply overrides its default.
  if (info.Length() > 2 && info[2]->IsNumber()) {
    options.deadlineSeconds = info[2].As<v8::Number>()->Value();
  }
  if (info.Length() > 3 && info[3]->IsBoolean()) {
    options.timeoutBehavior = info[3]->BooleanValue(isolate)
                                  ? ModuleEvaluationOptions::TimeoutBehavior::kThrow
                                  : ModuleEvaluationOptions::TimeoutBehavior::kReturnPending;
  }
  if (info.Length() > 4 && info[4]->IsBoolean()) {
    options.pumpRunLoop = info[4]->BooleanValue(isolate);
  }

  info.GetReturnValue().Set(moduleInternal->GetRequireFunction(isolate, dirName, options));
}

bool ModuleInternal::InstallCreateRequireBinding(Local<Context> context, Local<Object> binding) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> fn;
  if (!v8::Function::New(context, ModuleInternal::CreateRequireCallback).ToLocal(&fn)) {
    return false;
  }
  fn->SetName(tns::ToV8String(isolate, "createRequire"));
  return binding->CreateDataProperty(context, tns::ToV8String(isolate, "createRequire"), fn)
      .FromMaybe(false);
}

Local<v8::Function> ModuleInternal::GetRequireFunction(Isolate* isolate, const std::string& dirName,
                                                       const ModuleEvaluationOptions& options) {
  Local<v8::Function> requireFuncFactory = requireFactoryFunction_->Get(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  Local<v8::Function> requireInternalFunc = this->requireFunction_->Get(isolate);
  Local<Value> args[6]{
      requireInternalFunc,
      tns::ToV8String(isolate, dirName.c_str()),
      Integer::New(isolate, static_cast<int>(options.policy)),
      v8::Number::New(isolate, options.deadlineSeconds),
      v8::Boolean::New(isolate,
                       options.timeoutBehavior == ModuleEvaluationOptions::TimeoutBehavior::kThrow),
      v8::Boolean::New(isolate, options.pumpRunLoop)};

  Local<Value> result;
  Local<Object> thiz = Object::New(isolate);

  TryCatch tc(isolate);
  bool success = requireFuncFactory->Call(context, thiz, 6, args).ToLocal(&result);
  if (!success || tc.HasCaught()) {
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }
    Log(@"FATAL: Failed to call require factory function");
    // A require that cannot exist must throw when called, in every build.
    result = v8::Function::New(context, [](const v8::FunctionCallbackInfo<v8::Value>& info) {
               info.GetIsolate()->ThrowException(v8::Exception::Error(
                   tns::ToV8String(info.GetIsolate(), "Require function unavailable")));
             }).ToLocalChecked();
  }

  if (result.IsEmpty() || !result->IsFunction()) {
    Log(@"FATAL: Require factory did not return a function");
    result = v8::Function::New(context, [](const v8::FunctionCallbackInfo<v8::Value>& info) {
               info.GetIsolate()->ThrowException(v8::Exception::Error(
                   tns::ToV8String(info.GetIsolate(), "Require function unavailable")));
             }).ToLocalChecked();
  }

  return result.As<v8::Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  // Builtin modules resolve before any path handling, so they can never be
  // shadowed by a file or a package, and an unknown one fails as a missing
  // builtin rather than as a missing file. Only prefixed specifiers get here:
  // a bare `util` still resolves through npm.
  if (info.Length() > 0 && info[0]->IsString()) {
    std::string specifier = tns::ToString(isolate, info[0].As<v8::String>());
    if (NsBuiltinModules::IsBuiltinScheme(specifier)) {
      Local<Context> context = isolate->GetCurrentContext();
      Local<Object> exports;
      if (NsBuiltinModules::GetExports(context, specifier).ToLocal(&exports)) {
        info.GetReturnValue().Set(exports);
      } else if (!NsBuiltinModules::IsRegistered(specifier)) {
        isolate->ThrowException(Exception::Error(
            tns::ToV8String(isolate, NsBuiltinModules::NotFoundMessage(specifier))));
      }
      return;
    }

    // Node-API addons claim a bare name only, so a path can never be diverted
    // into the addon registry, and builtins keep priority over both.
    if (IsBareSpecifier(specifier) && NapiModules::IsRegistered(specifier)) {
      Local<Context> context = isolate->GetCurrentContext();
      Local<Object> exports;
      if (NapiModules::GetExports(context, specifier).ToLocal(&exports)) {
        info.GetReturnValue().Set(exports);
      }
      return;
    }
  }

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
          std::string msg =
              std::string("NativeScript: require() of URL module is not supported: ") + moduleName +
              ". Use dynamic import() instead.";
          throw NativeScriptException(msg.c_str());
        }
      }
    }
    ModuleInternal* moduleInternal = static_cast<ModuleInternal*>(
        info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));

    moduleName = tns::ToString(isolate, info[0].As<v8::String>());
    callingModuleDirName = tns::ToString(isolate, info[1].As<v8::String>());
    // The require factory forwards the options its require was minted with;
    // an absent policy is the strict default every ordinary require uses.
    ModuleEvaluationPolicy policy = ModuleEvaluationPolicy::kSyncStrict;
    if (info.Length() > 2 && info[2]->IsInt32() &&
        info[2].As<Int32>()->Value() == static_cast<int>(ModuleEvaluationPolicy::kSyncPumping)) {
      policy = ModuleEvaluationPolicy::kSyncPumping;
    }
    ModuleEvaluationOptions evaluationOptions = RequireEvaluationOptions(policy);
    if (info.Length() > 3 && info[3]->IsNumber()) {
      evaluationOptions.deadlineSeconds = info[3].As<v8::Number>()->Value();
    }
    if (info.Length() > 4 && info[4]->IsBoolean()) {
      evaluationOptions.timeoutBehavior =
          info[4]->BooleanValue(isolate) ? ModuleEvaluationOptions::TimeoutBehavior::kThrow
                                         : ModuleEvaluationOptions::TimeoutBehavior::kReturnPending;
    }
    if (info.Length() > 5 && info[5]->IsBoolean()) {
      evaluationOptions.pumpRunLoop = info[5]->BooleanValue(isolate);
    }

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
        // `~` is the app-root alias, so what follows it is a path relative to
        // the app root whether or not the caller wrote the separator.
        std::string relative = moduleName.substr(1);
        size_t firstSegment = relative.find_first_not_of('/');
        relative =
            firstSegment == std::string::npos ? std::string() : relative.substr(firstSegment);
        fullPath = [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:relative.c_str()]];
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
    Local<Object> moduleObj = moduleInternal->LoadImpl(
        isolate, [fileNameOnly UTF8String], [pathOnly UTF8String], isData, evaluationOptions);

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
                                       const std::string& baseDir, bool& isData,
                                       const ModuleEvaluationOptions& options) {
  size_t lastIndex = moduleName.find_last_of(".");
  std::string moduleNameWithoutExtension =
      (lastIndex == std::string::npos) ? moduleName : moduleName.substr(0, lastIndex);
  std::string cacheKey = baseDir + "*" + moduleNameWithoutExtension;
  auto it = this->loadedModules_.find(cacheKey);

  if (it != this->loadedModules_.end()) {
    return it->second->Get(isolate);
  }

  Local<Object> moduleObj;
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
    throw NativeScriptException(isolate, "Cannot find module '" + moduleName + "'", "Error");
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
    moduleObj = this->LoadModule(isolate, path, cacheKey, options);
  } else if ([extension isEqualToString:@"json"]) {
    moduleObj = this->LoadData(isolate, path);
  } else {
    // Throw an error for unsupported file extension instead of crashing
    std::string errorMsg = "Unsupported file extension: " + std::string([extension UTF8String]);
    throw NativeScriptException(errorMsg);
  }

  return moduleObj;
}

static bool NamespaceHasOwn(Isolate* isolate, Local<Context> context, Local<Object> ns,
                            const char* name) {
  return ns->HasOwnProperty(context, tns::ToV8String(isolate, name)).FromMaybe(false);
}

// The live compiled module behind a registry key, or empty.
static Local<Module> RegisteredModuleForPath(Isolate* isolate, const std::string& canonicalPath) {
  auto* registryPtr = ModuleRegistryFor(isolate);
  if (registryPtr == nullptr) {
    return Local<Module>();
  }
  auto it = registryPtr->find(canonicalPath);
  if (it == registryPtr->end()) {
    return Local<Module>();
  }
  return it->second.Get(isolate);
}

// What `require()` of an ES module hands back, per Node's
// populateCJSExportsFromESM: an explicit `module.exports` export wins outright;
// a namespace with no default export, or one that already declares
// __esModule, passes through untouched; everything else gets the facade so
// transpiled consumers reading `_mod.__esModule ? _mod.default : _mod` find the
// default. Export names are arbitrary strings, hence the own-property probes.
static Local<Value> RequireExportsForNamespace(Isolate* isolate, Local<Context> context,
                                               Local<Object> ns, const std::string& canonicalPath) {
  TryCatch tc(isolate);

  if (NamespaceHasOwn(isolate, context, ns, "module.exports")) {
    Local<Value> moduleExports;
    if (!ns->Get(context, tns::ToV8String(isolate, "module.exports")).ToLocal(&moduleExports)) {
      throw NativeScriptException(isolate, tc,
                                  "Cannot read the 'module.exports' export of " + canonicalPath);
    }
    return moduleExports;
  }

  bool hasDefault = NamespaceHasOwn(isolate, context, ns, "default");
  bool hasEsModuleMarker = NamespaceHasOwn(isolate, context, ns, "__esModule");
  if (!hasDefault || hasEsModuleMarker) {
    return ns;
  }

  Local<Module> target = RegisteredModuleForPath(isolate, canonicalPath);
  if (target.IsEmpty()) {
    // The load that produced this namespace registered the module under this
    // very key, so a miss means the registry and the namespace disagree —
    // returning the bare namespace would drop __esModule and misroute every
    // transpiled consumer downstream.
    throw NativeScriptException(
        "require() cannot build the exports facade for " + canonicalPath +
        ": the module evaluated but is absent from the registry under its canonical key");
  }

  Local<Module> facade;
  if (!GetOrCreateRequireFacade(isolate, context, target, canonicalPath).ToLocal(&facade)) {
    throw NativeScriptException("Cannot build the require() exports facade for " + canonicalPath);
  }
  return facade->GetModuleNamespace();
}

Local<Object> ModuleInternal::LoadModule(Isolate* isolate, const std::string& modulePath,
                                         const std::string& cacheKey,
                                         const ModuleEvaluationOptions& options) {
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
  Local<Value> scriptValue = LoadScript(isolate, modulePath, options);

  if (scriptValue.IsEmpty()) {
    throw NativeScriptException(isolate, "Script loading failed for " + modulePath);
  }

  // Check if this is an ES module
  bool isESM = IsESModule(modulePath);

  if (isESM) {
    // For ES modules, the returned value is the namespace object

    if (scriptValue.IsEmpty()) {
      throw NativeScriptException(isolate, "ES module load returned empty value " + modulePath);
    }

    if (!scriptValue->IsObject()) {
      throw NativeScriptException(isolate, "Failed to load ES module " + modulePath);
    }

    Local<Value> esmExports = RequireExportsForNamespace(isolate, context, scriptValue.As<Object>(),
                                                         CanonicalizeModulePath(modulePath));

    bool succ =
        moduleObj->Set(context, tns::ToV8String(isolate, "exports"), esmExports).FromMaybe(false);
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
  std::string shortParentDir;
  if (parentDir.length() >= RuntimeConfig.ApplicationPath.length() &&
      parentDir.compare(0, RuntimeConfig.ApplicationPath.length(), RuntimeConfig.ApplicationPath) ==
          0) {
    shortParentDir = "/app" + parentDir.substr(RuntimeConfig.ApplicationPath.length());
  } else {
    // Fallback: use the entire path if it doesn't start with ApplicationPath
    shortParentDir = parentDir;
  }

  // A module's own require inherits the options it was loaded under, so a
  // pumping require stays pumping — with the same deadline and timeout
  // behavior — all the way down its dependency tree.
  Local<v8::Function> require = GetRequireFunction(isolate, shortParentDir, options);
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

Local<Value> ModuleInternal::LoadScript(Isolate* isolate, const std::string& path,
                                        const ModuleEvaluationOptions& options) {
  std::string canonicalPath = NormalizePath(path);

  if (IsESModule(canonicalPath)) {
    // Treat all .mjs files as standard ES modules. require()'s default route
    // cannot wait: an async graph is refused rather than pumped.
    return ModuleInternal::LoadESModule(isolate, canonicalPath, options);
  }

  Local<Script> script = ModuleInternal::LoadClassicScript(isolate, canonicalPath);

  if (script.IsEmpty()) {
    throw NativeScriptException(isolate, "Classic script compilation failed for " + canonicalPath);
  }

  // run it and return the value with proper exception handling
  Local<Context> context = isolate->GetCurrentContext();
  TryCatch tc(isolate);
  Local<Value> result;

  if (!script->Run(context).ToLocal(&result)) {
    if (RuntimeConfig.IsDebug) {
      Log(@"***** JavaScript exception occurred *****");
      Log(@"Error executing script: %s", canonicalPath.c_str());
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }
    }
    if (tc.HasCaught()) {
      throw NativeScriptException(isolate, tc, "Cannot execute script " + canonicalPath);
    }
    throw NativeScriptException(isolate, "Script execution failed for " + canonicalPath);
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

  ScriptOrigin origin(urlString,
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
      Log(@"***** JavaScript exception occurred *****");
      Log(@"Error compiling classic script: %s", canonicalPath.c_str());
      if (tc.HasCaught()) {
        tns::LogError(isolate, tc);
      }
    }
    throw NativeScriptException(isolate, tc, "Cannot compile script " + canonicalPath);
  }

  if (cacheData == nullptr) {
    ModuleInternal::SaveScriptCache(script, canonicalPath);
  }

  return script;
}

MaybeLocal<Module> ModuleInternal::CompileFileEsModule(Isolate* isolate, const std::string& path) {
  std::string canonicalPath = NormalizePath(path);

  struct stat st;
  if (stat(canonicalPath.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
    throw NativeScriptException("Cannot find module " + canonicalPath);
  }

  std::string base = ReplaceAll(canonicalPath, RuntimeConfig.BaseDir, "");
  std::string url = "file://" + base;

  Local<v8::String> sourceText = ModuleInternal::WrapModuleContent(isolate, canonicalPath);
  auto* cacheData = ModuleInternal::LoadScriptCache(canonicalPath);

  Local<v8::String> urlString;
  if (!v8::String::NewFromUtf8(isolate, url.c_str(), NewStringType::kNormal).ToLocal(&urlString)) {
    throw NativeScriptException(isolate,
                                "Failed to create URL string for ES module " + canonicalPath);
  }

  ScriptOrigin origin(urlString, 0, 0, false, -1, Local<Value>(), false, false,
                      true  // ← is_module
  );
  ScriptCompiler::Source source(sourceText, origin, cacheData);

  Local<Module> module;
  MaybeLocal<Module> maybeMod = ScriptCompiler::CompileModule(
      isolate, &source,
      cacheData ? ScriptCompiler::kConsumeCodeCache : ScriptCompiler::kNoCompileOptions);
  if (!maybeMod.ToLocal(&module)) {
    return MaybeLocal<Module>();
  }

  if (cacheData == nullptr) {
    Local<UnboundModuleScript> unbound = module->GetUnboundModuleScript();
    auto* generatedCache = ScriptCompiler::CreateCodeCache(unbound);
    ModuleInternal::SaveScriptCache(generatedCache, canonicalPath);
  }

  return maybeMod;
}

// The shared probe behind both entry-evaluation queries: a registry hit plus
// Evaluate(), which hands back the SAME capability promise rather than
// re-running anything, so it is cheap enough to call from a pump loop.
static MaybeLocal<Promise> EntryEvaluationPromise(Isolate* isolate, const std::string& path) {
  if (!IsESModule(path) && !IsHttpModulePath(path)) {
    return MaybeLocal<Promise>();
  }
  auto* registryPtr = ModuleRegistryFor(isolate);
  if (registryPtr == nullptr) {
    return MaybeLocal<Promise>();
  }
  std::string canonicalPath = CanonicalizeModulePath(path);
  auto it = registryPtr->find(canonicalPath);
  if (it == registryPtr->end()) {
    return MaybeLocal<Promise>();
  }
  Local<Module> mod = it->second.Get(isolate);
  // A TLA-parked module reports kEvaluated while its promise is still
  // pending, so the status is the gate to *having* a promise, never to its
  // state.
  if (mod.IsEmpty() || mod->GetStatus() != Module::kEvaluated) {
    return MaybeLocal<Promise>();
  }
  TryCatch tc(isolate);
  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> result;
  if (!mod->Evaluate(context).ToLocal(&result) || !result->IsPromise()) {
    return MaybeLocal<Promise>();
  }
  return MaybeLocal<Promise>(result.As<Promise>());
}

MaybeLocal<Promise> ModuleInternal::PendingEntryEvaluation(Isolate* isolate,
                                                           const std::string& path) {
  Local<Promise> promise;
  if (!EntryEvaluationPromise(isolate, path).ToLocal(&promise)) {
    return MaybeLocal<Promise>();
  }
  if (promise->State() != Promise::kPending) {
    return MaybeLocal<Promise>();
  }
  return MaybeLocal<Promise>(promise);
}

EntryEvaluationState ModuleInternal::PollEntryEvaluation(Isolate* isolate, const std::string& path,
                                                         std::string* rejectionReason) {
  Local<Promise> promise;
  if (!EntryEvaluationPromise(isolate, path).ToLocal(&promise)) {
    return EntryEvaluationState::kNone;
  }
  switch (promise->State()) {
    case Promise::kPending:
      return EntryEvaluationState::kPending;
    case Promise::kFulfilled:
      return EntryEvaluationState::kFulfilled;
    case Promise::kRejected:
      break;
  }
  if (rejectionReason != nullptr) {
    Local<Value> reason = promise->Result();
    *rejectionReason = reason.IsEmpty() ? "<no reason>" : tns::ToString(isolate, reason);
  }
  return EntryEvaluationState::kRejected;
}

// Phase diagnostics for one module's trip through the loader.
static void LogEsmPhase(const std::string& canonicalPath, const char* phase, const char* status,
                        const char* classification = "", const char* extra = "") {
  if (classification && classification[0] != '\0') {
    if (extra && extra[0] != '\0') {
      TNS_DEBUG(Esm, "[%s][%s][%s] %s %s", phase, status, classification, canonicalPath.c_str(),
                extra);
    } else {
      TNS_DEBUG(Esm, "[%s][%s][%s] %s", phase, status, classification, canonicalPath.c_str());
    }
  } else {
    if (extra && extra[0] != '\0') {
      TNS_DEBUG(Esm, "[%s][%s] %s %s", phase, status, canonicalPath.c_str(), extra);
    } else {
      TNS_DEBUG(Esm, "[%s][%s] %s", phase, status, canonicalPath.c_str());
    }
  }
}

// `require()` cannot wait, so an async graph is refused rather than evaluated.
// Never evicts: the module is perfectly loadable through import().
[[noreturn]] static void ThrowAsyncGraphRefusal(const std::string& canonicalPath) {
  LogEsmPhase(canonicalPath, "evaluate", "refused", "async-graph");
  throw NativeScriptException("require() cannot load ES module '" + canonicalPath +
                              "': the module graph contains top-level await. Use import() or "
                              "createPumpingRequire from ns:module instead.");
}

// The pump advances the loop by running tasks and draining microtasks, and
// neither can happen re-entrantly: V8 ignores a microtask checkpoint while the
// isolate is already draining the queue, so a graph whose top-level await
// resumes through a promise reaction can never settle from here. Refused
// before evaluation, like the strict refusal, so the graph stays instantiated
// and import() can still load it.
[[noreturn]] static void ThrowMicrotaskPumpRefusal(const std::string& canonicalPath) {
  LogEsmPhase(canonicalPath, "evaluate", "refused", "microtask-context");
  throw NativeScriptException(
      "createPumpingRequire cannot settle module graph '" + canonicalPath +
      "' from inside a microtask (after an await or inside a promise callback): the event loop "
      "cannot be pumped re-entrantly. Call it from a task context, or use import().");
}

// Evicts the module and surfaces the rejection reason. Always throws — debug
// adds the modal and the detailed log, never recovery.
[[noreturn]] static void ThrowModuleEvaluationRejection(Isolate* isolate, Local<Promise> promise,
                                                        TryCatch& tc,
                                                        const std::string& canonicalPath) {
  RemoveModuleFromRegistry(isolate, canonicalPath);
  LogEsmPhase(canonicalPath, "evaluate", "promise-rejected");

  if (RuntimeConfig.IsDebug) {
    std::string errorTitle = "Uncaught JavaScript Exception";
    std::string errorMessage = "Module evaluation promise rejected";
    std::string stackTrace = "";

    Local<Value> reason = promise->Result();
    if (!reason.IsEmpty()) {
      Local<Context> context = isolate->GetCurrentContext();
      if (reason->IsObject()) {
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
      } else {
        auto maybeReasonStr = reason->ToString(context);
        if (!maybeReasonStr.IsEmpty()) {
          v8::String::Utf8Value reasonUtf8(isolate, maybeReasonStr.ToLocalChecked());
          if (*reasonUtf8) {
            errorMessage = std::string(*reasonUtf8);
          }
        }
      }

      Log(@"NativeScript encountered a fatal error: %s", errorMessage.c_str());
      if (!stackTrace.empty()) {
        Log(@"JavaScript stack trace:\n%s", stackTrace.c_str());
      }
    }

    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }

    Log(@"***** End stack trace - Fix to continue *****");

    if (stackTrace.empty()) {
      stackTrace = tns::GetSmartStackTrace(isolate);
    } else {
      stackTrace = tns::RemapStackTraceIfAvailable(isolate, stackTrace);
    }

    if (tns::LogCategoryEnabled(tns::LogCategory::Esm)) {
      std::string stackPreview =
          stackTrace.size() > 240 ? stackTrace.substr(0, 240) + "…" : stackTrace;
      TNS_DEBUG(Esm, "[evaluate][promise-rejected:detail] path=%s message=%s stack=%s",
                canonicalPath.c_str(), errorMessage.c_str(), stackPreview.c_str());
    }

    NativeScriptException::ShowErrorModal(isolate, errorTitle, errorMessage, stackTrace);
    LogEsmPhase(canonicalPath, "evaluate", "promise-rejected-handled");

    // The throw must carry the rejection detail so the boundary handlers
    // (RunMainScript, worker onerror, the dev client) see the reason; debug
    // adds the modal above, never recovery.
    std::string detail = std::string("Module evaluation promise rejected: ") + canonicalPath;
    if (!errorMessage.empty()) {
      detail += " — ";
      detail += errorMessage;
    }
    throw NativeScriptException(detail);
  }

  if (!tc.HasCaught()) {
    Local<Value> reason = promise->Result();
    isolate->ThrowException(reason);
  }
  throw NativeScriptException(isolate, tc, "Module evaluation promise rejected");
}

MaybeLocal<Promise> EvaluateModuleGraph(Isolate* isolate, Local<Context> context,
                                        Local<Module> module, const std::string& canonicalPath,
                                        const ModuleEvaluationOptions& options) {
  if (options.policy == ModuleEvaluationPolicy::kSyncStrict) {
    if (module->IsGraphAsync()) {
      // Refusing before evaluation leaves the graph at kInstantiated, so a
      // later import() can still evaluate it, and keeps this diagnosis ahead
      // of whatever runtime error the graph would have produced first.
      ThrowAsyncGraphRefusal(canonicalPath);
    }
    if (module->GetStatus() == Module::kEvaluating) {
      // Re-entered through a cycle while the graph is still on the stack; its
      // namespace holds whatever has been initialized so far.
      return MaybeLocal<Promise>();
    }
  }

  if (options.policy == ModuleEvaluationPolicy::kSyncPumping && module->IsGraphAsync() &&
      MicrotasksScope::IsRunningMicrotasks(isolate)) {
    // Only an async graph needs the pump; a synchronous one settles on its own
    // and stays legal from anywhere. Entry modules also arrive here, but from
    // native at task level, so they never trip this.
    ThrowMicrotaskPumpRefusal(canonicalPath);
  }

  LogEsmPhase(canonicalPath, "evaluate", "begin");
  TryCatch tcEval(isolate);
  Local<Value> result;
  if (!module->Evaluate(context).ToLocal(&result)) {
    RemoveModuleFromRegistry(isolate, canonicalPath);
    const char* classification = "unknown";
    if (tcEval.HasCaught()) {
      Local<Message> msg = tcEval.Message();
      if (!msg.IsEmpty()) {
        v8::String::Utf8Value w(isolate, msg->Get());
        if (*w) {
          std::string m(*w);
          if (m.find("is not defined") != std::string::npos)
            classification = "reference";
          else if (m.find("TypeError") != std::string::npos)
            classification = "type";
          else if (m.find("Cannot read properties") != std::string::npos)
            classification = "type-nullish";
        }
      }
    }
    LogEsmPhase(canonicalPath, "evaluate", "fail", classification);
    if (RuntimeConfig.IsDebug) {
      Log(@"***** JavaScript exception occurred *****");
      Log(@"Error evaluating ES module: %s", canonicalPath.c_str());
      if (tcEval.HasCaught()) {
        tns::LogError(isolate, tcEval);
      }
    }
    throw NativeScriptException(isolate, tcEval, "Cannot evaluate module " + canonicalPath);
  }
  LogEsmPhase(canonicalPath, "evaluate", "ok");

  if (!result->IsPromise()) {
    return MaybeLocal<Promise>();
  }
  LogEsmPhase(canonicalPath, "evaluate", "promise");
  Local<Promise> promise = result.As<Promise>();

  if (options.policy == ModuleEvaluationPolicy::kAsync) {
    return promise;
  }

  TryCatch promiseTc(isolate);

  if (options.policy == ModuleEvaluationPolicy::kSyncStrict) {
    Promise::PromiseState state = promise->State();
    if (state == Promise::kRejected) {
      ThrowModuleEvaluationRejection(isolate, promise, promiseTc, canonicalPath);
    }
    if (state == Promise::kPending) {
      // V8 guarantees a settled capability for a graph that reported
      // !IsGraphAsync, so reaching here means the graph classification and the
      // evaluation disagree — never paper over it with a half-initialized
      // namespace.
      throw NativeScriptException("ES module " + canonicalPath +
                                  " left its evaluation promise pending on a graph reported as "
                                  "synchronous");
    }
    LogEsmPhase(canonicalPath, "evaluate", "promise-resolved");
    return MaybeLocal<Promise>();
  }

  // Top-level await can depend on native async work such as fetch(), which requires
  // both V8 microtasks and the Cocoa run loop to advance. Returning early here would
  // let dynamic-import callers continue before the module finished evaluating.
  // An await whose resolution arrives as a v8 foreground task (e.g.
  // Atomics.waitAsync, streaming compilation) never settles from
  // checkpoints alone; JS frames are on the stack, so like the inspector
  // pause loops only nestable tasks may run here.
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> eventLoop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;

  auto pumpAsyncProgress = [&]() {
    if (eventLoop != nullptr) {
      eventLoop->RunNestableV8Tasks();
    }
    isolate->PerformMicrotaskCheckpoint();
    if (options.pumpRunLoop) {
      @autoreleasepool {
        NSRunLoop* runLoop =
            [NSThread isMainThread] ? [NSRunLoop mainRunLoop] : [NSRunLoop currentRunLoop];
        NSDate* sliceDeadline = [NSDate dateWithTimeIntervalSinceNow:0.01];
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:sliceDeadline];
      }
      isolate->PerformMicrotaskCheckpoint();
    }
  };

  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:options.deadlineSeconds];
  bool settled = false;

  // State is checked before the first pump: a synchronous graph's
  // evaluation promise is already settled when Evaluate() returns, so it
  // exits here without paying for a runloop slice.
  while (!promiseTc.HasCaught()) {
    Promise::PromiseState state = promise->State();
    if (state != Promise::kPending) {
      settled = true;
      if (state == Promise::kRejected) {
        ThrowModuleEvaluationRejection(isolate, promise, promiseTc, canonicalPath);
      }
      LogEsmPhase(canonicalPath, "evaluate", "promise-resolved");
      break;
    }

    if ([deadline timeIntervalSinceNow] <= 0) {
      break;
    }

    pumpAsyncProgress();
    if (!options.pumpRunLoop) {
      usleep(1000);  // 1ms delay for non-HTTP top-level await polling
    }
  }

  if (!settled && promise->State() == Promise::kPending) {
    LogEsmPhase(canonicalPath, "evaluate", "promise-timeout");
    if (options.timeoutBehavior == ModuleEvaluationOptions::TimeoutBehavior::kThrow) {
      RemoveModuleFromRegistry(isolate, canonicalPath);
      // Throw even in debug so the TLA timeout reason flows
      // through `ModuleInternal::RunModule`'s catch handler and
      // into the rejected promise the JS dev client observes —
      // a silent empty namespace here would surface only as a
      // generic "failed to import" with no clue that TLA had
      // timed out.
      if (RuntimeConfig.IsDebug) {
        Log(@"***** JavaScript exception occurred *****");
        Log(@"Top-level await timed out for ES module: %s", canonicalPath.c_str());
        Log(@"***** Debug mode - surfacing as exception so HMR dev session sees the reason *****");
      }

      throw NativeScriptException("Top-level await timed out for ES module " + canonicalPath);
    }
  }

  return MaybeLocal<Promise>();
}

Local<Value> ModuleInternal::LoadESModule(Isolate* isolate, const std::string& path,
                                          const ModuleEvaluationOptions& options) {
  bool isHttpModule = IsHttpModulePath(path);
  std::string canonicalPath = CanonicalizeModulePath(path);
  std::string requestPath = isHttpModule ? NormalizeHttpModuleUrl(path) : canonicalPath;
  auto context = isolate->GetCurrentContext();
  auto* registryPtr = ModuleRegistryFor(isolate);
  if (registryPtr == nullptr) {
    return Local<Value>();
  }
  auto& registry = *registryPtr;

  auto describeModuleStatus = [](Module::Status status) -> const char* {
    switch (status) {
      case Module::kUninstantiated:
        return "uninstantiated";
      case Module::kInstantiating:
        return "instantiating";
      case Module::kInstantiated:
        return "instantiated";
      case Module::kEvaluating:
        return "evaluating";
      case Module::kEvaluated:
        return "evaluated";
      case Module::kErrored:
        return "errored";
    }

    return "unknown";
  };

  Local<Module> reusedModule;
  auto existingIt = registry.find(canonicalPath);
  if (existingIt != registry.end()) {
    Local<Module> existing = existingIt->second.Get(isolate);
    if (existing.IsEmpty()) {
      TNS_DEBUG(Esm, "[cache] dropping empty registry entry %s", canonicalPath.c_str());
      RemoveModuleFromRegistry(isolate, canonicalPath);
    } else {
      Module::Status existingStatus = existing->GetStatus();
      TNS_DEBUG(Esm, "[cache] hit %s status=%s", canonicalPath.c_str(),
                describeModuleStatus(existingStatus));
      if (existingStatus == Module::kErrored) {
        RemoveModuleFromRegistry(isolate, canonicalPath);
      } else if (existingStatus == Module::kEvaluated) {
        // A top-level-await graph reports kEvaluated while its capability
        // promise is still pending, so the namespace here may be in its TDZ;
        // require() refuses the graph whatever the load order, matching Node.
        if (options.policy == ModuleEvaluationPolicy::kSyncStrict && existing->IsGraphAsync()) {
          ThrowAsyncGraphRefusal(canonicalPath);
        }
        return existing->GetModuleNamespace();
      } else if (existingStatus == Module::kUninstantiated ||
                 existingStatus == Module::kInstantiated) {
        // Recompiling would mint a second module identity while importers
        // still hold this one; reuse it and let InstantiateModule below
        // no-op (kInstantiated) or link it (kUninstantiated).
        reusedModule = existing;
      }
    }
  }

  auto logPhase = [&canonicalPath](const char* phase, const char* status,
                                   const char* classification = "", const char* extra = "") {
    LogEsmPhase(canonicalPath, phase, status, classification, extra);
  };
  Local<Module> module;
  if (!reusedModule.IsEmpty()) {
    logPhase("compile", "reuse-registry");
    module = reusedModule;
  } else if (isHttpModule) {
    logPhase("compile", "delegate-http");
    // Async-pipeline pre-pass: fetch + compile the entry's transitive
    // closure with concurrent background fetches, pumping this thread's
    // runloop until the graph settles (the "manual runloop until settled"
    // boot handoff for static HTTP entries). Afterwards the load below is a
    // registry hit and instantiation resolves as pure lookup. On timeout or
    // partial coverage the legacy synchronous path still owns correctness.
    RunModuleGraphLoadPumped(isolate, context, requestPath, kModuleEvaluateDeadlineSeconds);
    MaybeLocal<Module> maybeMod = LoadHttpModuleForUrl(isolate, context, requestPath);
    if (!maybeMod.ToLocal(&module)) {
      logPhase("compile", "fail", "http-loader");
      throw NativeScriptException("Cannot load ES module " + canonicalPath);
    }
    logPhase("compile", "ok", "http-loader");

    if (module->GetStatus() == Module::kEvaluated) {
      return module->GetModuleNamespace();
    }
  } else {
    logPhase("compile", "begin");
    // Discovery pre-pass for local roots too: a local graph can reach HTTP
    // edges, and without this they hit the resolver cold and fetch serially,
    // one blocking request at a time. The walk compiles and registers the
    // whole closure up front, so instantiation resolves as pure lookup. A
    // graph with no HTTP edges settles inside the call and pays no wait.
    //
    // The deadline is the FETCH bound, independent of the evaluation policy's
    // settle window: a strict require refuses an async EVALUATION, not an
    // async fetch, so it legitimately waits here and then evaluates
    // synchronously.
    RunModuleGraphLoadPumped(isolate, context, canonicalPath, kModuleEvaluateDeadlineSeconds);
    auto walkedIt = registry.find(canonicalPath);
    if (walkedIt != registry.end()) {
      Local<Module> walked = walkedIt->second.Get(isolate);
      if (!walked.IsEmpty() && walked->GetStatus() != Module::kErrored) {
        module = walked;
      }
    }

    if (module.IsEmpty()) {
      TryCatch tcCompile(isolate);
      MaybeLocal<Module> maybeMod = ModuleInternal::CompileFileEsModule(isolate, canonicalPath);

      if (!maybeMod.ToLocal(&module)) {
        // Attempt classification heuristics
        const char* classification = "unknown";
        if (tcCompile.HasCaught()) {
          Local<Message> msg = tcCompile.Message();
          if (!msg.IsEmpty()) {
            v8::String::Utf8Value w(isolate, msg->Get());
            if (*w) {
              std::string m(*w);
              if (m.find("Unexpected token") != std::string::npos ||
                  m.find("SyntaxError") != std::string::npos)
                classification = "syntax";
              else if (m.find("Cannot use import statement outside a module") != std::string::npos)
                classification = "not-a-module";
            }
          }
        }
        logPhase("compile", "fail", classification);
        if (RuntimeConfig.IsDebug) {
          Log(@"***** JavaScript exception occurred *****");
          Log(@"Error compiling ES module: %s", canonicalPath.c_str());
          if (tcCompile.HasCaught()) {
            tns::LogError(isolate, tcCompile);
          }
        }
        throw NativeScriptException(isolate, tcCompile,
                                    "Cannot compile ES module " + canonicalPath);
      }
    }
    logPhase("compile", "ok");

    // Register for resolution callback
    auto it = registry.find(canonicalPath);
    if (requestPath != canonicalPath || path != canonicalPath) {
      TNS_DEBUG(Esm, "[register] raw=%s request=%s canonical=%s existing=%s", path.c_str(),
                requestPath.c_str(), canonicalPath.c_str(), it != registry.end() ? "yes" : "no");
    }
    registry[canonicalPath].Reset(isolate, module);
    IndexModuleForIsolate(isolate, canonicalPath, module);
  }

  // 5) Instantiate (link) with its own TryCatch
  logPhase("instantiate", "begin");
  {
    TryCatch tcLink(isolate);
    bool linked = module->InstantiateModule(context, &ResolveModuleCallback).FromMaybe(false);

    if (!linked) {
      RemoveModuleFromRegistry(isolate, canonicalPath);
      const char* classification = "unknown";
      if (tcLink.HasCaught()) {
        Local<Message> msg = tcLink.Message();
        if (!msg.IsEmpty()) {
          v8::String::Utf8Value w(isolate, msg->Get());
          if (*w) {
            std::string m(*w);
            if (m.find("Cannot find module") != std::string::npos ||
                m.find("failed to resolve module specifier") != std::string::npos)
              classification = "resolve";
            else if (m.find("does not provide an export named") != std::string::npos)
              classification = "link-export";
          }
        }
      }
      logPhase("instantiate", "fail", classification);
      if (RuntimeConfig.IsDebug) {
        Log(@"***** JavaScript exception occurred *****");
        Log(@"Error instantiating module: %s", canonicalPath.c_str());
        if (tcLink.HasCaught()) {
          tns::LogError(isolate, tcLink);
        }
      }
      if (tcLink.HasCaught()) {
        throw NativeScriptException(isolate, tcLink, "Cannot instantiate module " + canonicalPath);
      }
      // V8 gave no exception object—throw plain text
      throw NativeScriptException(isolate, "Cannot instantiate module " + canonicalPath);
    }
  }
  logPhase("instantiate", "ok");

  // 6) Evaluate the graph under the caller's policy.
  EvaluateModuleGraph(isolate, context, module, canonicalPath, options);
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
    // Create a detailed error message with context
    std::string errorMsg = "Cannot find module '" + moduleName + "'";
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
  std::string key;
  if (path.length() > RuntimeConfig.ApplicationPath.size() &&
      path.compare(0, RuntimeConfig.ApplicationPath.size(), RuntimeConfig.ApplicationPath) == 0) {
    key = path.substr(RuntimeConfig.ApplicationPath.size() + 1);
  } else {
    // Fallback: use the entire path if it doesn't start with ApplicationPath
    key = path;
  }
  std::replace(key.begin(), key.end(), '/', '-');

  NSArray* paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString* cachesPath = [paths objectAtIndex:0];
  NSString* result =
      [cachesPath stringByAppendingPathComponent:[NSString stringWithUTF8String:key.c_str()]];

  return [result UTF8String];
}

}  // namespace tns
