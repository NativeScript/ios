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

@end

@implementation TNSSubstitutingInit

- (instancetype)init {
    return (id)[[TNSAllocLog alloc] init];
}

@end

@implementation TNSOwnedReturns

- (id)newChild {
    return [[TNSAllocLog alloc] init];
}

+ (void)copyAndDrop:(id)object {
    id result = [object copy];
    (void)result;
}

+ (void)mutableCopyAndDrop:(id)object {
    id result = [object mutableCopy];
    (void)result;
}

+ (void)newChildAndDrop:(TNSOwnedReturns*)object {
    id result = [object newChild];
    (void)result;
}

+ (void)awakeAndDrop:(id)object {
    NSCoder* coder = nil;
    id result = [object awakeAfterUsingCoder:coder];
    (void)result;
}

@end
