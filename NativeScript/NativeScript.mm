#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "runtime/Runtime.h"
#include "runtime/Helpers.h"

using namespace v8;
using namespace tns;

@implementation NativeScript

static Runtime* runtime_ = nullptr;

+ (void)start:(void*)metadataPtr fromApplicationPath:(NSString*)path fromNativesPtr:(const char*)nativesPtr fromNativesSize:(size_t)nativesSize fromSnapshotPtr:(const char*)snapshotPtr fromSnapshotSize:(size_t)snapshotSize isDebug:(bool)isDebug {
    NSString* appPath = [path stringByAppendingPathComponent:@"app"];
    const char* baseDir = [appPath UTF8String];

    Runtime::Initialize(metadataPtr, nativesPtr, nativesSize, snapshotPtr, snapshotSize, isDebug);
    runtime_ = new Runtime();
    runtime_->SetIsDebug(isDebug);
    runtime_->InitAndRunMainScript(baseDir);
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
