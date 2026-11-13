#include "TNSPseudoDataTypes.h"
#include "TNSTestCommon.h"

@interface TNSPseudoDataTypeInternal : TNSType<Proto1, Proto2>

-(void)methodFromProto1;

-(void)methodFromProto2:(NSString*)param;

@end

@interface TNSWithOptionalMember : NSObject <TNSOptionalMemberProtocol>
@end

@implementation TNSWithOptionalMember

-(NSString*)optionalMember {
    return @"optional member";
}

@end

@interface TNSWithoutOptionalMember : NSObject <TNSOptionalMemberProtocol>
@end

@implementation TNSWithoutOptionalMember
@end

@implementation TNSReadwriteValue
@end

@implementation TNSType

-(void)method {
    TNSLog(@"method called");
}

@end

@implementation TNSPseudoDataTypeInternal

@synthesize propertyFromProto1;
@synthesize propertyFromProto2;

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
    internal.propertyFromProto1 = @"property from proto1";
    internal.propertyFromProto2 = @"property from proto2";
    return internal;
}

+(id<TNSOptionalMemberProtocol>)getWithOptionalMember {
    return [[TNSWithOptionalMember alloc] init];
}

+(id<TNSOptionalMemberProtocol>)getWithoutOptionalMember {
    return [[TNSWithoutOptionalMember alloc] init];
}

+(id<TNSReadonlyValueProtocol>)getReadwriteValue {
    return [[TNSReadwriteValue alloc] init];
}

+(TNSType<Proto1, Proto2>*)getType {
    TNSPseudoDataTypeInternal* internal = [[TNSPseudoDataTypeInternal alloc] init];
    internal.propertyFromProto1 = @"property from proto1";
    internal.propertyFromProto2 = @"property from proto2";
    return internal;
}

@end
