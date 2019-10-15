#import <Foundation/Foundation.h>

@interface Config : NSObject

@property (nonatomic) NSString* BaseDir;
@property (nonatomic) void* MetadataPtr;
@property (nonatomic) const char* SnapshotPtr;
@property size_t SnapshotSize;
@property BOOL IsDebug;
@property BOOL LogToSystemConsole;
@property int ArgumentsCount;
@property (nonatomic) char** Arguments;

@end

@interface NativeScript : NSObject

+ (void)start:(Config*)config;
+ (bool)liveSync;

@end
