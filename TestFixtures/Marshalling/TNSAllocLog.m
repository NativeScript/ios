#import "TNSAllocLog.h"
#import <objc/message.h>
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

- (instancetype)initWithObject:(id)object {
    return [self init];
}

+ (void (^)(id))objectSink {
    return ^(id object) {
    };
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

+ (void)allocInitAndDrop:(Class)cls {
    id result = [[cls alloc] init];
    (void)result;
}

@end

@implementation TNSCopyKeeper {
    NSMutableArray* _copies;
}

- (void)keepCopyOf:(id)object {
    if (_copies == nil) {
        _copies = [NSMutableArray array];
    }
    [_copies addObject:[object copy]];
}

- (BOOL)keepTwoCopiesOf:(id)object {
    [self keepCopyOf:object];
    [self keepCopyOf:object];
    return _copies[_copies.count - 1] == _copies[_copies.count - 2];
}

- (void)drop {
    _copies = nil;
}

@end

@implementation TNSOwnedBlocks {
    NSInteger (^_stored)(void);
}

- (NSInteger (^)(void))retainedBlockAnswering:(NSInteger)value {
    return [self blockAnswering:value];
}

- (NSInteger (^)(void))blockAnswering:(NSInteger)value {
    TNSAllocLog* captured = [[TNSAllocLog alloc] init];
    return ^NSInteger {
        (void)captured;
        return value;
    };
}

- (NSInteger (^)(void))retainedBlockFrom:(NSInteger (^)(void))block {
    return block;
}

- (NSInteger (^)(void))blockFrom:(NSInteger (^)(void))block {
    return block;
}

+ (NSInteger)callBlock:(NSInteger (^)(void))block {
    return block();
}

- (void)storeBlock:(NSInteger (^)(void))block {
    _stored = block;
}

- (NSInteger (^)(void))retainedStoredBlock {
    NSInteger (^block)(void) = _stored;
    _stored = nil;
    return block;
}

static NSInteger (^gSharedBlock)(NSInteger);

// A JS block's dispose waits for its isolate, so the slot's previous block is
// released outside the lock. Precise lifetime keeps ARC from releasing it
// earlier, at its last use inside the lock.
+ (void)storeSharedBlock:(NSInteger (^)(NSInteger))block {
    __attribute__((objc_precise_lifetime)) NSInteger (^previous)(NSInteger);
    @synchronized([TNSOwnedBlocks class]) {
        previous = gSharedBlock;
        gSharedBlock = block;
    }
    previous = nil;
}

+ (NSInteger (^)(NSInteger))sharedBlock {
    NSInteger (^block)(NSInteger);
    @synchronized([TNSOwnedBlocks class]) {
        block = gSharedBlock;
    }
    return block;
}

+ (NSInteger (^)(NSInteger))retainedSharedBlock {
    return [self sharedBlock];
}

+ (NSInteger (^)(NSInteger))takeSharedBlock {
    NSInteger (^block)(NSInteger);
    @synchronized([TNSOwnedBlocks class]) {
        block = gSharedBlock;
        gSharedBlock = nil;
    }
    return block;
}

+ (void)clearSharedBlock {
    __attribute__((objc_precise_lifetime)) NSInteger (^block)(NSInteger);
    @synchronized([TNSOwnedBlocks class]) {
        block = gSharedBlock;
        gSharedBlock = nil;
    }
    block = nil;
}

+ (NSInteger)callBlock:(NSInteger (^)(NSInteger))block withValue:(NSInteger)value {
    return block(value);
}

@end

// Foundation answers tagged pointers for dates in the range JS can represent.
@interface TNSHeapDate : NSDate
@end

@implementation TNSHeapDate {
    NSTimeInterval _interval;
}

// NSDate's initializers end in the one this class would have to override, so
// the instance is used uninitialized, which NSObject allows.
+ (instancetype)heapDateWithInterval:(NSTimeInterval)interval {
    TNSHeapDate* date = [self alloc];
    date->_interval = interval;
    return date;
}

- (NSTimeInterval)timeIntervalSinceReferenceDate {
    return _interval;
}

@end

@implementation TNSOwnedPrimitives {
    NSArray* _objects;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString* string = [[NSMutableString stringWithString:@"an owned string long enough to live on the heap"] copy];
        _objects = @[ string, [NSNumber numberWithDouble:M_PI], [TNSHeapDate heapDateWithInterval:700000000.5] ];
    }
    return self;
}

- (id)newObjectAt:(NSUInteger)index {
    return _objects[index];
}

- (id)objectAt:(NSUInteger)index {
    return _objects[index];
}

- (NSUInteger)retainCountAt:(NSUInteger)index {
    return CFGetRetainCount((__bridge CFTypeRef)_objects[index]);
}

