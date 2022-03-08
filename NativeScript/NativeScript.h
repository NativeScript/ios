#import <Foundation/Foundation.h>

@interface Config : NSObject

@property (nonatomic, retain) NSString* BaseDir;
@property (nonatomic, retain) NSString* ApplicationPath;
@property (nonatomic) void* MetadataPtr;
@property BOOL IsDebug;
@property BOOL LogToSystemConsole;
@property int ArgumentsCount;
@property (nonatomic) char** Arguments;

@end

@interface NativeScript : NSObject

- (instancetype)initWithConfig:(Config*)config;
- (void) runMainScript;
- (void)runScriptString: (NSString*) script runLoop: (BOOL) runLoop;
- (bool)liveSync;

@end
