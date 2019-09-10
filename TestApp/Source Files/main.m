#import <NativeScript/NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void* metadataPtr = &startOfMetadataSection;

        NSString* applicationPath = [[NSBundle mainBundle] resourcePath];
        [NativeScript start:metadataPtr fromApplicationPath:applicationPath];

        return 0;
    }
}
