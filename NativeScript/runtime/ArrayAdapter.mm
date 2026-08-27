#include "ArrayAdapter.h"
#include "ArgConverter.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "IsolateWrapper.h"

using namespace tns;
using namespace v8;

@implementation ArrayAdapter {
  IsolateWrapper* wrapper_;
  std::shared_ptr<Persistent<Value>> object_;
  // The wrapper this adapter attached to the JS object, or nullptr when the
  // field was already taken. Ownership lives with the field, not with this
  // pointer: it is only the claim used to recognise our own wrapper there.
  ObjCDataWrapper* dataWrapper_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
  if (self) {
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

- (NSUInteger)count {
  auto isolate = wrapper_->Isolate();
  if (!wrapper_->IsValid()) {
    return 0;
  }
  NSUInteger result = 0;
  // Scopes-before-@throw: a branded escape from the JS boundary is @thrown only
  // after the inner block's V8 scopes destruct.
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Object> object = self->object_->Get(isolate).As<Object>();
    if (object->IsArray()) {
      result = object.As<v8::Array>()->Length();
    } else {
      Local<Context> context = wrapper_->GetCache()->GetContext();
      Local<v8::Array> propertyNames;
      TryCatch tc(isolate);
      if (object->GetPropertyNames(context).ToLocal(&propertyNames)) {
        result = propertyNames->Length();
      } else {
        NSException* ex = ArgConverter::HandleBoundaryException(context, tc);
        if (ex != nil) {
          pendingThrow = ex;
        }
      }
    }
  }
  if (pendingThrow != nil) {
    @throw pendingThrow;
  }
  return result;
}

- (id)objectAtIndex:(NSUInteger)index {
  auto isolate = wrapper_->Isolate();
  if (!wrapper_->IsValid()) {
    return nil;
  }

  if (!(index < [self count])) {
    // Out of bounds: return the adapter default rather than aborting.
    return nil;
  }

  id result = nil;
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Object> object = self->object_->Get(isolate).As<Object>();
    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<Value> item;
    TryCatch tc(isolate);
    if (!object->Get(context, (uint)index).ToLocal(&item)) {
      NSException* ex = ArgConverter::HandleBoundaryException(context, tc);
      if (ex != nil) {
        pendingThrow = ex;
      }
    } else if (!item->IsNullOrUndefined()) {
      result = Interop::ToObject(context, item);
    }
  }
  if (pendingThrow != nil) {
    @throw pendingThrow;
  }
  return result;
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
  delete wrapper_;
  self->object_ = nullptr;
  [super dealloc];
}

@end
