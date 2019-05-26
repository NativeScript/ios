#import <Foundation/NSString.h>
#import "ArrayAdapter.h"
#include "Helpers.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
    Isolate* isolate_;
    Persistent<v8::Array>* object_;
}

- (instancetype)initWithJSObject:(Local<v8::Array>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->object_ = new Persistent<v8::Array>(isolate, jsObject);
    }

    return self;
}

- (NSUInteger)count {
    return self->object_->Get(self->isolate_)->Length();
}

- (id)objectAtIndex:(NSUInteger)index {
    if (!(index < [self count])) {
        assert(false);
    }

    Local<v8::Array> array = self->object_->Get(self->isolate_);
    Local<Value> item = array->Get((uint)index);
    if (item->IsNullOrUndefined()) {
        return nil;
    }

    assert(item->IsString());

    std::string value = tns::ToString(self->isolate_, item);
    NSString* result = [NSString stringWithUTF8String:value.c_str()];

    return result;
}

- (void)dealloc {
    self->object_->Reset();
}

@end
