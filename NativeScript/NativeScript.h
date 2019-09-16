#import <Foundation/Foundation.h>

@interface NativeScript : NSObject

+ (void)start:(void*)metadataPtr fromApplicationPath:(NSString*)path fromNativesPtr:(const char*)nativesPtr fromNativesSize:(size_t)nativesSize fromSnapshotPtr:(const char*)snapshotPtr fromSnapshotSize:(size_t)snapshotSize;
+ (bool)liveSync;

@end
