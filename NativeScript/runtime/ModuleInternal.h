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

// How a module graph's evaluation promise is settled.
//   kSyncStrict  - Node's `require(esm)`: an async graph is refused before it
//                  ever evaluates, and the capability promise must already be
//                  settled when Evaluate() returns.
//   kSyncPumping - drive this thread in place until the promise settles or the
//                  window closes. Only legal while nothing else owns the loop
//                  (entry evaluation), and only nestable V8 tasks can run.
//   kAsync       - evaluate and hand the caller the capability promise.
enum class ModuleEvaluationPolicy { kSyncStrict, kSyncPumping, kAsync };

struct ModuleEvaluationOptions {
  enum class TimeoutBehavior { kReturnPending, kThrow };

  ModuleEvaluationPolicy policy = ModuleEvaluationPolicy::kSyncStrict;
  // kSyncPumping only: how long the graph gets to settle in-pump.
  double deadlineSeconds = 0.0;
  // kSyncPumping only: what an expired window means.
  TimeoutBehavior timeoutBehavior = TimeoutBehavior::kReturnPending;
  // kSyncPumping only: also give the Cocoa runloop a slice per iteration, for
  // graphs whose progress depends on native transports rather than V8 tasks.
  bool pumpRunLoop = false;
};

// Evaluates an instantiated graph under `options`. Returns the capability
// promise for kAsync and an empty handle otherwise; the namespace always comes
// from the module itself. Throws NativeScriptException on failure, in every
// build. `canonicalPath` names the registry entry to evict on failure and
// labels the phase logs.
v8::MaybeLocal<v8::Promise> EvaluateModuleGraph(
    v8::Isolate* isolate, v8::Local<v8::Context> context,
    v8::Local<v8::Module> module, const std::string& canonicalPath,
    const ModuleEvaluationOptions& options);

// The state of an entry module's evaluation promise. kNone means the path
// names no registered ES module — a classic script settles synchronously and
// never has one, so it needs no boot backstop.
enum class EntryEvaluationState { kNone, kPending, kFulfilled, kRejected };

// The app's main entry, resolved from package.json's `main` (with the usual
// extension probing). Boot code needs the resolved path to ask about the
// entry's evaluation.
std::string ResolveMainEntryFromPackageJson(const std::string& baseDir);

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
  static v8::Local<v8::Value> LoadScript(
      v8::Isolate* isolate, const std::string& path,
      const ModuleEvaluationOptions& options);
  // Installs `createRequire` on the `ns:module` binding object. Kept here
  // rather than with the dev-loader members because it hands out the very
  // require the CommonJS loader builds for every module.
  static bool InstallCreateRequireBinding(v8::Local<v8::Context> context,
                                          v8::Local<v8::Object> binding);
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
  // The same probe, but reporting the promise's state rather than only
  // "pending or not" — the boot backstop must tell a rejection from a
  // successful settle. Cheap enough to call once per pump slice: a registry
  // hit plus Evaluate(), which returns the existing capability promise.
  // `rejectionReason` (when non-null) receives the reason's text on kRejected.
  static EntryEvaluationState PollEntryEvaluation(v8::Isolate* isolate,
                                                  const std::string& path,
                                                  std::string* rejectionReason);

 private:
  static void RequireCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
  static void CreateRequireCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  // A require bound to `dirName`, whose ES module loads evaluate under
  // `options`. The options ride along as trailing arguments to the require
  // factory, so nothing about them is ambient — and they are resolved once at
  // mint time, never per require() call.
  v8::Local<v8::Function> GetRequireFunction(
      v8::Isolate* isolate, const std::string& dirName,
      const ModuleEvaluationOptions& options);
  v8::Local<v8::Object> LoadImpl(v8::Isolate* isolate,
                                 const std::string& moduleName,
                                 const std::string& baseDir, bool& isData,
                                 const ModuleEvaluationOptions& options);
  // Compile (and cache) a classic script; returns the compiled Script handle.
  static v8::Local<v8::Script> LoadClassicScript(v8::Isolate* isolate,
                                                 const std::string& path);

  // Compile/link/evaluate an ES module; returns its namespace object.
  static v8::Local<v8::Value> LoadESModule(
      v8::Isolate* isolate, const std::string& path,
      const ModuleEvaluationOptions& options);
  static v8::Local<v8::String> WrapModuleContent(v8::Isolate* isolate,
                                                 const std::string& path);
  v8::Local<v8::Object> LoadModule(v8::Isolate* isolate,
                                   const std::string& modulePath,
                                   const std::string& cacheKey,
                                   const ModuleEvaluationOptions& options);
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
