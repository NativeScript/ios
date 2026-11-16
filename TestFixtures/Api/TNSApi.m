#import "TNSApi.h"

NSString* const TNSConstant = @"TNSConstant";

void functionThrowsException() {
  @throw [NSException exceptionWithName:NSGenericException reason:@"No reason" userInfo:nil];
}

@implementation TNSApi {
  int _property;
}

- (int)customGetter {
  return _property;
}
- (void)customSetter:(int)value {
  _property = value;
}

+ (void)methodThrowsException {
  @throw [NSException exceptionWithName:NSGenericException reason:@"No reason" userInfo:nil];
}

- (void)methodThrowsException {
  @throw [NSException exceptionWithName:NSGenericException reason:@"No reason" userInfo:nil];
}

- (void)methodCalledInDealloc {
  // TODO
  //    [TNSGetOutput() appendString:@"methodCalledInDealloc called"];
}

- (void)dealloc {
  [self methodCalledInDealloc];
}

- (BOOL)method:(NSInteger)errorCode error:(NSError**)outError {
  if (outError) {
    if (errorCode != 0) {
      *outError = [NSError errorWithDomain:@"TNSErrorDomain" code:errorCode userInfo:nil];
    } else {
      *outError = nil;
    }
  }
  return errorCode == 0;
}

- (BOOL)methodNullable:(NSInteger)errorCode error:(NSError* _Nullable* _Nullable)outError {
  if (outError) {
    if (errorCode != 0) {
      *outError = [NSError errorWithDomain:@"TNSErrorDomain" code:errorCode userInfo:nil];
    } else {
      *outError = nil;
    }
  }
  return errorCode == 0;
}

- (BOOL)methodTypedefNullable:(NSInteger)errorCode
                        error:(TNSNullableError _Nullable* _Nullable)outError {
  if (outError) {
    if (errorCode != 0) {
      *outError = [NSError errorWithDomain:@"TNSErrorDomain" code:errorCode userInfo:nil];
    } else {
      *outError = nil;
    }
  }
  return errorCode == 0;
}

@end

@implementation TNSConflictingSelectorTypes1
+ (void)method:(long long)x {
}
- (void)method:(long long)x {
}
@end

@implementation TNSConflictingSelectorTypes2
+ (id)method:(id)x {
  return nil;
}
- (id)method:(id)x {
  return nil;
}
@end

@implementation TNSSwizzleKlass
+ (int)staticMethod:(int)x {
  return x;
}
- (int)instanceMethod:(int)x {
  return x;
}
@end

@implementation TNSPropertyMethodConflictClass

@end

@implementation RectClass

- (CGRect)getRect {
  return CGRectMake(1, 2, 3, 4);
}

@end

@implementation TNSAccessorTypes
@end

@implementation TNSAccessorSwizzleBase
@end

@implementation TNSAccessorSwizzleDerived {
  double _derivedDouble;
  BOOL _derivedBool;
}
@dynamic doubleProperty, boolProperty;

- (void)setDoubleProperty:(double)value {
  _derivedDouble = value;
}

- (void)setBoolProperty:(BOOL)value {
  _derivedBool = value;
}

@end

@implementation TNSInheritedSwizzleBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSInheritedSwizzleDerived
@end

@implementation TNSInheritedSwizzleSubclass
@end

@implementation TNSInheritedSwizzleTwice
@end

@implementation TNSSwizzleChainBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSSwizzleChainDerived
@end

@implementation TNSSwizzleReverseBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSSwizzleReverseDerived
@end

@implementation TNSSwizzleRepeatBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSSwizzleRepeatDerived
@end

@implementation TNSSwizzleMiddleBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSSwizzleMiddle {
  id _middleObject;
  NSInteger _middleScalar;
}

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"middle %d", value];
}

- (id)objectValue {
  return [NSString stringWithFormat:@"middle %@", _middleObject];
}

- (void)setObjectValue:(id)value {
  _middleObject = [NSString stringWithFormat:@"%@ via middle", value];
}

- (NSInteger)scalarValue {
  return _middleScalar + 1000;
}

- (void)setScalarValue:(NSInteger)value {
  _middleScalar = value * 3;
}

@end

@implementation TNSSwizzleMiddleLeaf
@end

@implementation TNSSwizzleSuperBase

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"base %d", value];
}

- (id)storedObjectValue {
  return _objectValue;
}

- (NSInteger)storedScalarValue {
  return _scalarValue;
}

@end

@implementation TNSSwizzleSuperMiddle

- (id)describeValue:(int)value {
  return [NSString stringWithFormat:@"middle %@", [super describeValue:value]];
}

- (id)objectValue {
  return [NSString stringWithFormat:@"middle %@", [super objectValue]];
}

- (void)setObjectValue:(id)value {
  [super setObjectValue:[NSString stringWithFormat:@"%@ via middle", value]];
}

- (NSInteger)scalarValue {
  return [super scalarValue] + 1000;
}

- (void)setScalarValue:(NSInteger)value {
  [super setScalarValue:value * 3];
}

@end

@implementation TNSSwizzleSuperLeaf
@end

static TNSLinkedNode sharedLinkedNodes[2] = {{1, &sharedLinkedNodes[1]}, {2, NULL}};

@implementation TNSLinkedTypes

- (TNSLinkedNode*)nextOf:(TNSLinkedNode*)node {
  return node != NULL ? node->next : NULL;
}

- (TNSLinkedHolder)holderWithLeaf:(TNSLinkedLeaf*)leaf {
  return (TNSLinkedHolder){&sharedLinkedNodes[0], leaf, 1};
}

@end
