#import <Foundation/Foundation.h>

@interface NativeScript : NSObject

+ (void)start:(void*)metadataPtr fromApplicationPath:(NSString*)path;
+ (bool)liveSync;

@end
