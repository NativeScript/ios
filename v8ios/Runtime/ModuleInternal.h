#ifndef ModuleInternal_h
#define ModuleInternal_h

#include <map>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

using namespace v8;

namespace tns {

class ModuleInternal {
public:
    ModuleInternal();
    void Init(Isolate* isolate, const std::string& baseDir);
private:
    static void RequireCallback(const FunctionCallbackInfo<Value>& args);
    Local<Function> GetRequireFunction(const std::string& dirName);
    Local<Object> LoadImpl(const std::string& moduleName, const std::string& baseDir);
    Local<Script> LoadScript(const std::string& moduleName, const std::string& baseDir);
    Local<String> WrapModuleContent(const std::string& path);
    Isolate* isolate_;
    Persistent<Function>* requireFunction_;
    Persistent<Function>* requireFactoryFunction_;
    std::map<std::string, Persistent<Object>*> loadedModules_;
};

}

#endif /* ModuleInternal_h */
