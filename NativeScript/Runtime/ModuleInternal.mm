#include <Foundation/Foundation.h>
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

void ModuleInternal::RunModule(Isolate* isolate, std::string path) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> globalObject = context->Global();
    Local<Value> requireObj;
    bool success = globalObject->Get(context, ToV8String(isolate, "require")).ToLocal(&requireObj);
    assert(success && requireObj->IsFunction());
    Local<v8::Function> requireFunc = requireObj.As<v8::Function>();
    Local<Value> args[] = { ToV8String(isolate, path) };
    Local<Value> result;
    success = requireFunc->Call(context, globalObject, 1, args).ToLocal(&result);
    assert(success);
}

Local<v8::Function> ModuleInternal::GetRequireFunction(Isolate* isolate, const std::string& dirName) {
    Local<v8::Function> requireFuncFactory = requireFactoryFunction_->Get(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> requireInternalFunc = requireFunction_->Get(isolate);
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

    NSString* fullPath = (moduleName.length() > 0 && moduleName[0] == '/')
        ? [NSString stringWithUTF8String:moduleName.c_str()]
        : [[NSString stringWithUTF8String:callingModuleDirName.c_str()] stringByAppendingPathComponent:[NSString stringWithUTF8String:moduleName.c_str()]];
    NSString* fileNameOnly = [fullPath lastPathComponent];
    NSString* pathOnly = [fullPath stringByDeletingLastPathComponent];

    Local<Value> resultObj = moduleInternal->LoadImpl(isolate, [fileNameOnly UTF8String], [pathOnly UTF8String]);

    info.GetReturnValue().Set(resultObj);
}

Local<Value> ModuleInternal::LoadImpl(Isolate* isolate, const std::string& moduleName, const std::string& baseDir) {
    size_t lastIndex = moduleName.find_last_of(".");
    std::string moduleNameWithoutExtension = (lastIndex == std::string::npos) ? moduleName : moduleName.substr(0, lastIndex);
    std::string cacheKey = baseDir + "*" + moduleNameWithoutExtension;
    auto it = loadedModules_.find(cacheKey);

    if (it != loadedModules_.end()) {
        Local<Object> result = Local<Object>::New(isolate, *it->second);
        return result;
    }

    Local<Object> moduleObj;
    Local<Value> exportsObj;
    std::string path = this->ResolvePath(baseDir, moduleName);
    NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
    NSString* extension = [pathStr pathExtension];
    if ([extension isEqualToString:@"js"]) {
        moduleObj = this->LoadModule(isolate, path);
        Local<Context> context = isolate->GetCurrentContext();
        bool success = moduleObj->Get(context, tns::ToV8String(isolate, "exports")).ToLocal(&exportsObj);
        assert(success);
    } else if ([extension isEqualToString:@"json"]) {
        moduleObj = this->LoadData(isolate, path);
    } else {
        // TODO: throw an error for unsupported file extension
        assert(false);
    }

    Persistent<Object>* poModuleObj = new Persistent<Object>(isolate, moduleObj);
    loadedModules_.insert(make_pair(cacheKey, poModuleObj));

    if (!exportsObj.IsEmpty()) {
        return exportsObj;
    }

    return moduleObj;
}

Local<Object> ModuleInternal::LoadModule(Isolate* isolate, const std::string& modulePath) {
    Local<Object> moduleObj = Object::New(isolate);
    Local<Object> exportsObj = Object::New(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = moduleObj->Set(context, tns::ToV8String(isolate, "exports"), exportsObj).FromMaybe(false);
    assert(success);

    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);

    Local<v8::String> fileName = tns::ToV8String(isolate, modulePath);
    success = moduleObj->DefineOwnProperty(context, tns::ToV8String(isolate, "id"), fileName, readOnlyFlags).FromMaybe(false);
    assert(success);

    Local<Script> script = LoadScript(isolate, modulePath);

    TryCatch tc(isolate);
    Local<v8::Function> moduleFunc = script->Run(context).ToLocalChecked().As<v8::Function>();
    if (tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        assert(false);
    }

    std::string parentDir = [[[NSString stringWithUTF8String:modulePath.c_str()] stringByDeletingLastPathComponent] UTF8String];
    Local<v8::Function> require = GetRequireFunction(isolate, parentDir);
    Local<Value> requireArgs[5] {
        moduleObj, exportsObj, require, tns::ToV8String(isolate, modulePath.c_str()), tns::ToV8String(isolate, parentDir.c_str())
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

    return moduleObj;
}

Local<Object> ModuleInternal::LoadData(Isolate* isolate, const std::string& modulePath) {
    Local<Object> json;

    std::string jsonData = tns::ReadText(modulePath);

    TryCatch tc(isolate);

    Local<v8::String> jsonStr = tns::ToV8String(isolate, jsonData);

    Local<Context> context = isolate->GetCurrentContext();
    MaybeLocal<Value> maybeValue = JSON::Parse(context, jsonStr);

    if (maybeValue.IsEmpty() || tc.HasCaught()) {
        std::string errMsg = "Cannot parse JSON file " + modulePath;
        // TODO: throw exception
        assert(false);
    }

    Local<Value> value = maybeValue.ToLocalChecked();

    if (!value->IsObject()) {
        std::string errMsg = "JSON is not valid, file=" + modulePath;
        // TODO: throw exception
        assert(false);
    }

    json = value.As<Object>();

    return json;
}

Local<Script> ModuleInternal::LoadScript(Isolate* isolate, const std::string& path) {
    Local<Context> context = isolate->GetCurrentContext();
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
    return tns::ToV8String(isolate, result);
}

std::string ModuleInternal::ResolvePath(const std::string& baseDir, const std::string& moduleName) {
    NSString* baseDirStr = [NSString stringWithUTF8String:baseDir.c_str()];
    NSString* moduleNameStr = [NSString stringWithUTF8String:moduleName.c_str()];
    NSString* fullPath = [[baseDirStr stringByAppendingPathComponent:moduleNameStr] stringByStandardizingPath];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    BOOL exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];

    if (exists == YES && isDirectory == YES) {
        NSString* jsFile = [fullPath stringByAppendingPathExtension:@"js"];
        BOOL isDir;
        if ([fileManager fileExistsAtPath:jsFile isDirectory:&isDir] && isDir == NO) {
            return [jsFile UTF8String];
        }
    }

    if (exists == NO) {
        fullPath = [fullPath stringByAppendingPathExtension:@"js"];
        exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
    }

    if (exists == NO) {
        // TODO: throw an exception
        assert(false);
    }

    if (isDirectory == NO) {
        return [fullPath UTF8String];
    }

    // Try to resolve module from main entry in package.json
    NSString* packageJson = [fullPath stringByAppendingPathComponent:@"package.json"];
    std::string entry = this->ResolvePathFromPackageJson([packageJson UTF8String]);
    if (!entry.empty()) {
        fullPath = [NSString stringWithUTF8String:entry.c_str()];
    }

    exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
    if (exists == YES && isDirectory == NO) {
        return [fullPath UTF8String];
    }

    if (exists == NO) {
        fullPath = [fullPath stringByAppendingPathExtension:@"js"];
    } else {
        fullPath = [fullPath stringByAppendingPathComponent:@"index.js"];
    }

    exists = [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
    if (exists == NO) {
        // TODO: throw an exception
        assert(false);
    }


    return [fullPath UTF8String];
}

std::string ModuleInternal::ResolvePathFromPackageJson(const std::string& packageJson) {
    NSString* packageJsonStr = [NSString stringWithUTF8String:packageJson.c_str()];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    BOOL exists = [fileManager fileExistsAtPath:packageJsonStr isDirectory:&isDirectory];
    if (exists == NO || isDirectory == YES) {
        return std::string();
    }

    NSData *data = [NSData dataWithContentsOfFile:packageJsonStr];
    if (data == nil) {
        return std::string();
    }

    NSDictionary* dic = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    if (dic == nil) {
        return std::string();
    }

    NSString *main = [dic objectForKey:@"main"];
    if (main == nil) {
        return std::string();
    }

    NSString* path = [[[packageJsonStr stringByDeletingLastPathComponent] stringByAppendingPathComponent:main] stringByStandardizingPath];
    exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];

    if (exists == YES && isDirectory == YES) {
        packageJsonStr = [path stringByAppendingPathComponent:@"package.json"];
        exists = [fileManager fileExistsAtPath:packageJsonStr isDirectory:&isDirectory];
        if (exists == YES && isDirectory == NO) {
            return this->ResolvePathFromPackageJson([packageJsonStr UTF8String]);
        }
    }

    return [path UTF8String];
}

}
