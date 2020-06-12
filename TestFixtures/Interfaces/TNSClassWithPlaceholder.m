#import "TNSClassWithPlaceholder.h"

@interface TNSClassWithPlaceholderReal : TNSClassWithPlaceholder

@end

@implementation TNSClassWithPlaceholderReal

- (NSString*)description {
    return @"real";
}

@end

@interface TNSClassWithPlaceholderPlaceholder : TNSClassWithPlaceholder

@end

@implementation TNSClassWithPlaceholderPlaceholder

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

- (TNSClassWithPlaceholder*)init {
    return (id)[[TNSClassWithPlaceholderReal alloc] init];
}

- (TNSClassWithPlaceholder*)testEmbeddedClass {
    return (id)[[TNSClassWithPlaceholderReal alloc] init];
}

#pragma clang diagnostic pop

- (instancetype)retain {
    TNSLog(@"retain on placeholder called");

    return [super retain];
}

- (oneway void)release {
    [super release];

    TNSLog(@"release on placeholder called");
}

@end

@implementation TNSClassWithPlaceholder

+ (instancetype)alloc {
    if (self == [TNSClassWithPlaceholder class]) {
        return [TNSClassWithPlaceholderPlaceholder alloc];
    }

    return [super alloc];
}

- (TNSClassWithPlaceholder*)testEmbeddedClass {
    return [TNSClassWithPlaceholderPlaceholder alloc];
}

@end
