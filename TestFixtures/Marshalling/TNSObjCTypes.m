#import "TNSObjCTypes.h"

void TNSFunctionWithCFTypeRefArgument(CFTypeRef x) {
    NSString* str = (__bridge NSString*)x;
    TNSLog([NSString stringWithFormat:@"%@", str]);
}

CFTypeRef TNSFunctionWithSimpleCFTypeRefReturn() {
    return CFSTR("test");
}

CFTypeRef TNSFunctionWithCreateCFTypeRefReturn() {
    return CFStringCreateWithCString(kCFAllocatorDefault, "test", kCFStringEncodingUTF8);
}

@implementation TNSObjCTypes
+ (void)methodWithComplexBlock:(id (^)(int, id, SEL, NSObject*, TNSOStruct))block {
    TNSOStruct str = { 5, 6, 7 };
    id result = block(1, @2, @selector(init), @[@3, @4], str);
    TNSLog([NSString stringWithFormat:@"\n%@", NSStringFromClass([result class])]);
}

+ (id)methodWithObject:(id)x {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    NSDictionary* result = [x performSelector:@selector(getData)];
#pragma clang diagnostic pop
    TNSLog([NSString stringWithFormat:@"%s %d", [(NSString*)result[@"a"] UTF8String], [(NSNumber*)result[@"b"] intValue]]);
    return x;
}

- (void)methodWithIdOutParameter:(NSString**)value {
    TNSLog([NSString stringWithFormat:@"%@", *value]);
    *value = @"test";
}

- (void)methodWithLongLongOutParameter:(long long*)value {
    TNSLog([NSString stringWithFormat:@"%lld", *value]);
    *value = 1;
}

- (void)methodWithStructOutParameter:(TNSOStruct*)value {
    TNSLog([NSString stringWithFormat:@"%d %d %d", value->x, value->y, value->z]);
    *value = (TNSOStruct){ 4, 5, 6 };
}

- (void)methodWithSimpleBlock:(void (^)(void))block {
    block();
}

- (void)methodWithComplexBlock:(id (^)(int, id, SEL, NSObject*, TNSOStruct))block {
    TNSOStruct str = { 5, 6, 7 };
    id result = block(1, @2, @selector(init), @[@3, @4], str);
    TNSLog([NSString stringWithFormat:@"\n%@", NSStringFromClass([result class])]);
}

- (NumberReturner)methodWithBlockScope:(int)number {
    return ^(int a, int b, int c) {
      return (number + a + b + c);
    };
}

- (id)methodReturningBlockAsId:(int)number {
    return ^(int a, int b, int c) {
      return (number + a + b + c);
    };
}

- (NSDate*)methodWithNSDate:(NSDate*)date {
    TNSLog(date.description);
    return date;
}

- (void (^)(void))methodWithBlock:(void (^)(void))block {
    if (block) {
        block();
    }
    return block;
}

- (NSArray*)methodWithNSArray:(NSArray*)array {
    for (id x in array) {
        TNSLog([NSString stringWithFormat:@"%@", x]);
    }
    return array;
}

- (id)methodWithNSArrayWrappingDictionary:(id)array {
    NSArray* arr = (NSArray*)array;
    id result = [arr objectAtIndex:0];
    return result;
}

- (NSDictionary*)methodWithNSDictionary:(NSDictionary*)dictionary {
    for (id x in dictionary) {
        TNSLog([NSString stringWithFormat:@"%@ %@", x, dictionary[x]]);
    }

    return dictionary;
}

- (NSData*)methodWithNSData:(NSData*)data {
    NSString* string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    TNSLog(string);
    return data;
}

- (NSDecimalNumber*)methodWithNSDecimalNumber:(NSDecimalNumber*)number {
    TNSLog([number stringValue]);
    return number;
}

- (NSNumber*)methodWithNSCFBool {
    return @YES;
}

- (NSNull*)methodWithNSNull {
    return [NSNull null];
}

@end
