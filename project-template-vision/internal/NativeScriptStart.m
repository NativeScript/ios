//
//  NativeScriptStart.m
//
//  Created by Team nStudio on 7/5/23.
//  Copyright © 2023 NativeScript. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <NativeScript/NativeScript.h>
#import <NativeScriptStart.h>

#include <dlfcn.h>
#include <notify.h>
#include "macros.h"

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
NativeScript* nativescriptStart;

@implementation NativeScriptStart

+(void)setup{
     @autoreleasepool {
         NSString* baseDir = [[NSBundle mainBundle] resourcePath];

             // TKLiveSync is in NS_DEBUG_FRAMEWORKS: only debug configurations embed it, unless
             // NS_SHIP_DEBUG_FRAMEWORKS lists it.
             void (*initializeLiveSync)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "TNSInitializeLiveSync");
             if (initializeLiveSync != NULL) {
                 int refreshRequestSubscription;
                 notify_register_dispatch(NOTIFICATION("RefreshRequest"), &refreshRequestSubscription, dispatch_get_main_queue(), ^(int token) {
                     notify_post(NOTIFICATION("AppRefreshStarted"));
                     bool success = [nativescriptStart liveSync];
                     if (success) {
                         notify_post(NOTIFICATION("AppRefreshSucceeded"));
                     } else {
                         NSLog(@"__onLiveSync call failed");
                         notify_post(NOTIFICATION("AppRefreshFailed"));
                     }
                 });

                 initializeLiveSync();
                 if (getenv("TNSBaseDir")) {
                     baseDir = @(getenv("TNSBaseDir"));
                 }
             }

             void* metadataPtr = &startOfMetadataSection;

             bool isDebug =
     #ifdef DEBUG
                 true;
     #else
                 false;
     #endif

             Config* config = [[Config alloc] init];
             config.IsDebug = isDebug;
             config.LogToSystemConsole = isDebug;
             config.MetadataPtr = metadataPtr;
             config.BaseDir = baseDir;
//             config.ArgumentsCount = argc;
//             config.Arguments = argv;

            nativescriptStart = [[NativeScript alloc] initWithConfig:config];

         }

}
+(void)boot{
    [nativescriptStart runMainApplication];
}
@end


