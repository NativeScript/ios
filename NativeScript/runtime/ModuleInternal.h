#ifndef ModuleInternal_h
#define ModuleInternal_h

#include "Common.h"
#include "robin_hood.h"

namespace tns {

// The single deadline for every module-graph settle wait: the entry
// top-level-await pump in LoadESModule, the pumped async graph walk, and
// (doubled, as the outermost backstop) the app-boot handoff in
// NativeScript.mm. One knob, so the waits stay ordered: transport timeouts
// < this < the boot backstop.
inline constexpr double kModuleEvaluateDeadlineSeconds = 60.0;

class ModuleInternal {
 public:
  ModuleInternal(v8::Local<v8::Context> context);
  // Runs the entry module at `path` (main "./" or a worker entry). Throws
  // NativeScriptException on failure — the exception carries the cause
  // (compile/require error text, top-level-await rejection reason, or a
  // directional hint for an empty namespace); callers translate at their
  // boundary (workers re-arm it on the isolate for worker.onerror).
  void RunModule(v8::Isolate* isolate, std::string path);
  void RunScript(v8::Isolate* isolate, std::string script);
  static v8::Local<v8::Value> LoadScript(v8::Isolate* isolate,
                                         const std::string& path);
  // Read + wrap + compile `path` as an ES module (consuming/producing the
  // on-disk code cache) WITHOUT registering, instantiating, or evaluating it.
  // On compile failure the exception is left pending on the isolate (or a
  // NativeScriptException is thrown for setup failures) and the result is
  // empty. This is the resolver's file loader: the resolver must only ever
  // hand V8 a compiled module — evaluation order belongs to V8.
  static v8::MaybeLocal<v8::Module> CompileFileEsModule(
      v8::Isolate* isolate, const std::string& path);
  // The entry module's still-pending evaluation promise, or empty when
  // evaluation has settled (classic scripts settle synchronously and always
  // return empty). Callers use this after RunModule to observe a top-level
  // await that outlived the settle window. Note a TLA-parked module reports
  // kEvaluated while its capability promise is still pending, so this probes
  // the promise (Evaluate() returns the same capability), not the status.
  static v8::MaybeLocal<v8::Promise> PendingEntryEvaluation(
      v8::Isolate* isolate, const std::string& path);

 private:
  static void RequireCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
  v8::Local<v8::Function> GetRequireFunction(v8::Isolate* isolate,
                                             const std::string& dirName);
  v8::Local<v8::Object> LoadImpl(v8::Isolate* isolate,
                                 const std::string& moduleName,
                                 const std::string& baseDir, bool& isData);
  // Compile (and cache) a classic script; returns the compiled Script handle.
  static v8::Local<v8::Script> LoadClassicScript(v8::Isolate* isolate,
                                                 const std::string& path);

  // Compile/link/evaluate an ES module; returns its namespace object.
  static v8::Local<v8::Value> LoadESModule(v8::Isolate* isolate,
                                           const std::string& path);
  static v8::Local<v8::String> WrapModuleContent(v8::Isolate* isolate,
                                                 const std::string& path);
  v8::Local<v8::Object> LoadModule(v8::Isolate* isolate,
                                   const std::string& modulePath,
                                   const std::string& cacheKey);
  v8::Local<v8::Object> LoadData(v8::Isolate* isolate,
                                 const std::string& modulePath);
  std::string ResolvePath(v8::Isolate* isolate, const std::string& baseDir,
                          const std::string& moduleName);
  std::string ResolvePathFromPackageJson(const std::string& packageJson,
                                         bool& error);
  static v8::ScriptCompiler::CachedData* LoadScriptCache(
      const std::string& path);
  static void SaveScriptCache(const v8::Local<v8::Script> script,
                              const std::string& path);
  static void SaveScriptCache(const v8::ScriptCompiler::CachedData* cache,
                              const std::string& path);
  static std::string GetCacheFileName(const std::string& path);
  v8::MaybeLocal<v8::Value> RunScriptString(v8::Isolate* isolate,
                                            v8::Local<v8::Context> context,
                                            const std::string script);

  std::unique_ptr<v8::Persistent<v8::Function>> requireFunction_;
  std::unique_ptr<v8::Persistent<v8::Function>> requireFactoryFunction_;
  robin_hood::unordered_map<std::string,
                            std::shared_ptr<v8::Persistent<v8::Object>>>
      loadedModules_;

  struct TempModule {
   public:
    TempModule(ModuleInternal* module, std::string modulePath,
               std::string cacheKey,
               std::shared_ptr<v8::Persistent<v8::Object>> poModuleObj)
        : module_(module),
          dispose_(true),
          modulePath_(modulePath),
          cacheKey_(cacheKey) {
      module->loadedModules_.emplace(modulePath, poModuleObj);
      module->loadedModules_.emplace(cacheKey, poModuleObj);
    }

    ~TempModule() {
      if (this->dispose_) {
        this->module_->loadedModules_.erase(modulePath_);
        this->module_->loadedModules_.erase(cacheKey_);
      }
    }

    void SaveToCache() { this->dispose_ = false; }

   private:
    ModuleInternal* module_;
    bool dispose_;
    std::string modulePath_;
    std::string cacheKey_;
  };
};

}  // namespace tns

#endif /* ModuleInternal_h */
