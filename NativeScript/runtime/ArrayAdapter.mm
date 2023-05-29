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
        auto p = MakeGarbageCollected<ObjCDataWrapper>(isolate, self);
        tns::SetValue(isolate, jsObject, p);
        return self;
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

- (void)dealloc {
    self->cache_->Instances.erase(self);
    Local<Value> value = self->object_->Get(self->isolate_);
    BaseDataWrapper* wrapper = tns::GetValue(self->isolate_, value);
    if (wrapper != nullptr) {
        tns::DeleteValue(self->isolate_, value);
        delete wrapper;
    }
    self->object_->Reset();
    self->isolate_ = nullptr;
    self->cache_ = nullptr;
    self->object_ = nullptr;
    [super dealloc];
}

@end
