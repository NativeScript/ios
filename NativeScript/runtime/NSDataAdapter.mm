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
  // Pins the bytes for the adapter's lifetime, which is the NSData contract
  // native callers rely on. The persistent above pins only the JS OBJECT: a
  // postMessage transfer detaches it and hands the store to another isolate,
  // whose GC can free the memory while native code still holds this NSData —
  // an async reader/writer then touches a freed, recycled chunk.
  std::shared_ptr<v8::BackingStore> store_;
  // View byte offset into store_, captured with it (immutable for a view).
  size_t storeOffset_;
  // Byte length snapshotted with the store. NSData is immutable — its length
  // must not change for the object's lifetime — and the live ByteLength()
  // reads zero after a transfer detach while the pinned bytes stay valid.
  size_t length_;
  // Stable copy for a view whose buffer was never materialized, built during
  // init while the isolate is owned and the view alive — -bytes may run on
  // threads that cannot touch V8. Owned here, freed in dealloc.
  void* heapCopy_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
  if (self) {
    tns::Assert(jsObject->IsArrayBuffer() || jsObject->IsArrayBufferView() ||
                    jsObject->IsSharedArrayBuffer(),
                isolate);
    self->wrapper_ = new IsolateWrapper(isolate);
    self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
    self->wrapper_->GetCache()->Instances[self] = self->object_;
    self->storeOffset_ = 0;
    self->heapCopy_ = nullptr;
    if (jsObject->IsArrayBuffer()) {
      Local<ArrayBuffer> buffer = jsObject.As<ArrayBuffer>();
      self->store_ = buffer->GetBackingStore();
      self->length_ = buffer->ByteLength();
    } else if (jsObject->IsSharedArrayBuffer()) {
      Local<SharedArrayBuffer> buffer = jsObject.As<SharedArrayBuffer>();
      self->store_ = buffer->GetBackingStore();
      self->length_ = buffer->ByteLength();
    } else {
      Local<ArrayBufferView> view = jsObject.As<ArrayBufferView>();
      self->length_ = view->ByteLength();
      if (view->HasBuffer()) {
        self->store_ = view->Buffer()->GetBackingStore();
        self->storeOffset_ = view->ByteOffset();
      } else {
        self->heapCopy_ = malloc(self->length_);
        if (self->heapCopy_ != nullptr) {
          view->CopyContents(self->heapCopy_, self->length_);
        } else {
          self->length_ = 0;
        }
      }
    }
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
  // Every branch answers from native storage captured at init, so callers on
  // foreign threads never need isolate access (the old per-call
  // GetBackingStore() lookup ran unlocked from any thread).
  if (store_ != nullptr) {
    void* data = store_->Data();
    if (data == nullptr) {
      return nullptr;
    }
    return static_cast<uint8_t*>(data) + storeOffset_;
  }
  return heapCopy_;
}

- (NSUInteger)length {
  return length_;
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
  } else if (dataWrapper_ != nullptr) {
    // The isolate is gone, and with it the JS object and every other reader
    // or deleter of the claim (all IsValid-gated): an attached claim only
    // ever exists on a plain, never-registered object no finalizer visits,
    // so the owner frees it here — adapters released after a worker isolate's
    // teardown otherwise leak one wrapper each.
    delete dataWrapper_;
    dataWrapper_ = nullptr;
  }

  delete self->wrapper_;
  self->object_ = nullptr;
  free(self->heapCopy_);
  self->heapCopy_ = nullptr;
  [super dealloc];
}

@end