- (BOOL)isTaggedPointerAt:(NSUInteger)index {
    uintptr_t bits = (uintptr_t)(__bridge void*)_objects[index];
    // The ObjC runtime's OBJC_MSB_TAGGED_POINTERS condition (objc-internal.h).
#if (TARGET_OS_OSX || TARGET_OS_MACCATALYST) && __x86_64__
    return (bits & 1) != 0;
#else
    return (bits >> 63) != 0;
#endif
}

@end

id TNSOwnedPrimitivesRetainedObjectAt(TNSOwnedPrimitives* holder, NSUInteger index) {
    return [holder objectAt:index];
}

id TNSOwnedPrimitivesObjectAt(TNSOwnedPrimitives* holder, NSUInteger index) {
    return [holder objectAt:index];
}

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

@implementation TNSReplaceableRetainCount

+ (NSUInteger)retainCountOf:(id)object {
  return ((NSUInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName("retainCount"));
}

@end

@implementation TNSUninitializedTimer

+ (id)placeholder {
  return [NSTimer alloc];
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

@implementation TNSAccessorHost
@end

@implementation TNSAccessorDeallocHost

- (void)dealloc {
    id value = self.value;
    (void)value;
}

@end

static TNSAccessorHost* keptAccessorHost;

@implementation TNSAccessorSwizzleTarget
@end

@implementation TNSAccessorDriver {
    TNSAccessorHost* _host;
    id _lastObservedValue;
}

- (instancetype)initWithNewHostOf:(Class)cls name:(NSString*)name {
    self = [super init];
    if (self) {
        _host = [[cls alloc] init];
        _host.name = name;
    }
    return self;
}

- (instancetype)initWithHost:(TNSAccessorHost*)host {
    self = [super init];
    if (self) {
        _host = host;
    }
    return self;
}

- (id)readValue {
    return _host.value;
}

- (void)writeValue:(id)value {
    _host.value = value;
}

- (TNSAccessorHost*)host {
    return _host;
}

- (void)dropHost {
    _host = nil;
}

- (void)observeHost {
    [_host addObserver:self
            forKeyPath:@"value"
               options:NSKeyValueObservingOptionNew
               context:NULL];
}

- (void)unobserveHost {
    [_host removeObserver:self forKeyPath:@"value"];
}

- (id)lastObservedValue {
    return _lastObservedValue;
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id>*)change
                       context:(void*)context {
    _lastObservedValue = [object valueForKey:keyPath];
}

+ (id)valueOfNewHostOf:(Class)cls name:(NSString*)name {
    TNSAccessorHost* host = [[cls alloc] init];
    host.name = name;
    return host.value;
}

+ (void)dropNewHostOf:(Class)cls name:(NSString*)name {
    TNSAccessorHost* host = [[cls alloc] init];
    host.name = name;
}

+ (void)keepNewHostOf:(Class)cls name:(NSString*)name {
    TNSAccessorHost* host = [[cls alloc] init];
    host.name = name;
    keptAccessorHost = host;
}

+ (id)readKeptValue {
    return keptAccessorHost.value;
}

+ (CGRect)readKeptRect {
    return keptAccessorHost.rect;
}

+ (void)writeKeptValue:(id)value {
    keptAccessorHost.value = value;
}

+ (id)readSwizzleTargetValue {
    return [[TNSAccessorSwizzleTarget alloc] init].value;
}

+ (void)writeSwizzleTargetValue:(id)value {
    [[TNSAccessorSwizzleTarget alloc] init].value = value;
}

+ (void)dropKeptHost {
    keptAccessorHost = nil;
}

@end

@implementation TNSReplaceableRetainCount

+ (NSUInteger)retainCountOf:(id)object {
  return ((NSUInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName("retainCount"));
}

+ (void)addNewInstanceTo:(NSMutableArray*)owner {
  TNSReplaceableRetainCount* instance = [[self alloc] init];
  [owner addObject:instance];
  [self retainCountOf:instance];
}

@end

@implementation NSTimer (TNSCallbackHook)

- (void)tnsCallbackHook {
}

+ (void)tnsAddHookedTimerTo:(NSMutableArray*)owner {
  NSTimer* timer = [NSTimer timerWithTimeInterval:1000
                                           target:[[TNSAllocLog alloc] init]
                                         selector:@selector(description)
                                         userInfo:nil
                                          repeats:NO];
  [owner addObject:timer];
  [timer tnsCallbackHook];
}

@end

@implementation TNSUninitializedTimer

+ (id)placeholder {
  return [NSTimer alloc];
}

+ (void)hookPlaceholder {
  [[NSTimer alloc] tnsCallbackHook];
}

@end
