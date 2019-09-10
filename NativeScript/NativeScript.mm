#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "runtime/Runtime.h"
#include "runtime/Helpers.h"

using namespace v8;
using namespace tns;

@implementation NativeScript

static Runtime* runtime_ = nullptr;

+ (void)start:(void*)metadataPtr fromApplicationPath:(NSString*)path {
    NSString* appPath = [path stringByAppendingPathComponent:@"app"];
    const char* baseDir = [appPath UTF8String];

    Runtime::InitializeMetadata(metadataPtr);
    runtime_ = new Runtime();
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
            printf("%s\n", tns::ToString(isolate, tc.Exception()).c_str());
        }
        return false;
    }

    return true;
}

@end
