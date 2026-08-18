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
- (void)runScriptString: (NSString*) script runLoop: (BOOL) runLoop;

/**
 Embedder-only: dispose the isolate and construct a new Runtime.
 JS-bootstrapped apps must not use this — it kills JS-backed delegates.
 */
- (void)restartWithConfig:(Config*)config;
- (void)shutdownRuntime;

/**
 WARNING: this method does not return in most applications. (UIApplicationMain)
 */
- (void)runMainApplication;
- (bool)liveSync;

@end

@interface NativeScriptRuntime : NSObject

/**
 Reset the JS application on the existing main isolate.
 Does not dispose the isolate, create a second Runtime, or re-enter
 UIApplicationMain. JS-backed AppDelegate / UIScene delegates stay alive.
 Optional baseDir points later module loads at an OTA bundle. After flushing
 module caches, invokes global.__onApplicationReload if present.
 */
+ (BOOL)reloadApplication;
+ (BOOL)reloadApplication:(NSString*)baseDir;

@end
