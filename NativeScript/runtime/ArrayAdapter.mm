#include "ArrayAdapter.h"
#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Caches.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
    Isolate* isolate_;
    std::shared_ptr<Persistent<Value>> object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->object_ = ObjectManager::Register(isolate, jsObject);
        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        cache->Instances.emplace(self, self->object_);
        tns::SetValue(isolate, jsObject, new ObjCDataWrapper(self));
    }

    return self;
}

- (NSUInteger)count {
    Local<Object> object = self->object_->Get(self->isolate_).As<Object>();
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

    Local<Object> object = self->object_->Get(self->isolate_).As<Object>();
    Local<Context> context = self->isolate_->GetCurrentContext();
    Local<Value> item;
    bool success = object->Get(context, (uint)index).ToLocal(&item);
    assert(success);

    if (item->IsNullOrUndefined()) {
        return nil;
    }

    id value = Interop::ToObject(self->isolate_, item);
    return value;
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
