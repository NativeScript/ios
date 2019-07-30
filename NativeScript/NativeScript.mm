#include <Foundation/Foundation.h>
#include "NativeScript.h"
#include "Runtime/Runtime.h"

@implementation NativeScript

+(void)start:(void*)metadataPtr {
    NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
    NSArray* components = [NSArray arrayWithObjects:resourcePath, @"app", nil];
    NSString* path = [NSString pathWithComponents:components];
    const char* baseDir = [path UTF8String];

    tns::Runtime::InitializeMetadata(metadataPtr);
    tns::Runtime* runtime = new tns::Runtime();
    runtime->InitAndRunMainScript(baseDir);
}

@end