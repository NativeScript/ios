#include "NSDataAdapter.h"
#include "Caches.h"
#include "Helpers.h"
#include "IsolateWrapper.h"

using namespace tns;
using namespace v8;

@implementation NSDataAdapter {
  IsolateWrapper* wrapper_;
  // The wrapper this adapter attached to the JS object, or nullptr when the
  // field was already taken. Ownership lives with the field, not with this
  // pointer: it is only the claim used to recognise our own wrapper there.
  ObjCDataWrapper* dataWrapper_;
  std::shared_ptr<Persistent<Value>> object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
  if (self) {
    tns::Assert(jsObject->IsArrayBuffer() || jsObject->IsArrayBufferView() ||
                    jsObject->IsSharedArrayBuffer(),
                isolate);
    self->wrapper_ = new IsolateWrapper(isolate);
    self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
    self->wrapper_->GetCache()->Instances[self] = self->object_;
    // A JS object's internal field holds at most one wrapper, owned by whoever
    // attached it first. An adapter that finds the field taken stays detached
    // and never writes or clears it; it still reads the object through object_.
    if (tns::GetValue(isolate, jsObject) == nullptr) {
      self->dataWrapper_ = new ObjCDataWrapper(self);
      tns::SetValue(isolate, jsObject, self->dataWrapper_);
    }
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

  if (obj->IsSharedArrayBuffer()) {
    void* data = obj.As<SharedArrayBuffer>()->GetBackingStore()->Data();
    return data;
  }

  Local<ArrayBufferView> bufferView = obj.As<ArrayBufferView>();
  if (bufferView->HasBuffer()) {
    uint8_t* data = static_cast<uint8_t*>(bufferView->Buffer()->GetBackingStore()->Data());
    if (data == nullptr) {
      return nullptr;
    }

    return data + bufferView->ByteOffset();
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

  if (obj->IsSharedArrayBuffer()) {
    return obj.As<SharedArrayBuffer>()->ByteLength();
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
    // Detach and free only a wrapper that is still the one we attached: a
    // finalizer or __releaseNativeCounterpart can have retired it already, and
    // whatever else sits in the field belongs to another owner. Once the
    // isolate is gone the field can no longer be read, so the claim is dropped
    // rather than freed blind.
    if (dataWrapper_ != nullptr) {
      Local<Value> value = self->object_->Get(isolate);
      if (tns::GetValue(isolate, value) == dataWrapper_) {
        tns::DeleteValue(isolate, value);
        delete dataWrapper_;
      }
      dataWrapper_ = nullptr;
    }
    self->object_->Reset();
  }

  delete self->wrapper_;
  self->object_ = nullptr;
  [super dealloc];
}

@end
