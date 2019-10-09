//
// Any changes in this file will be removed after you update your platform!
//
#import <UIKit/UIKit.h>
#import <NativeScript/NativeScript.h>

#ifdef DEBUG
#include <notify.h>
#include "TKLiveSync/include/TKLiveSync.h"

#define NOTIFICATION(name)                                                      \
    [[NSString stringWithFormat:@"%@:NativeScript.Debug.%s",                    \
        [[NSBundle mainBundle] bundleIdentifier], name] UTF8String]
#endif

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
extern char startOfSnapshotSection __asm("section$start$__DATA$__TNSSnapshot");
extern char endOfSnapshotSection __asm("section$end$__DATA$__TNSSnapshot");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString* baseDir = [[NSBundle mainBundle] resourcePath];

#ifdef DEBUG
        int refreshRequestSubscription;
        notify_register_dispatch(NOTIFICATION("RefreshRequest"), &refreshRequestSubscription, dispatch_get_main_queue(), ^(int token) {
            notify_post(NOTIFICATION("AppRefreshStarted"));
            bool success = [NativeScript liveSync];
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

        const char* startSnapshotPtr = &startOfSnapshotSection;
        const char* endSnapshotPtr = &endOfSnapshotSection;
        size_t snapshotSize = endSnapshotPtr - startSnapshotPtr;

        bool isDebug =
#ifdef DEBUG
            true;
#else
            false;
#endif

        Config* config = [[Config alloc] init];
        config.IsDebug = isDebug;
        config.MetadataPtr = metadataPtr;
        config.SnapshotPtr = startSnapshotPtr;
        config.SnapshotSize = snapshotSize;
        config.BaseDir = baseDir;
        config.ArgumentsCount = argc;
        config.Arguments = argv;

        [NativeScript start:config];

        return 0;
    }
}
