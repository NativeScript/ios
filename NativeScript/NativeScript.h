#import <Foundation/Foundation.h>

@interface NativeScript : NSObject

+ (void)start:(void*)metadataPtr;
+ (bool)liveSync;

@end
