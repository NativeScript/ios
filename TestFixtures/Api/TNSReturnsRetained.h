id functionReturnsNSRetained() NS_RETURNS_RETAINED;
id functionReturnsCFRetained() CF_RETURNS_RETAINED;

CF_IMPLICIT_BRIDGING_ENABLED
CFTypeRef functionImplicitCreate();
CF_IMPLICIT_BRIDGING_DISABLED

id functionExplicitCreateNSObject();

typedef int (^TNSIntBlock)(void);

@interface TNSReturnsRetained : NSObject
+ (id)methodReturnsNSRetained NS_RETURNS_RETAINED;
+ (id)methodReturnsCFRetained CF_RETURNS_RETAINED;
+ (id)newNSObjectMethod;
// Returns a +0 __NSStackBlock__ capturing `value` (see implementation). Used to
// regression-test native block ownership: the runtime must take it with
// Block_copy and release it with Block_release, not CFRetain/CFRelease.
+ (TNSIntBlock)blockCapturing:(int)value;
@end
