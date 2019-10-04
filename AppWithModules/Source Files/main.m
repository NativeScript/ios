#import <NativeScript/NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
extern char startOfSnapshotSection __asm("section$start$__DATA$__TNSSnapshot");
extern char endOfSnapshotSection __asm("section$end$__DATA$__TNSSnapshot");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void* metadataPtr = &startOfMetadataSection;

        const char* startSnapshotPtr = &startOfSnapshotSection;
        const char* endSnapshotPtr = &endOfSnapshotSection;
        size_t snapshotSize = endSnapshotPtr - startSnapshotPtr;

        NSString* baseDir = [[NSBundle mainBundle] resourcePath];

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

        [NativeScript start:config];

        return 0;
    }
}
