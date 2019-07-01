#include <string>
#include <chrono>
#include "Runtime.h"
#include "Console.h"
#include "SetTimeout.h"
#include "InlineFunctions.h"
#include "Helpers.h"
#include "Tasks.h"
#include "WeakRef.h"

#if defined __arm64 && __arm64__
#include "natives_blob.arm64.h"
#include "snapshot_blob.arm64.h"
#elif defined __x86_64__ && __x86_64__
#include "natives_blob.x86_64.h"
#include "snapshot_blob.x86_64.h"
#else
#error Unknown CPU architecture. Only ARM64 and X86_64 architectures are supported
#endif

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

namespace tns {

void Runtime::InitializeMetadata(void* metadataPtr) {
    MetaFile::setInstance(metadataPtr);
}

Runtime::Runtime() {
}

void Runtime::Init(const string& baseDir) {
    isolate_ = InitInternal(baseDir);
    RunScript("index.js");
    tns::Tasks::Drain();
}

Isolate* Runtime::InitInternal(const string& baseDir) {
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
    globalTemplateFunction->SetClassName(tns::ToV8String(isolate, "NativeScriptGlobalObject"));
    Local<ObjectTemplate> globalTemplate = ObjectTemplate::New(isolate, globalTemplateFunction);
    DefineNativeScriptVersion(isolate, globalTemplate);
    metadataBuilder_.RegisterConstantsOnGlobalObject(isolate, globalTemplate);
    DefinePerformanceObject(isolate, globalTemplate);
    DefineTimeMethod(isolate, globalTemplate);
    WeakRef::Init(isolate, globalTemplate);
    SetTimeout::Init(isolate, globalTemplate);

    Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
    context->Enter();

    baseDir_ = baseDir;
    DefineGlobalObject(context);
    Console::Init(isolate);
    moduleInternal_.Init(isolate, baseDir);
    metadataBuilder_.Init(isolate);
    InlineFunctions::Init(isolate);

    return isolate;
}

void Runtime::RunScript(string file) {
    Isolate* isolate = isolate_;
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    string source = tns::ReadText(baseDir_ + "/" + file);
    Local<v8::String> script_source = v8::String::NewFromUtf8(isolate, source.c_str(), NewStringType::kNormal).ToLocalChecked();
    Local<Script> script;
    TryCatch tc(isolate);
    if (!Script::Compile(context, script_source).ToLocal(&script) && tc.HasCaught()) {
        printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        assert(false);
    }

    Local<Value> result;
    if (!script->Run(context).ToLocal(&result)) {
        if (tc.HasCaught()) {
            printf("%s\n", tns::ToString(isolate_, tc.Exception()).c_str());
        }
        assert(false);
    }
}

void Runtime::DefineGlobalObject(Local<Context> context) {
    Local<Object> global = context->Global();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "global"), global, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Runtime::DefinePerformanceObject(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<ObjectTemplate> performanceTemplate = ObjectTemplate::New(isolate);

    Local<FunctionTemplate> nowFuncTemplate = FunctionTemplate::New(isolate, PerformanceNowCallback);
    performanceTemplate->Set(tns::ToV8String(isolate, "now"), nowFuncTemplate);

    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    Local<v8::String> performancePropertyName = ToV8String(isolate, "performance");
    globalTemplate->Set(performancePropertyName, performanceTemplate, readOnlyFlags);
}

void Runtime::PerformanceNowCallback(const FunctionCallbackInfo<Value>& args) {
    std::chrono::system_clock::time_point now = std::chrono::system_clock::now();
    std::chrono::milliseconds timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    double result = timestampMs.count();
    args.GetReturnValue().Set(result);
}

void Runtime::DefineNativeScriptVersion(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    globalTemplate->Set(ToV8String(isolate, "__runtimeVersion"), ToV8String(isolate, STRINGIZE_VALUE_OF(NATIVESCRIPT_VERSION)), readOnlyFlags);
}

void Runtime::DefineTimeMethod(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> timeFunctionTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        auto nano = std::chrono::time_point_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now());
        double duration = nano.time_since_epoch().count() / 1000000.0;
        info.GetReturnValue().Set(duration);
    });
    globalTemplate->Set(ToV8String(isolate, "__time"), timeFunctionTemplate);
}

}
