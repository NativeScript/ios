#include "ArrayAdapter.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Caches.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
    Isolate* isolate_;
    std::shared_ptr<Persistent<Value>> object_;
    std::shared_ptr<Caches> cache_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->cache_ = Caches::Get(isolate);
        self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
        self->cache_->Instances.emplace(self, self->object_);
        tns::SetValue(isolate, jsObject, new ObjCDataWrapper(self));
    }

    return self;
}

- (NSUInteger)count {
    v8::Locker locker(self->isolate_);
    Isolate::Scope isolate_scope(self->isolate_);
    HandleScope handle_scope(self->isolate_);

    Local<Object> object = self->object_->Get(self->isolate_).As<Object>();
    if (object->IsArray()) {
        uint32_t length = object.As<v8::Array>()->Length();
        return length;
    }

    Local<Context> context = self->cache_->GetContext();
    Local<v8::Array> propertyNames;
    bool success = object->GetPropertyNames(context).ToLocal(&propertyNames);
    tns::Assert(success, self->isolate_);
    uint32_t length = propertyNames->Length();
    return length;
}

- (id)objectAtIndex:(NSUInteger)index {
    v8::Locker locker(self->isolate_);
    Isolate::Scope isolate_scope(self->isolate_);
    HandleScope handle_scope(self->isolate_);

    if (!(index < [self count])) {
        tns::Assert(false, self->isolate_);
    }

    Local<Object> object = self->object_->Get(self->isolate_).As<Object>();
    Local<Context> context = self->cache_->GetContext();
    Local<Value> item;
    bool success = object->Get(context, (uint)index).ToLocal(&item);
    tns::Assert(success, self->isolate_);

    if (item->IsNullOrUndefined()) {
        return nil;
    }

    id value = Interop::ToObject(context, item);
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
    self->cache_->Instances.erase(self);
    Local<Value> value = self->object_->Get(self->isolate_);
    BaseDataWrapper* wrapper = tns::GetValue(self->isolate_, value);
    if (wrapper != nullptr) {
        tns::DeleteValue(self->isolate_, value);
        delete wrapper;
    }
    self->object_->Reset();
    [super dealloc];
}

@end
