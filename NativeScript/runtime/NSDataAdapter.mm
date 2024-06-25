#include "NSDataAdapter.h"
#include "Helpers.h"
#include "Caches.h"
#include "IsolateWrapper.h"

using namespace tns;
using namespace v8;

@implementation NSDataAdapter {
    IsolateWrapper* wrapper_;
    ObjCDataWrapper* dataWrapper_;
    std::shared_ptr<Persistent<Value>> object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        tns::Assert(jsObject->IsArrayBuffer() || jsObject->IsArrayBufferView(), isolate);
        self->wrapper_ = new IsolateWrapper(isolate);
        self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
        self->wrapper_->GetCache()->Instances.emplace(self, self->object_);
        tns::SetValue(isolate, jsObject, (dataWrapper_ = new ObjCDataWrapper(self)));
    }

    return self;
}

- (const void*)bytes {
    return [self mutableBytes];
}

- (void*)mutableBytes {
    if (!wrapper_->IsValid()) {
        return nil;
    }
    Isolate* isolate = wrapper_->Isolate();
    Local<Object> obj = self->object_->Get(isolate).As<Object>();
    if (obj->IsArrayBuffer()) {
        void* data = obj.As<ArrayBuffer>()->GetBackingStore()->Data();
        return data;
    }

    Local<ArrayBufferView> bufferView = obj.As<ArrayBufferView>();
    if (bufferView->HasBuffer()) {
        void* data = bufferView->Buffer()->GetBackingStore()->Data();
        return data;
    }

    size_t length = bufferView->ByteLength();
    void* data = malloc(length);
    bufferView->CopyContents(data, length);

    return data;
}

- (NSUInteger)length {
    if (!wrapper_->IsValid()) {
        return 0;
    }
    Isolate* isolate = wrapper_->Isolate();
    Local<Object> obj = self->object_->Get(isolate).As<Object>();
    if (obj->IsArrayBuffer()) {
        return obj.As<ArrayBuffer>()->ByteLength();
    }

    return obj.As<ArrayBufferView>()->ByteLength();
}

- (void)dealloc {
    if (wrapper_->IsValid()) {
        auto isolate = wrapper_->Isolate();
        v8::Locker locker(isolate);
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        wrapper_->GetCache()->Instances.erase(self);
        Local<Value> value = self->object_->Get(isolate);
        BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
        if (wrapper != nullptr) {
            tns::DeleteValue(isolate, value);
            // ensure we don't delete the same wrapper twice
            // this is just needed as a failsafe in case some other wrapper is assigned to this object
            if (wrapper == dataWrapper_) {
                dataWrapper_ = nullptr;
            }
            delete wrapper;
        }
        self->object_->Reset();
    }
    if (dataWrapper_ != nullptr) {
        delete dataWrapper_;
    }
    
    self->object_->Reset();
    delete self->wrapper_;
    self->object_ = nullptr;
    [super dealloc];
}

@end
