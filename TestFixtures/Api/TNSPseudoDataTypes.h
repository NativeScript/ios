#import <Foundation/Foundation.h>

@protocol Proto1

@property (nonatomic) NSString* propertyFromProto1;
-(void)methodFromProto1;

@end

@protocol Proto2

@property (nonatomic) NSString* propertyFromProto2;
-(void)methodFromProto2:(NSString*)param;

@end

@protocol TNSOptionalMemberProtocol

@optional
-(NSString*)optionalMember;

@end

@protocol TNSReadonlyValueProtocol

@property (nonatomic, readonly) NSInteger value;

@end

@interface TNSReadwriteValue : NSObject

@property (nonatomic) NSInteger value;

@end

@protocol TNSDeclaredMemberProtocol

-(NSString*)declaredMember;

@end

@interface TNSDeclaredMemberBase : NSObject
@end

// Declared for the base class, implemented only by TNSDeclaredMemberSubclass.
@interface TNSDeclaredMemberBase (TNSDeclaredOnly)

-(NSString*)declaredMember;

@end

@interface TNSDeclaredMemberSubclass : TNSDeclaredMemberBase
@end

@interface TNSType : NSObject

-(void)method;

@end

@interface TNSPseudoDataType: NSObject

+(id<Proto1, Proto2>)getId;
+(TNSType<Proto1, Proto2>*)getType;
+(id<TNSOptionalMemberProtocol>)getWithOptionalMember;
+(id<TNSOptionalMemberProtocol>)getWithoutOptionalMember;
+(id<TNSReadonlyValueProtocol>)getReadwriteValue;
+(id<TNSDeclaredMemberProtocol>)getDeclaredMemberSubclass;

@end
