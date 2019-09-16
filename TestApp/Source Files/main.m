#import <NativeScript/NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");
extern char startOfNativesSection __asm("section$start$__DATA$__TNSNatives");
extern char endOfNativesSection __asm("section$end$__DATA$__TNSNatives");
extern char startOfSnapshotSection __asm("section$start$__DATA$__TNSSnapshot");
extern char endOfSnapshotSection __asm("section$end$__DATA$__TNSSnapshot");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void* metadataPtr = &startOfMetadataSection;

        const char* startNativesPtr = &startOfNativesSection;
        const char* endNativesPtr = &endOfNativesSection;
        size_t nativesSize = endNativesPtr - startNativesPtr;

        const char* startSnapshotPtr = &startOfSnapshotSection;
        const char* endSnapshotPtr = &endOfSnapshotSection;
        size_t snapshotSize = endSnapshotPtr - startSnapshotPtr;

        NSString* applicationPath = [[NSBundle mainBundle] resourcePath];

        [NativeScript start:metadataPtr
                      fromApplicationPath:applicationPath
                      fromNativesPtr:startNativesPtr
                      fromNativesSize:nativesSize
                      fromSnapshotPtr:startSnapshotPtr
                      fromSnapshotSize:snapshotSize];

        return 0;
    }
}
