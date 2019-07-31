#ifndef ModuleInternal_h
#define ModuleInternal_h

#include "Common.h"
#include <map>

namespace tns {

class ModuleInternal {
public:
    ModuleInternal();
    void Init(v8::Isolate* isolate, const std::string& baseDir);
    void RunModule(v8::Isolate* isolate, std::string path);
private:
    static void RequireCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    v8::Local<v8::Function> GetRequireFunction(v8::Isolate* isolate, const std::string& dirName);
    v8::Local<v8::Value> LoadImpl(v8::Isolate* isolate, const std::string& moduleName, const std::string& baseDir);
    v8::Local<v8::Script> LoadScript(v8::Isolate* isolate, const std::string& path);
    v8::Local<v8::String> WrapModuleContent(v8::Isolate* isolate, const std::string& path);
    v8::Local<v8::Object> LoadModule(v8::Isolate* isolate, const std::string& modulePath);
    v8::Local<v8::Object> LoadData(v8::Isolate* isolate, const std::string& modulePath);
    std::string ResolvePath(const std::string& baseDir, const std::string& moduleName);
    std::string ResolvePathFromPackageJson(const std::string& packageJson);
    v8::Persistent<v8::Function>* requireFunction_;
    v8::Persistent<v8::Function>* requireFactoryFunction_;
    std::map<std::string, v8::Persistent<v8::Object>*> loadedModules_;
};

}

#endif /* ModuleInternal_h */
