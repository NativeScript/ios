#import "TNSAllocLog.h"
#import "../TNSTestCommon.h"

@implementation TNSAllocLog

// Disable ARC for TextFixtures.a and uncomment for debugging puproses
//- (instancetype)retain {
//    return [super retain];
//}
//- (void)release {
//    [super release];
//}

- (instancetype)init {
    TNSLog(@"TNSAllocLog init");
    return [super init];
}

- (void)dealloc {
    TNSLog(@"TNSAllocLog dealloc");
}

+ (void)autoreleaseInstance {
  // CFBridgingRetain moves the instance's ownership out of ARC so the
  // CFAutorelease'd reference in the current pool is the only one left.
  CFAutorelease(CFBridgingRetain([[TNSAllocLog alloc] init]));
}

@end
