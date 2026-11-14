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

+ (void)newChildAndDrop:(id)object {
    id result = [object newChild];
    (void)result;
}

+ (void)awakeAndDrop:(id)object {
    NSCoder* coder = nil;
    id result = [object awakeAfterUsingCoder:coder];
    (void)result;
}

- (id)newItem {
    return [[TNSAllocLog alloc] init];
}

+ (void)newItemAndDrop:(id)object {
    id result = [object newItem];
    (void)result;
}

+ (id)readNewItemOf:(id)object {
    return [object newItem];
}

@end

@implementation TNSSwizzledOwnedReturns

- (id)newChild {
    return [[TNSAllocLog alloc] init];
}

- (id)newItem {
    return [[TNSAllocLog alloc] init];
}

@end

@implementation TNSCodingAllocLog

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
    return [super init];
}

- (void)encodeWithCoder:(NSCoder*)coder {
}

@end

@implementation TNSDecodeDelegate

- (id)unarchiver:(NSKeyedUnarchiver*)unarchiver didDecodeObject:(id)object {
    return self.substitutes ? [[TNSAllocLog alloc] init] : object;
}

@end

@implementation TNSInitCallsHook

- (instancetype)init {
    self = [super init];
    [self initHook];
    return self;
}

- (void)initHook {
}

@end
