#include "DictionaryAdapter.h"
#import <Foundation/NSString.h>
#include "ArgConverter.h"
#include "Caches.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "IsolateWrapper.h"

using namespace v8;
using namespace tns;

@interface DictionaryAdapterMapKeysEnumerator : NSEnumerator

- (instancetype)initWithMap:(std::shared_ptr<Persistent<Value>>)map
                    isolate:(Isolate*)isolate
                      owner:(id)owner;

@end

@implementation DictionaryAdapterMapKeysEnumerator {
  IsolateWrapper* wrapper_;
  uint32_t index_;
  std::shared_ptr<Persistent<Value>> map_;
  // The adapter owns the persistent this enumerator reads and resets it in
  // -dealloc, so an enumeration keeps its adapter alive.
  id owner_;
}

- (instancetype)initWithMap:(std::shared_ptr<Persistent<Value>>)map
                    isolate:(Isolate*)isolate
                      owner:(id)owner {
  if (self) {
    self->wrapper_ = new IsolateWrapper(isolate);
    self->index_ = 0;
    self->map_ = map;
    self->owner_ = [owner retain];
  }

  return self;
}

- (id)nextObject {
  if (!wrapper_->IsValid()) {
    return nil;
  }
  Isolate* isolate = wrapper_->Isolate();
  NSString* result = nil;
  // Scopes-before-@throw: keep V8 scopes in an inner block so a branded escape
  // is @thrown only after they destruct.
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> array = self->map_->Get(isolate).As<Map>()->AsArray();

    if (self->index_ < array->Length() - 1) {
      Local<Value> key;
      TryCatch tc(isolate);
      if (array->Get(context, self->index_).ToLocal(&key)) {
        self->index_ += 2;
        result = tns::ToNSString(isolate, key);
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

- (void)dealloc {
  self->map_ = nil;
  delete self->wrapper_;
  [self->owner_ release];
  self->owner_ = nil;

  [super dealloc];
}

@end

@interface DictionaryAdapterObjectKeysEnumerator : NSEnumerator

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary
                           isolate:(Isolate*)isolate
                             owner:(id)owner;
- (Local<v8::Array>)getProperties;

@end

@implementation DictionaryAdapterObjectKeysEnumerator {
  IsolateWrapper* wrapper_;
  std::shared_ptr<Persistent<Value>> dictionary_;
  NSUInteger index_;
  // The adapter owns the persistent this enumerator reads and resets it in
  // -dealloc, so an enumeration keeps its adapter alive.
  id owner_;
}

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary
                           isolate:(Isolate*)isolate
                             owner:(id)owner {
  if (self) {
    self->wrapper_ = new IsolateWrapper(isolate);
    self->dictionary_ = dictionary;
    self->index_ = 0;
    self->owner_ = [owner retain];
  }

  return self;
}

- (Local<v8::Array>)getProperties {
  Isolate* isolate = wrapper_->Isolate();
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  EscapableHandleScope handle_scope(isolate);

  Local<Context> context = wrapper_->GetCache()->GetContext();
  Local<v8::Array> properties;
  Local<Object> dictionary = self->dictionary_->Get(isolate).As<Object>();
  TryCatch tc(isolate);
  if (!dictionary->GetOwnPropertyNames(context).ToLocal(&properties)) {
    // This helper runs under the caller's V8 scopes and returns a Local, so a
    // branded escape cannot be safely @thrown from here. Report through the
    // uncaught path and return an empty array; the caller yields its default.
    ArgConverter::HandleBoundaryException(context, tc);
    properties = v8::Array::New(isolate, 0);
  }
  return handle_scope.Escape(properties);
}

- (id)nextObject {
  if (!wrapper_->IsValid()) {
    return nil;
  }
  Isolate* isolate = wrapper_->Isolate();
  NSString* result = nil;
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> properties = [self getProperties];
    if (self->index_ < properties->Length()) {
      Local<Value> value;
      TryCatch tc(isolate);
      if (properties->Get(context, (uint)self->index_).ToLocal(&value)) {
        self->index_++;
        result = tns::ToNSString(isolate, value);
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

- (NSArray*)allObjects {
  if (!wrapper_->IsValid()) {
    return nil;
  }
  Isolate* isolate = wrapper_->Isolate();
  NSMutableArray* array = [NSMutableArray array];
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> properties = [self getProperties];
    for (int i = 0; i < properties->Length(); i++) {
      Local<Value> value;
      TryCatch tc(isolate);
      if (!properties->Get(context, i).ToLocal(&value)) {
        NSException* ex = ArgConverter::HandleBoundaryException(context, tc);
        if (ex != nil) {
          pendingThrow = ex;
        }
        break;
      }
      [array addObject:tns::ToNSString(isolate, value)];
    }
  }
  if (pendingThrow != nil) {
    @throw pendingThrow;
  }
  return array;
}

- (void)dealloc {
  self->dictionary_ = nil;
  delete self->wrapper_;
  [self->owner_ release];
  self->owner_ = nil;

  [super dealloc];
}

@end

@implementation DictionaryAdapter {
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
  if (!wrapper_->IsValid()) {
    return 0;
  }
  Isolate* isolate = wrapper_->Isolate();
  NSUInteger result = 0;
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Object> obj = self->object_->Get(isolate).As<Object>();

    if (obj->IsMap()) {
      result = obj.As<Map>()->Size();
    } else {
      Local<Context> context = wrapper_->GetCache()->GetContext();
      Local<v8::Array> properties;
      TryCatch tc(isolate);
      if (obj->GetOwnPropertyNames(context).ToLocal(&properties)) {
        result = properties->Length();
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

- (id)objectForKey:(id)aKey {
  if (!wrapper_->IsValid()) {
    return nil;
  }
  Isolate* isolate = wrapper_->Isolate();
  id result = nil;
  NSException* __strong pendingThrow = nil;
  {
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<Object> obj = self->object_->Get(isolate).As<Object>();

    Local<Value> value;
    bool got = false;
    TryCatch tc(isolate);
    if ([aKey isKindOfClass:[NSNumber class]]) {
      unsigned int key = [aKey unsignedIntValue];
      got = obj->Get(context, key).ToLocal(&value);
    } else if ([aKey isKindOfClass:[NSString class]]) {
      NSString* key = (NSString*)aKey;
      Local<v8::String> keyV8Str = tns::ToV8String(isolate, key);

      if (obj->IsMap()) {
        Local<Map> map = obj.As<Map>();
        got = map->Get(context, keyV8Str).ToLocal(&value);
      } else {
        got = obj->Get(context, keyV8Str).ToLocal(&value);
      }
    } else {
      // Unsupported key type: return the adapter default rather than aborting.
      got = false;
    }

    if (got) {
      result = Interop::ToObject(context, value);
    } else if (tc.HasCaught()) {
      NSException* ex = ArgConverter::HandleBoundaryException(context, tc);
      if (ex != nil) {
        pendingThrow = ex;
      }
    }
  }
  if (pendingThrow != nil) {
    @throw pendingThrow;
  }
  return result;
}

- (NSEnumerator*)keyEnumerator {
  if (!wrapper_->IsValid()) {
    return nil;
  }
  Isolate* isolate = wrapper_->Isolate();
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);

  Local<Value> obj = self->object_->Get(isolate);

  if (obj->IsMap()) {
    return [[[DictionaryAdapterMapKeysEnumerator alloc] initWithMap:self->object_
                                                            isolate:isolate
                                                              owner:self] autorelease];
  }

  return [[[DictionaryAdapterObjectKeysEnumerator alloc] initWithProperties:self->object_
                                                                    isolate:isolate
                                                                      owner:self] autorelease];
}

- (void)dealloc {
  if (wrapper_->IsValid()) {
    Isolate* isolate = wrapper_->Isolate();
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
    // Persistent<Value> does not reset in its destructor; the enumerators
    // vended by -keyEnumerator hold this adapter alive, so nothing can be
    // reading the handle by the time this runs.
    self->object_->Reset();
  }
  self->object_ = nullptr;
  delete self->wrapper_;

  [super dealloc];
}

@end
