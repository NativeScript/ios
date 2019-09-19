#ifndef ModuleInternal_h
#define ModuleInternal_h

#include "Common.h"
#include <unordered_map>

namespace tns {

class ModuleInternal {
public:
    ModuleInternal();
    void Init(v8::Isolate* isolate, const std::string& baseDir);
    void RunModule(v8::Isolate* isolate, std::string path);
private:
    static void RequireCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    v8::Local<v8::Function> GetRequireFunction(v8::Isolate* isolate, const std::string& dirName);
    v8::Local<v8::Object> LoadImpl(v8::Isolate* isolate, const std::string& moduleName, const std::string& baseDir, bool& isData);
    v8::Local<v8::Script> LoadScript(v8::Isolate* isolate, const std::string& path);
    v8::Local<v8::String> WrapModuleContent(v8::Isolate* isolate, const std::string& path);
    v8::Local<v8::Object> LoadModule(v8::Isolate* isolate, const std::string& modulePath, const std::string& cacheKey);
    v8::Local<v8::Object> LoadData(v8::Isolate* isolate, const std::string& modulePath);
    std::string ResolvePath(v8::Isolate* isolate, const std::string& baseDir, const std::string& moduleName);
    std::string ResolvePathFromPackageJson(const std::string& packageJson, bool& error);
    v8::ScriptCompiler::CachedData* LoadScriptCache(const std::string& path);
    void SaveScriptCache(const v8::Local<v8::Script> script, const std::string& path);
    std::string GetCacheFileName(const std::string& path);

    std::string baseDir_;
    v8::Persistent<v8::Function>* requireFunction_;
    v8::Persistent<v8::Function>* requireFactoryFunction_;
    std::unordered_map<std::string, v8::Persistent<v8::Object>*> loadedModules_;

    class TempModule {
    public:
        TempModule(ModuleInternal* module, std::string modulePath, std::string cacheKey, v8::Persistent<v8::Object>* poModuleObj)
            : module_(module), dispose_(true), modulePath_(modulePath), cacheKey_(cacheKey) {
            module->loadedModules_.insert(std::make_pair(modulePath, poModuleObj));
            module->loadedModules_.insert(std::make_pair(cacheKey, poModuleObj));
        }

        ~TempModule() {
            if (this->dispose_) {
                this->module_->loadedModules_.erase(modulePath_);
                this->module_->loadedModules_.erase(cacheKey_);
            }
        }

        void SaveToCache() {
            this->dispose_ = false;
        }
    private:
        ModuleInternal* module_;
        bool dispose_;
        std::string modulePath_;
        std::string cacheKey_;
    };
};

}

#endif /* ModuleInternal_h */
