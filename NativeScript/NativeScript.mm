#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "runtime/Runtime.h"
#include "runtime/Helpers.h"
#include "runtime/RuntimeConfig.h"

using namespace v8;
using namespace tns;

@implementation Config

@synthesize BaseDir;
@synthesize MetadataPtr;
@synthesize NativesPtr;
@synthesize NativesSize;
@synthesize SnapshotPtr;
@synthesize SnapshotSize;
@synthesize IsDebug;

@end

@implementation NativeScript

static Runtime* runtime_ = nullptr;

+ (void)start:(Config*)config {
    RuntimeConfig.BaseDir = [config.BaseDir UTF8String];
    RuntimeConfig.ApplicationPath = [[config.BaseDir stringByAppendingPathComponent:@"app"] UTF8String];
    RuntimeConfig.MetadataPtr = [config MetadataPtr];
    RuntimeConfig.NativesPtr = [config NativesPtr];
    RuntimeConfig.NativesSize = [config NativesSize];
    RuntimeConfig.SnapshotPtr = [config SnapshotPtr];
    RuntimeConfig.SnapshotSize = [config SnapshotSize];
    RuntimeConfig.IsDebug = [config IsDebug];

    Runtime::Initialize();
    runtime_ = new Runtime();
    runtime_->InitAndRunMainScript();
}

+ (bool)liveSync {
    if (runtime_ == nullptr) {
        return false;
    }

    Isolate* isolate = runtime_->GetIsolate();
    HandleScope scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> value;
    bool success = global->Get(context, tns::ToV8String(isolate, "__onLiveSync")).ToLocal(&value);
    if (!success || value.IsEmpty() || !value->IsFunction()) {
        return false;
    }

    Local<v8::Function> liveSyncFunc = value.As<v8::Function>();
    Local<Value> args[0];
    Local<Value> result;

    TryCatch tc(isolate);
    success = liveSyncFunc->Call(context, v8::Undefined(isolate), 0, args).ToLocal(&result);
    if (!success || tc.HasCaught()) {
        if (tc.HasCaught()) {
            tns::LogError(isolate, tc);
        }
        return false;
    }

    return true;
}

@end
