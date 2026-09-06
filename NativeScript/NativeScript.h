#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Config : NSObject

@property (nonatomic, retain) NSString* BaseDir;
@property (nonatomic, retain, nullable) NSString* ApplicationPath;
@property (nonatomic, nullable) void* MetadataPtr;
@property BOOL IsDebug;
@property BOOL LogToSystemConsole;
@property int ArgumentsCount;
@property (nonatomic) char* _Nullable* _Nullable Arguments;

@end

@interface NativeScript : NSObject

- (instancetype)initWithConfig:(Config*)config;
- (void)runScriptString: (NSString*) script runLoop: (BOOL) runLoop;
- (void)restartWithConfig:(Config*)config;
- (void)shutdownRuntime;

/**
 WARNING: this method does not return in most applications. (UIApplicationMain)
 */
- (void)runMainApplication;
- (bool)liveSync;

@end

NS_ASSUME_NONNULL_END
