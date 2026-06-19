#import "TNSReturnsRetained.h"

// Identity passthrough: hides the stack-block-ness from the compiler's
// return-stack-address diagnostic without copying the block to the heap.
static TNSIntBlock TNSPassthroughIntBlock(TNSIntBlock block) { return block; }

id functionReturnsNSRetained() { return [[NSObject alloc] init]; }
id functionReturnsCFRetained() { return [[NSObject alloc] init]; }
CFTypeRef functionImplicitCreate() { return [[NSObject alloc] init]; }
id functionExplicitCreateNSObject() { return [[NSObject alloc] init]; }

@implementation TNSReturnsRetained
+ (id)methodReturnsNSRetained {
  return [[NSObject alloc] init];
}
+ (id)methodReturnsCFRetained {
  return [[NSObject alloc] init];
}
+ (id)newNSObjectMethod {
  return [[TNSReturnsRetained alloc] init];
}
+ (TNSIntBlock)blockCapturing:(int)value {
  // This file is compiled with -fno-objc-arc. Capturing a non-constant value
  // (the parameter) forces a __NSStackBlock__ - capturing only a compile-time
  // constant would let clang promote it to a global block, which CFRetain
  // handles fine and would not reproduce the bug. The block is routed through
  // TNSPassthroughIntBlock so the compiler's "returning a stack block" check
  // can't see through the call boundary; it is still a +0 stack block living in
  // this frame at runtime. A correct runtime Block_copy's it to take ownership
  // (heap-promoting it). CFRetain does not promote a stack block, so the wrapper
  // is left pointing at this (about to be dead) stack frame.
  return TNSPassthroughIntBlock(^{
    return value;
  });
}
@end
