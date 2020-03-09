#include "TNSPseudoDataTypes.h"
#include "TNSTestCommon.h"

@interface TNSPseudoDataTypeInternal : TNSType<Proto1, Proto2>

-(void)methodFromProto1;

-(void)methodFromProto2:(NSString*)param;

@end

@implementation TNSType

-(void)method {
    TNSLog(@"method called");
}

@end

@implementation TNSPseudoDataTypeInternal

-(void)methodFromProto1 {
    TNSLog(@"methodFromProto1 called");
}

-(void)methodFromProto2:(NSString*)param {
    TNSLog([NSString stringWithFormat:@"methodFromProto2 called with %@", param]);
}

@end

@implementation TNSPseudoDataType

+(id<Proto1, Proto2>)getId {
    TNSPseudoDataTypeInternal* internal = [[TNSPseudoDataTypeInternal alloc] init];
    return internal;
}

+(TNSType<Proto1, Proto2>*)getType {
    TNSPseudoDataTypeInternal* internal = [[TNSPseudoDataTypeInternal alloc] init];
    return internal;
}

@end
