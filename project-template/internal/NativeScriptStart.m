//
//  NativeScriptStart.m
//
//  Created by Team nStudio on 7/5/23.
//  Copyright © 2023 NativeScript. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <NativeScript/NativeScript.h>
#import <NativeScriptStart.h>

#ifdef DEBUG
#include <notify.h>
#include <TKLiveSync/TKLiveSync.h>
#include "macros.h"
#endif

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
NativeScript* nativescriptStart;

@implementation NativeScriptStart

+(void)setup{
     @autoreleasepool {
         NSString* baseDir = [[NSBundle mainBundle] resourcePath];

     #ifdef DEBUG
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

             TNSInitializeLiveSync();
             if (getenv("TNSBaseDir")) {
                 baseDir = @(getenv("TNSBaseDir"));
             }
     #endif

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


