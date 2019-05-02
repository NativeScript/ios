#import <FOundation/NSString.h>
#import "ArrayAdapter.h"
#include "Helpers.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
    Isolate* isolate_;
    Local<v8::Array> object_;
}

- (instancetype)initWithJSObject:(Local<v8::Array>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->object_ = jsObject;
    }

    return self;
}

- (NSUInteger)count {
    return self->object_->Length();
}

- (id)objectAtIndex:(NSUInteger)index {
    if (!(index < [self count])) {
        assert(false);
    }

    Local<Value> item = self->object_->Get((uint)index);
    if (item->IsNullOrUndefined()) {
        return nil;
    }

    assert(item->IsString());

    std::string value = tns::ToString(self->isolate_, item);
    NSString* result = [NSString stringWithUTF8String:value.c_str()];

    return result;
}

- (void)dealloc {
    NSLog(@"Destroying the instance");
}

@end
