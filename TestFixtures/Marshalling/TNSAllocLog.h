#ifndef TNSAllocLog_h
#define TNSAllocLog_h

@interface TNSAllocLog : NSObject

// Disable ARC for TextFixtures.a and uncomment for debugging puproses
//- (instancetype)retain;
//- (void)release;

- (instancetype)init;
- (void)dealloc;

// Creates an instance whose only reference is in the current autorelease pool,
// so its dealloc log marks when that pool drains.
+ (void)autoreleaseInstance;

@end

#endif /* TNSAllocLog_h */
