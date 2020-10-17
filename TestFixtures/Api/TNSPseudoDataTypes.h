#import <Foundation/Foundation.h>

@protocol Proto1

@property (nonatomic) NSString* propertyFromProto1;
-(void)methodFromProto1;

@end

@protocol Proto2

@property (nonatomic) NSString* propertyFromProto2;
-(void)methodFromProto2:(NSString*)param;

@end

@interface TNSType : NSObject

-(void)method;

@end

@interface TNSPseudoDataType: NSObject

+(id<Proto1, Proto2>)getId;
+(TNSType<Proto1, Proto2>*)getType;

@end
