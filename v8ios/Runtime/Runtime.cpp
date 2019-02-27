#include "TargetConditionals.h"
#include <string>
#include <chrono>
#include "Runtime.h"
#include "Console.h"

#if TARGET_OS_SIMULATOR
#include "natives_blob.x64.h"
#include "snapshot_blob.x64.h"
#else
#include "natives_blob.h"
#include "snapshot_blob.h"
#endif

using namespace v8;

namespace tns {

Runtime::Runtime() {
}

void Runtime::Init(const std::string& baseDir) {
    isolate_ = InitInternal(baseDir);
}

Isolate* Runtime::InitInternal(const std::string& baseDir) {
    platform_ = platform::NewDefaultPlatform().release();
    V8::InitializePlatform(platform_);
    V8::Initialize();
    std::string flags = "--expose_gc --jitless";
    V8::SetFlagsFromString(flags.c_str(), (int)flags.size());

    auto* nativesBlobStartupData = new StartupData();
    nativesBlobStartupData->data = reinterpret_cast<const char*>(&natives_blob_bin[0]);
    nativesBlobStartupData->raw_size = natives_blob_bin_len;
    V8::SetNativesDataBlob(nativesBlobStartupData);

    auto* snapshotBlobStartupData = new StartupData();
    snapshotBlobStartupData->data = reinterpret_cast<const char*>(&snapshot_blob_bin[0]);
    snapshotBlobStartupData->raw_size = snapshot_blob_bin_len;
    V8::SetSnapshotDataBlob(snapshotBlobStartupData);

    Isolate::CreateParams create_params;
    create_params.array_buffer_allocator = ArrayBuffer::Allocator::NewDefaultAllocator();
    Isolate* isolate = Isolate::New(create_params);

    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Local<FunctionTemplate> globalTemplateFunction = FunctionTemplate::New(isolate);
    Local<ObjectTemplate> globalTemplate = ObjectTemplate::New(isolate, globalTemplateFunction);
    Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
    context->Enter();

    baseDir_ = baseDir;
    DefineGlobalObject(context);
    DefinePerformanceObject(context);
    Console::Init(isolate);
    moduleInternal_.Init(isolate, baseDir);

    return isolate;
}

void Runtime::RunScript(std::string file) {
    Isolate* isolate = isolate_;
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    std::string source = Runtime::ReadText(baseDir_ + "/" + file);
    Local<String> script_source = String::NewFromUtf8(isolate, source.c_str(), NewStringType::kNormal).ToLocalChecked();
    Local<Script> script;
    TryCatch tc(isolate);
    if (!Script::Compile(context, script_source).ToLocal(&script) && tc.HasCaught()) {
        printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        assert(false);
    }

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result)) {
        if (tc.HasCaught()) {
            printf("%s\n", *String::Utf8Value(isolate_, tc.Exception()));
        }
        assert(false);
    }
}

void Runtime::DefineGlobalObject(Local<Context> context) {
    Local<Object> global = context->Global();
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, String::NewFromUtf8(context->GetIsolate(), "global"), global, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Runtime::DefinePerformanceObject(Local<Context> context) {
    Local<Object> global = context->Global();
    Local<String> performancePropertyName = String::NewFromUtf8(context->GetIsolate(), "performance");
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, performancePropertyName, global, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }

    Local<Value> performance;
    if (!global->Get(context, performancePropertyName).ToLocal(&performance) || !performance->IsObject()) {
        assert(false);
    }

    Local<Function> nowFunc;
    if (!Function::New(context, PerformanceNowCallback).ToLocal(&nowFunc)) {
        assert(false);
    }
    performance->ToObject(context).ToLocalChecked()->Set(String::NewFromUtf8(context->GetIsolate(), "now"), nowFunc);
}

void Runtime::PerformanceNowCallback(const FunctionCallbackInfo<Value>& args) {
    std::chrono::system_clock::time_point now = std::chrono::system_clock::now();
    std::chrono::milliseconds timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    double result = timestampMs.count();
    args.GetReturnValue().Set(result);
}

std::string Runtime::ReadText(const std::string& file) {
    std::ifstream ifs(file);
    if (ifs.fail()) {
        assert(false);
    }
    std::string content((std::istreambuf_iterator<char>(ifs)), (std::istreambuf_iterator<char>()));
    return content;
}

}
