#import <NativeScript/NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
NativeScript* nativescript;

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void* metadataPtr = &startOfMetadataSection;

        NSString* baseDir = [[NSBundle mainBundle] resourcePath];

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

        nativescript = [[NativeScript alloc] initWithConfig: config];
        [nativescript runMainScript];

        return 0;
    }
}
