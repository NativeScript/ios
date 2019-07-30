#include <string>
#include "ModuleInternal.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

ModuleInternal::ModuleInternal()
    : requireFunction_(nullptr), requireFactoryFunction_(nullptr) {
}

void ModuleInternal::Init(Isolate* isolate, const std::string& baseDir) {
    std::string requireFactoryScript =
        "(function() { "
        "    function require_factory(requireInternal, dirName) { "
        "        return function require(modulePath) { "
        "            return requireInternal(modulePath, dirName); "
        "        } "
        "    } "
        "    return require_factory; "
        "})()";

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Script> script;
    TryCatch tc(isolate);
    if (!Script::Compile(context, tns::ToV8String(isolate, requireFactoryScript.c_str())).ToLocal(&script) && tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        assert(false);
    }
    assert(!script.IsEmpty());

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        assert(false);
    }
    assert(!result.IsEmpty() && result->IsFunction());

    requireFactoryFunction_ = new Persistent<v8::Function>(isolate, result.As<v8::Function>());

    Local<FunctionTemplate> requireFuncTemplate = FunctionTemplate::New(isolate, RequireCallback, External::New(isolate, this));
    requireFunction_ = new Persistent<v8::Function>(isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

    Local<v8::Function> globalRequire = GetRequireFunction(isolate, baseDir);
    bool success = global->Set(context, tns::ToV8String(isolate, "require"), globalRequire).FromMaybe(false);
    assert(success);
}

Local<v8::Function> ModuleInternal::GetRequireFunction(Isolate* isolate, const std::string& dirName) {
    Local<v8::Function> requireFuncFactory = Local<v8::Function>::New(isolate, *requireFactoryFunction_);
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> requireInternalFunc = Local<v8::Function>::New(isolate, *requireFunction_);
    Local<Value> args[2] {
        requireInternalFunc, tns::ToV8String(isolate, dirName.c_str())
    };

    Local<Value> result;
    Local<Object> thiz = Object::New(isolate);
    bool success = requireFuncFactory->Call(context, thiz, 2, args).ToLocal(&result);
    assert(success && !result.IsEmpty() && result->IsFunction());

    return result.As<v8::Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& info) {
    ModuleInternal* moduleInternal = static_cast<ModuleInternal*>(info.Data().As<External>()->Value());
    Isolate* isolate = info.GetIsolate();

    std::string moduleName = tns::ToString(isolate, info[0].As<v8::String>());
    std::string callingModuleDirName = tns::ToString(isolate, info[1].As<v8::String>());
    Local<Object> moduleObj = moduleInternal->LoadImpl(isolate, moduleName, callingModuleDirName);

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> exportsObj;
    bool success = moduleObj->Get(context, tns::ToV8String(isolate, "exports")).ToLocal(&exportsObj);
    assert(success);
    info.GetReturnValue().Set(exportsObj);
}

Local<Object> ModuleInternal::LoadImpl(Isolate* isolate, const std::string& moduleName, const std::string& baseDir) {
    std::string cacheKey = baseDir + "*" + moduleName;
    auto it = loadedModules_.find(cacheKey);

    if (it != loadedModules_.end()) {
        Local<Object> result = Local<Object>::New(isolate, *it->second);
        return result;
    }

    Local<Object> moduleObj = Object::New(isolate);
    Local<Object> exportsObj = Object::New(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = moduleObj->Set(context, tns::ToV8String(isolate, "exports"), exportsObj).FromMaybe(false);
    assert(success);

    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    Local<v8::String> fileName = tns::ToV8String(isolate, baseDir + "/" + moduleName + ".js");
    success = moduleObj->DefineOwnProperty(context, tns::ToV8String(isolate, "id"), fileName, readOnlyFlags).FromMaybe(false);
    assert(success);

    Local<Script> script = LoadScript(isolate, moduleName, baseDir);

    TryCatch tc(isolate);
    Local<v8::Function> moduleFunc = script->Run(context).ToLocalChecked().As<v8::Function>();
    if (tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        assert(false);
    }

    Local<v8::Function> require = GetRequireFunction(isolate, baseDir);
    Local<Value> requireArgs[5] {
        moduleObj, exportsObj, require, tns::ToV8String(isolate, baseDir.c_str()), tns::ToV8String(isolate, baseDir.c_str())
    };

    success = moduleObj->Set(context, tns::ToV8String(isolate, "require"), require).FromMaybe(false);
    assert(success);

    Local<Object> thiz = Object::New(isolate);
    Local<Value> result;
    if (!moduleFunc->Call(context, thiz, sizeof(requireArgs) / sizeof(Local<Value>), requireArgs).ToLocal(&result)) {
        if (tc.HasCaught()) {
            printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        }
        assert(false);
    }

    Persistent<Object>* poModuleObj = new Persistent<Object>(isolate, moduleObj);
    loadedModules_.insert(make_pair(cacheKey, poModuleObj));

    return moduleObj;
}

Local<Script> ModuleInternal::LoadScript(Isolate* isolate, const std::string& moduleName, const std::string& baseDir) {
    Local<Context> context = isolate->GetCurrentContext();
    std::string path = baseDir + "/" + moduleName + ".js";
    std::string fullRequiredModulePathWithSchema = "file://" + path;
    ScriptOrigin origin(tns::ToV8String(isolate, fullRequiredModulePathWithSchema));
    Local<v8::String> scriptText = WrapModuleContent(isolate, path);
    ScriptCompiler::Source source(scriptText, origin, nullptr);
    TryCatch tc(isolate);
    Local<Script> script;
    bool success = ScriptCompiler::Compile(context, &source, ScriptCompiler::kNoCompileOptions).ToLocal(&script);
    if (!success || tc.HasCaught()) {
        if (tc.HasCaught()) {
            printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        }
        assert(false);
    }
    return script;
}

Local<v8::String> ModuleInternal::WrapModuleContent(Isolate* isolate, const std::string& path) {
    std::string content = tns::ReadText(path);
    std::string result("(function(module, exports, require, __filename, __dirname) { ");
    result.reserve(content.length() + 1024);
    result += content;
    result += "\n})";
    return tns::ToV8String(isolate, result.c_str());
}

}
