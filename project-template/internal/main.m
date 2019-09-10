//
// Any changes in this file will be removed after you update your platform!
//
#import <UIKit/UIKit.h>
#import <NativeScript/NativeScript.h>

#ifdef DEBUG
#include <notify.h>

#define NOTIFICATION(name)                                                      \
    [[NSString stringWithFormat:@"%@:NativeScript.Debug.%s",                    \
        [[NSBundle mainBundle] bundleIdentifier], name] UTF8String]
#endif

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

int main(int argc, char *argv[]) {
    @autoreleasepool {

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
#endif

        void* metadataPtr = &startOfMetadataSection;

        NSString* applicationPath = [[NSBundle mainBundle] resourcePath];
        [NativeScript start:metadataPtr fromApplicationPath:applicationPath];

        return 0;
    }
}
