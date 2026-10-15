typedef struct TNSCStructure {
    int x;
    int y;
} TNSCStructure;

@protocol TNSCProtocol
// Ensure we have unimplemented methods before and after
// the implemented ones (in alphabetical order)
@optional
- (id)initAWithIntNotImplemented:(int)x andInt:(int)y andInt:(int)z;

@required
- (id)initWithInt:(int)x andInt:(int)y;

@optional
- (id)initWithStringOptional:(NSString*)x andString:(NSString*)y;
- (id)initZWithIntNotImplemented:(int)x andInt:(int)y andInt:(int)z;
@end

@interface TNSCInterface : NSObject <TNSCProtocol>
- (id)initWithEmpty;
- (id)initWithPrimitive:(int)x;
- (id)initWithStructure:(TNSCStructure)x;
- (id)initWithString:(NSString*)x;
- (id)initWithParameter1:(NSString*)x parameter2:(NSString*)y error:(NSError**)error;
@end

@interface TNSTestObject : NSObject
- (id)initWithURL:(NSURL*)x;
@end

// Instances come only from a factory that runs an initializer this header does not declare, so
// the metadata never lists it (the shape of +[UIButton buttonWithType:]).
@interface TNSPrivateInitializerObject : NSObject
+ (instancetype)createPrivately;
@property(readonly) BOOL initializedPrivately;
@end

@interface TNSRaisingInitializerObject : NSObject
// Raises an NSException named TNSInitializerException.
- (instancetype)initRaising;
@end
