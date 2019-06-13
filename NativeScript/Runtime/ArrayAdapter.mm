#import <Foundation/NSString.h>
#include "ArrayAdapter.h"
#include "DictionaryAdapter.h"
#include "DataWrapper.h"
#include "Helpers.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
    Isolate* isolate_;
    Persistent<Object>* object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->object_ = new Persistent<Object>(isolate, jsObject);
    }

    return self;
}

- (NSUInteger)count {
    Local<Object> object = self->object_->Get(self->isolate_);
    if (object->IsArray()) {
        uint32_t length = object.As<v8::Array>()->Length();
        return length;
    }

    Local<Context> context = self->isolate_->GetCurrentContext();
    Local<v8::Array> propertyNames;
    bool success = object->GetPropertyNames(context).ToLocal(&propertyNames);
    assert(success);
    uint32_t length = propertyNames->Length();
    return length;
}

- (id)objectAtIndex:(NSUInteger)index {
    if (!(index < [self count])) {
        assert(false);
    }

    Local<Object> object = self->object_->Get(self->isolate_);
    Local<Value> item = object->Get((uint)index);

    if (item->IsNullOrUndefined()) {
        return nil;
    }

    if (tns::IsString(item)) {
        std::string value = tns::ToString(self->isolate_, item);
        NSString* result = [NSString stringWithUTF8String:value.c_str()];
        return result;
    }

    if (tns::IsNumber(item)) {
        double value = tns::ToNumber(item);
        return @(value);
    }

    if (tns::IsBool(item)) {
        bool value = tns::ToBool(item);
        return @(value);
    }

    if (item->IsArray()) {
        ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:item.As<v8::Array>() isolate:self->isolate_];
        return adapter;
    }

    if (item->IsObject()) {
        Local<Object> obj = item.As<Object>();

        if (BaseDataWrapper* wrapper = tns::GetValue(self->isolate_, obj)) {
            switch (wrapper->Type()) {
                case WrapperType::ObjCObject: {
                    ObjCDataWrapper* wr = static_cast<ObjCDataWrapper*>(wrapper);
                    return wr->Data();
                    break;
                }
                case WrapperType::ObjCClass: {
                    ObjCClassWrapper* wr = static_cast<ObjCClassWrapper*>(wrapper);
                    return wr->Klass();
                    break;
                }
                case WrapperType::ObjCProtocol: {
                    ObjCProtocolWrapper* wr = static_cast<ObjCProtocolWrapper*>(wrapper);
                    return wr->Proto();
                    break;
                }
                default:
                    // TODO: Unsupported object type
                    assert(false);
                    break;
            }
        } else {
            DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:item.As<Object>() isolate:self->isolate_];
            return adapter;
        }
    }

    // TODO: Handle other possible types
    assert(false);
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained _Nullable [_Nonnull])buffer count:(NSUInteger)len {
    if (state->state == 0) { // uninitialized
        state->state = 1;
        void* selfPtr = (__bridge void*)self;
        state->mutationsPtr = (unsigned long*)selfPtr;
        state->extra[0] = 0; // current index
        NSUInteger cnt = [self count];
        state->extra[1] = cnt;
    }

    NSUInteger currentIndex = state->extra[0];
    unsigned long length = state->extra[1];
    NSUInteger count = 0;
    state->itemsPtr = buffer;

    @autoreleasepool {
        while (count < len && currentIndex < length) {
            id obj = [self objectAtIndex:currentIndex];
            CFBridgingRetain(obj);
            *buffer++ = obj;
            currentIndex++;
            count++;
        }
    }

    state->extra[0] = currentIndex;

    return count;

}

- (void)dealloc {
    self->object_->Reset();
}

@end
