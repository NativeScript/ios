#include <string>
#include "ModuleInternal.h"
#include "Runtime.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

ModuleInternal::ModuleInternal()
    : isolate_(nullptr), requireFunction_(nullptr), requireFactoryFunction_(nullptr) {
}

void ModuleInternal::Init(Isolate* isolate, const std::string& baseDir) {
    isolate_ = isolate;

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
        printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        assert(false);
    }
    assert(!script.IsEmpty());

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        assert(false);
    }
    assert(!result.IsEmpty() && result->IsFunction());

    requireFactoryFunction_ = new Persistent<v8::Function>(isolate, result.As<v8::Function>());

    Local<FunctionTemplate> requireFuncTemplate = FunctionTemplate::New(isolate, RequireCallback, External::New(isolate, this));
    requireFunction_ = new Persistent<v8::Function>(isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

    Local<v8::Function> globalRequire = GetRequireFunction(baseDir);
    global->Set(tns::ToV8String(isolate, "require"), globalRequire);
}

Local<v8::Function> ModuleInternal::GetRequireFunction(const std::string& dirName) {
    Local<v8::Function> requireFuncFactory = Local<v8::Function>::New(isolate_, *requireFactoryFunction_);
    Local<Context> context = isolate_->GetCurrentContext();
    Local<v8::Function> requireInternalFunc = Local<v8::Function>::New(isolate_, *requireFunction_);
    Local<Value> args[2] {
        requireInternalFunc, tns::ToV8String(isolate_, dirName.c_str())
    };

    Local<Value> result;
    Local<Object> thiz = Object::New(isolate_);
    bool success = requireFuncFactory->Call(context, thiz, 2, args).ToLocal(&result);
    assert(success && !result.IsEmpty() && result->IsFunction());

    return result.As<v8::Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& args) {
    ModuleInternal* moduleInternal = static_cast<ModuleInternal*>(args.Data().As<External>()->Value());
    Isolate* isolate = moduleInternal->isolate_;

    std::string moduleName = tns::ToString(isolate, args[0].As<v8::String>());
    std::string callingModuleDirName = tns::ToString(isolate, args[1].As<v8::String>());
    Local<Object> moduleObj = moduleInternal->LoadImpl(moduleName, callingModuleDirName);

    Local<Value> exportsObj = moduleObj->Get(tns::ToV8String(isolate, "exports"));
    args.GetReturnValue().Set(exportsObj);
}

Local<Object> ModuleInternal::LoadImpl(const std::string& moduleName, const std::string& baseDir) {
    std::string cacheKey = baseDir + "*" + moduleName;
    auto it = loadedModules_.find(cacheKey);

    if (it != loadedModules_.end()) {
        Local<Object> result = Local<Object>::New(isolate_, *it->second);
        return result;
    }

    Local<Object> moduleObj = Object::New(isolate_);
    Local<Object> exportsObj = Object::New(isolate_);
    moduleObj->Set(tns::ToV8String(isolate_, "exports"), exportsObj);

    Local<Script> script = LoadScript(moduleName, baseDir);
    Local<Context> context = isolate_->GetCurrentContext();

    TryCatch tc(isolate_);
    Local<v8::Function> moduleFunc = script->Run(context).ToLocalChecked().As<v8::Function>();
    if (tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        assert(false);
    }

    Local<v8::Function> require = GetRequireFunction(baseDir);
    Local<Value> requireArgs[4] {
        moduleObj, exportsObj, require, tns::ToV8String(isolate_, baseDir.c_str())
    };

    moduleObj->Set(tns::ToV8String(isolate_, "require"), require);

    Local<Object> thiz = Object::New(isolate_);
    Local<Value> result;
    if (!moduleFunc->Call(context, thiz, sizeof(requireArgs) / sizeof(Local<Value>), requireArgs).ToLocal(&result)) {
        if (tc.HasCaught()) {
            printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        }
        assert(false);
    }

    Persistent<Object>* poModuleObj = new Persistent<Object>(isolate_, moduleObj);
    loadedModules_.insert(make_pair(cacheKey, poModuleObj));

    return moduleObj;
}

Local<Script> ModuleInternal::LoadScript(const std::string& moduleName, const std::string& baseDir) {
    ScriptOrigin origin(tns::ToV8String(isolate_, ("file://" + moduleName + ".js").c_str()));
    Local<v8::String> scriptText = WrapModuleContent(baseDir + "/" + moduleName + ".js");
    ScriptCompiler::Source source(scriptText, origin);
    TryCatch tc(isolate_);
    MaybeLocal<Script> maybeScript = ScriptCompiler::Compile(isolate_->GetCurrentContext(), &source, ScriptCompiler::kNoCompileOptions);
    if (maybeScript.IsEmpty() || tc.HasCaught()) {
        if (tc.HasCaught()) {
            printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        }
        assert(false);
    }
    return maybeScript.ToLocalChecked();
}

Local<v8::String> ModuleInternal::WrapModuleContent(const std::string& path) {
    std::string content = Runtime::ReadText(path);
    std::string result("(function(module, exports, require, __filename, __dirname) { ");
    result.reserve(content.length() + 1024);
    result += content;
    result += "\n})";
    return tns::ToV8String(isolate_, result.c_str());
}

}
