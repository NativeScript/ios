#import <Foundation/Foundation.h>

@interface Config : NSObject

@property (nonatomic) NSString* BaseDir;
@property (nonatomic) void* MetadataPtr;
@property (nonatomic) const char* SnapshotPtr;
@property size_t SnapshotSize;
@property BOOL IsDebug;

@end

@interface NativeScript : NSObject

+ (void)start:(Config*)config;
+ (bool)liveSync;

@end
