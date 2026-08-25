#import "TNSReturnsRetained.h"

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
+ (void)passStackBlockCapturing:(int)value to:(void (^)(TNSIntBlock))callback {
  // This file is compiled with -fno-objc-arc. Capturing a non-constant value
  // (the parameter) forces a __NSStackBlock__ - capturing only a compile-time
  // constant would let clang promote it to a global block, which CFRetain
  // handles fine and would not reproduce the bug. The block is handed over as a
  // callback argument, not a return value: this frame is still alive while the
  // callee marshals it, so a correct runtime can take ownership with Block_copy
  // (heap-promoting it) in time. CFRetain does not promote a stack block, so a
  // wrapper kept past this call would point into this dead frame.
  callback(^{
    return value;
  });
}
@end
