#import <simd/simd.h>

typedef NS_ENUM(NSInteger, TNSEnums) {
  TNSEnum1 = -1,
  TNSEnum2,
  TNSEnum3,
};

typedef NS_OPTIONS(NSInteger, TNSOptions) {
  TNSOption1 = 1 << 0,
  TNSOption2 = 1 << 1,
  TNSOption3 = 1 << 2,
};

enum { AnonymousEnumField = -1 };

extern NSString* const TNSConstant;

extern NSString* const TNSUnavailableConstant;

static const NSInteger TNSStaticConstant = -42;

void functionThrowsException();

@interface TNSApi : NSObject

@property(getter=customGetter, setter=customSetter:) int property;

typedef UIColor NIKColor;
@property(strong, nonatomic) NIKColor* strokeColor;  // ^{UIColor=#}

+ (void)methodThrowsException;
- (void)methodThrowsException;

- (void)methodCalledInDealloc;

- (BOOL)method:(NSInteger)errorCode error:(NSError**)outError;
- (BOOL)methodNullable:(NSInteger)errorCode error:(NSError* _Nullable* _Nullable)outError;

// The typedef carries its own nullability, so the parameter type ends up with
// nested nullability annotations (like BNNSFilterCreateLayerPadding in the SDK)
typedef NSError* _Nullable TNSNullableError;
- (BOOL)methodTypedefNullable:(NSInteger)errorCode
                        error:(TNSNullableError _Nullable* _Nullable)outError;
@end

@interface TNSConflictingSelectorTypes1 : NSObject
+ (void)method:(long long)x;
- (void)method:(long long)x;
@end

@interface TNSConflictingSelectorTypes2 : NSObject
+ (id)method:(id)x;
- (id)method:(id)x;
@end

@interface TNSSwizzleKlass : NSObject
@property(assign) int aProperty;
+ (int)staticMethod:(int)x;
- (int)instanceMethod:(int)x;
@end

@protocol TNSPropertyMethodConflictProtocol
- (BOOL)conflict;
@end

@interface TNSPropertyMethodConflictClass : NSObject <TNSPropertyMethodConflictProtocol>
@property BOOL conflict;
@end

@protocol TNSUnusedProtocol
- (void)someMethod:(int)a;
@end

@protocol RectProtocol
@optional
- (CGRect)getRect;
@end

@interface RectClass : NSObject <RectProtocol>
@end

@interface TNSAccessorTypes : NSObject
@property(nonatomic) BOOL boolProperty;
@property(nonatomic) NSUInteger unsignedProperty;
@property(nonatomic) NSInteger integerProperty;
@property(nonatomic) short shortProperty;
@property(nonatomic) unichar unicharProperty;
@property(nonatomic) char charProperty;
@property(nonatomic) unsigned char unsignedCharProperty;
@property(nonatomic) long long longLongProperty;
@property(nonatomic) float floatProperty;
@property(nonatomic) double doubleProperty;
@property(nonatomic) CGRect rectProperty;
@property(nonatomic) CGPoint pointProperty;
@property(nonatomic) SEL selectorProperty;
@property(nonatomic, strong) Class classProperty;
@property(nonatomic, copy) void (^blockProperty)(void);
@property(nonatomic) void* pointerProperty;
@property(nonatomic) int (*functionPointerProperty)(int);
@property(nonatomic) simd_float4 vectorProperty;
@property(nonatomic, copy) NSString* objectProperty;
@property(nonatomic, strong) id<NSCopying> protocolObjectProperty;
@end

@interface TNSAccessorSwizzleBase : NSObject
@property(nonatomic, readonly) double doubleProperty;
@property(nonatomic, readonly) BOOL boolProperty;
@end

// Readwrite redeclarations keep these properties in this class's metadata,
// while their getters stay implemented by the superclass only.
@interface TNSAccessorSwizzleDerived : TNSAccessorSwizzleBase
@property(nonatomic, readwrite) double doubleProperty;
@property(nonatomic, readwrite) BOOL boolProperty;
@end

@interface TNSInheritedSwizzleBase : NSObject
@property(nonatomic, strong) id objectValue;
@property(nonatomic) NSInteger scalarValue;
- (id)describeValue:(int)value;
- (id)storedObjectValue;
- (NSInteger)storedScalarValue;
@end

@interface TNSInheritedSwizzleDerived : TNSInheritedSwizzleBase
@end

// Compatible redeclarations with other types keep these members in this
// class's metadata, while only the superclass implements them.
@interface TNSInheritedSwizzleDerived (Redeclared)
@property(nonatomic, strong) NSString* objectValue;
@property(nonatomic) TNSEnums scalarValue;
- (NSString*)describeValue:(int)value;
@end

@interface TNSInheritedSwizzleSubclass : TNSInheritedSwizzleDerived
@end

@interface TNSInheritedSwizzleTwice : TNSInheritedSwizzleBase
@end

@interface TNSInheritedSwizzleTwice (Redeclared)
@property(nonatomic) TNSEnums scalarValue;
@end

typedef struct TNSLinkedNode {
  int value;
  struct TNSLinkedNode* next;
} TNSLinkedNode;

typedef struct TNSLinkedLeaf {
  int value;
} TNSLinkedLeaf;

typedef struct TNSLinkedHolder {
  TNSLinkedNode* node;
  TNSLinkedLeaf* leaf;
  int count;
} TNSLinkedHolder;

@interface TNSLinkedTypes : NSObject
@property(nonatomic) TNSLinkedNode* nodeProperty;
@property(nonatomic) TNSLinkedHolder holderProperty;
@property(nonatomic) TNSLinkedLeaf* leafProperty;
- (TNSLinkedNode*)nextOf:(TNSLinkedNode*)node;
- (TNSLinkedHolder)holderWithLeaf:(TNSLinkedLeaf*)leaf;
@end
