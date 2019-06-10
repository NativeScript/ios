#include "NSDataAdapter.h"

using namespace v8;

@implementation NSDataAdapter {
    Isolate* isolate_;
    Persistent<Object>* object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        assert(jsObject->IsArrayBuffer() || jsObject->IsArrayBufferView());
        self->isolate_ = isolate;
        self->object_ = new Persistent<Object>(isolate, jsObject);
    }

    return self;
}

- (const void*)bytes {
    return [self mutableBytes];
}

- (void*)mutableBytes {
    Local<Object> obj = self->object_->Get(self->isolate_);
    if (obj->IsArrayBuffer()) {
        void* data = obj.As<ArrayBuffer>()->GetContents().Data();
        return data;
    }

    Local<ArrayBufferView> bufferView = obj.As<ArrayBufferView>();
    if (bufferView->HasBuffer()) {
        void* data = bufferView->Buffer()->GetContents().Data();
        return data;
    }

    size_t length = bufferView->ByteLength();
    void* data = malloc(length);
    bufferView->CopyContents(data, length);

    return data;
}

- (NSUInteger)length {
    Local<Object> obj = self->object_->Get(self->isolate_);
    if (obj->IsArrayBuffer()) {
        return obj.As<ArrayBuffer>()->ByteLength();
    }

    return obj.As<ArrayBufferView>()->ByteLength();
}

- (void)dealloc {
    self->object_->Reset();
}

@end
