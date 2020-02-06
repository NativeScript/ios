#include "NSDataAdapter.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Caches.h"

using namespace tns;
using namespace v8;

@implementation NSDataAdapter {
    Isolate* isolate_;
    std::shared_ptr<Persistent<Value>> object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        tns::Assert(jsObject->IsArrayBuffer() || jsObject->IsArrayBufferView(), isolate);
        self->isolate_ = isolate;
        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        Local<Context> context = cache->GetContext();
        self->object_ = ObjectManager::Register(context, jsObject);
        cache->Instances.emplace(self, self->object_);
        tns::SetValue(isolate, jsObject, new ObjCDataWrapper(self));
    }

    return self;
}

- (const void*)bytes {
    return [self mutableBytes];
}

- (void*)mutableBytes {
    Local<Object> obj = self->object_->Get(self->isolate_).As<Object>();
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
    Local<Object> obj = self->object_->Get(self->isolate_).As<Object>();
    if (obj->IsArrayBuffer()) {
        return obj.As<ArrayBuffer>()->ByteLength();
    }

    return obj.As<ArrayBufferView>()->ByteLength();
}

- (void)dealloc {
    self->object_->Reset();
}

@end
