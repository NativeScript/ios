//
// Any changes in this file will be removed after you update your platform!
//
#import <UIKit/UIKit.h>
#import <NativeScript/NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

int main(int argc, char *argv[]) {
    assert(@protocol(UIApplicationDelegate));
    @autoreleasepool {
        void* metadataPtr = &startOfMetadataSection;

        [NativeScript start:metadataPtr];

        return 0;
    }
}
