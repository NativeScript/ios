#ifndef ModuleInternal_h
#define ModuleInternal_h

#include "Common.h"
#include <map>

namespace tns {

class ModuleInternal {
public:
    ModuleInternal();
    void Init(v8::Isolate* isolate, const std::string& baseDir);
private:
    static void RequireCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    v8::Local<v8::Function> GetRequireFunction(v8::Isolate* isolate, const std::string& dirName);
    v8::Local<v8::Object> LoadImpl(v8::Isolate* isolate, const std::string& moduleName, const std::string& baseDir);
    v8::Local<v8::Script> LoadScript(v8::Isolate* isolate, const std::string& moduleName, const std::string& baseDir);
    v8::Local<v8::String> WrapModuleContent(v8::Isolate* isolate, const std::string& path);
    v8::Persistent<v8::Function>* requireFunction_;
    v8::Persistent<v8::Function>* requireFactoryFunction_;
    std::map<std::string, v8::Persistent<v8::Object>*> loadedModules_;
};

}

#endif /* ModuleInternal_h */
