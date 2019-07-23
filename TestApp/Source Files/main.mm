#import <UIKit/UIKit.h>
#import <NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        NSArray* components = [NSArray arrayWithObjects:resourcePath, @"app", nil];
        NSString* path = [NSString pathWithComponents:components];
        std::string baseDir = [path UTF8String];
        void* metadataPtr = &startOfMetadataSection;
        tns::NativeScript::Start(metadataPtr, baseDir);

        return 0;
    }
}
