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
    return tns::LiveSync(isolate);
}

@end
