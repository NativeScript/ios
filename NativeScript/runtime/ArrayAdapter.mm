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
  // we're responsible for this wrapper
  ObjCDataWrapper* dataWrapper_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
  if (self) {
    self->wrapper_ = new IsolateWrapper(isolate);
    self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
    self->wrapper_->GetCache()->Instances.emplace(self, self->object_);
    tns::SetValue(isolate, jsObject, (self->dataWrapper_ = new ObjCDataWrapper(self)));
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
  delete wrapper_;
  if (dataWrapper_ != nullptr) {
    delete dataWrapper_;
  }
  self->object_ = nullptr;
  [super dealloc];
}

@end
