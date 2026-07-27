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
                      cache:(std::shared_ptr<Caches>)cache;

@end

@implementation DictionaryAdapterMapKeysEnumerator {
  IsolateWrapper* wrapper_;
  uint32_t index_;
  std::shared_ptr<Persistent<Value>> map_;
}

- (instancetype)initWithMap:(std::shared_ptr<Persistent<Value>>)map
                    isolate:(Isolate*)isolate
                      cache:(std::shared_ptr<Caches>)cache {
  if (self) {
    self->wrapper_ = new IsolateWrapper(isolate);
    self->index_ = 0;
    self->map_ = map;
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

  [super dealloc];
}

@end

@interface DictionaryAdapterObjectKeysEnumerator : NSEnumerator

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary
                           isolate:(Isolate*)isolate
                             cache:(std::shared_ptr<Caches>)cache;
- (Local<v8::Array>)getProperties;

@end

@implementation DictionaryAdapterObjectKeysEnumerator {
  IsolateWrapper* wrapper_;
  std::shared_ptr<Persistent<Value>> dictionary_;
  NSUInteger index_;
}

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary
                           isolate:(Isolate*)isolate
                             cache:(std::shared_ptr<Caches>)cache {
  if (self) {
    self->wrapper_ = new IsolateWrapper(isolate);
    self->dictionary_ = dictionary;
    self->index_ = 0;
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

  [super dealloc];
}

@end

@implementation DictionaryAdapter {
  IsolateWrapper* wrapper_;
  std::shared_ptr<Persistent<Value>> object_;
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
    return
        [[[DictionaryAdapterMapKeysEnumerator alloc] initWithMap:self->object_
                                                         isolate:isolate
                                                           cache:wrapper_->GetCache()] autorelease];
  }

  return [[[DictionaryAdapterObjectKeysEnumerator alloc] initWithProperties:self->object_
                                                                    isolate:isolate
                                                                      cache:wrapper_->GetCache()]
      autorelease];
}

- (void)dealloc {
  if (wrapper_->IsValid()) {
    Isolate* isolate = wrapper_->Isolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    wrapper_->GetCache()->Instances.erase(self);
    Local<Value> value = self->object_->Get(isolate);
    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
    if (wrapper != nullptr) {
      if (wrapper == dataWrapper_) {
        dataWrapper_ = nullptr;
      }
      tns::DeleteValue(isolate, value);
      delete wrapper;
    }
  }
  if (dataWrapper_ != nullptr) {
    delete dataWrapper_;
  }
  self->object_ = nullptr;
  delete self->wrapper_;

  [super dealloc];
}

@end
