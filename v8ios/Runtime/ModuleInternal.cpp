#include <string>
#include "ModuleInternal.h"
#include "Runtime.h"

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
    if (!Script::Compile(context, String::NewFromUtf8(isolate, requireFactoryScript.c_str())).ToLocal(&script) && tc.HasCaught()) {
        printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        assert(false);
    }
    assert(!script.IsEmpty());

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result) && tc.HasCaught()) {
        printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        assert(false);
    }
    assert(!result.IsEmpty() && result->IsFunction());

    requireFactoryFunction_ = new Persistent<Function>(isolate, result.As<Function>());

    Local<FunctionTemplate> requireFuncTemplate = FunctionTemplate::New(isolate, RequireCallback, External::New(isolate, this));
    requireFunction_ = new Persistent<Function>(isolate, requireFuncTemplate->GetFunction(context).ToLocalChecked());

    Local<Function> globalRequire = GetRequireFunction(baseDir);
    global->Set(String::NewFromUtf8(isolate, "require"), globalRequire);
}

Local<Function> ModuleInternal::GetRequireFunction(const std::string& dirName) {
    Local<Function> requireFuncFactory = Local<Function>::New(isolate_, *requireFactoryFunction_);
    Local<Context> context = isolate_->GetCurrentContext();
    Local<Function> requireInternalFunc = Local<Function>::New(isolate_, *requireFunction_);
    Local<Value> args[2] {
        requireInternalFunc, String::NewFromUtf8(isolate_, dirName.c_str())
    };

    Local<Value> result;
    Local<Object> thiz = Object::New(isolate_);
    bool success = requireFuncFactory->Call(context, thiz, 2, args).ToLocal(&result);
    assert(success && !result.IsEmpty() && result->IsFunction());

    return result.As<Function>();
}

void ModuleInternal::RequireCallback(const FunctionCallbackInfo<Value>& args) {
    ModuleInternal* moduleInternal = static_cast<ModuleInternal*>(args.Data().As<External>()->Value());
    Isolate* isolate = moduleInternal->isolate_;

    std::string moduleName = *String::Utf8Value(isolate, args[0].As<String>());
    std::string callingModuleDirName = *String::Utf8Value(isolate, args[1].As<String>());
    Local<Object> moduleObj = moduleInternal->LoadImpl(moduleName, callingModuleDirName);

    Local<Value> exportsObj = moduleObj->Get(String::NewFromUtf8(isolate, "exports"));
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
    moduleObj->Set(String::NewFromUtf8(isolate_, "exports"), exportsObj);

    Local<Script> script = LoadScript(moduleName, baseDir);
    Local<Context> context = isolate_->GetCurrentContext();

    TryCatch tc(isolate_);
    Local<Function> moduleFunc = script->Run(context).ToLocalChecked().As<Function>();
    if (tc.HasCaught()) {
        printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        assert(false);
    }

    Local<Function> require = GetRequireFunction(baseDir);
    Local<Value> requireArgs[4] {
        moduleObj, exportsObj, require, String::NewFromUtf8(isolate_, baseDir.c_str())
    };

    moduleObj->Set(String::NewFromUtf8(isolate_, "require"), require);

    Local<Object> thiz = Object::New(isolate_);
    Local<Value> result;
    if (!moduleFunc->Call(context, thiz, sizeof(requireArgs) / sizeof(Local<Value>), requireArgs).ToLocal(&result)) {
        if (tc.HasCaught()) {
            printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        }
        assert(false);
    }

    Persistent<Object>* poModuleObj = new Persistent<Object>(isolate_, moduleObj);
    loadedModules_.insert(make_pair(cacheKey, poModuleObj));

    return moduleObj;
}

Local<Script> ModuleInternal::LoadScript(const std::string& moduleName, const std::string& baseDir) {
    ScriptOrigin origin(String::NewFromUtf8(isolate_, ("file://" + moduleName + ".js").c_str()));
    Local<String> scriptText = WrapModuleContent(baseDir + "/" + moduleName + ".js");
    ScriptCompiler::Source source(scriptText, origin);
    TryCatch tc(isolate_);
    MaybeLocal<Script> maybeScript = ScriptCompiler::Compile(isolate_->GetCurrentContext(), &source, ScriptCompiler::kNoCompileOptions);
    assert(!maybeScript.IsEmpty() && !tc.HasCaught());
    return maybeScript.ToLocalChecked();
}

Local<String> ModuleInternal::WrapModuleContent(const std::string& path) {
    std::string content = Runtime::ReadText(path);
    std::string result("(function(module, exports, require, __filename, __dirname) { ");
    result.reserve(content.length() + 1024);
    result += content;
    result += "\n})";
    return String::NewFromUtf8(isolate_, result.c_str());
}

}
