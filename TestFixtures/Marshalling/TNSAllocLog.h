#ifndef TNSAllocLog_h
#define TNSAllocLog_h

@interface TNSAllocLog : NSObject

// Disable ARC for TextFixtures.a and uncomment for debugging puproses
//- (instancetype)retain;
//- (void)release;

- (instancetype)init;
- (void)dealloc;

@end

// -init answers a new TNSAllocLog in place of the receiver.
@interface TNSSubstitutingInit : NSObject

- (instancetype)init;

@end

// Native callers that own what an owned-return message answers and drop it
// straight away.
@interface TNSOwnedReturns : TNSAllocLog

// Answers a new TNSAllocLog.
- (id)newChild;

+ (void)copyAndDrop:(id)object;
+ (void)mutableCopyAndDrop:(id)object;
+ (void)newChildAndDrop:(TNSOwnedReturns*)object;
+ (void)awakeAndDrop:(id)object;

@end

#endif /* TNSAllocLog_h */
