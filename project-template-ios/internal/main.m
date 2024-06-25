//
// Any changes in this file will be removed after you update your platform!
//
#import <UIKit/UIKit.h>
#import <NativeScript/NativeScript.h>

#ifdef DEBUG
#include <notify.h>
#include <TKLiveSync/TKLiveSync.h>
#include "macros.h"
#endif

#if NS_SWIFTUI_BOOT == 0
// Users can disable Obj-C bootstrapping by defining NS_SWIFTUI_BOOT = 1 in their project's build.xcconfig file
// This requires a NativeScriptApp.swift to be setup in the project and embedding enabled in @nativescript/core bootstrap

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
NativeScript* nativescript;

int main(int argc, char *argv[]) {
   @autoreleasepool {
       NSString* baseDir = [[NSBundle mainBundle] resourcePath];

#ifdef DEBUG
       int refreshRequestSubscription;
       notify_register_dispatch(NOTIFICATION("RefreshRequest"), &refreshRequestSubscription, dispatch_get_main_queue(), ^(int token) {
           notify_post(NOTIFICATION("AppRefreshStarted"));
           bool success = [nativescript liveSync];
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
       config.ArgumentsCount = argc;
       config.Arguments = argv;

       nativescript = [[NativeScript alloc] initWithConfig:config];
       [nativescript runMainApplication];

       return 0;
   }
}

#endif
