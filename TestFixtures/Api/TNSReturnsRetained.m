#import "TNSReturnsRetained.h"

id functionReturnsNSRetained() {
    return [[NSObject alloc] init];
}
id functionReturnsCFRetained() {
    return [[NSObject alloc] init];
}
CFTypeRef functionImplicitCreate() {
    return [[NSObject alloc] init];
}
id functionExplicitCreateNSObject() {
    return [[NSObject alloc] init];
}

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
@end
