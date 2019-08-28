#import <Foundation/NSString.h>
#include "DictionaryAdapter.h"
#include "Interop.h"
#include "DataWrapper.h"
#include "Helpers.h"

using namespace v8;
using namespace tns;

@interface DictionaryAdapterMapKeysEnumerator : NSEnumerator

- (instancetype)initWithMap:(Local<Map>)properties isolate:(Isolate*)isolate;

@end

@implementation DictionaryAdapterMapKeysEnumerator {
    Isolate* isolate_;
    uint32_t index_;
    Persistent<v8::Array>* array_;
}

- (instancetype)initWithMap:(Local<Map>)map isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->index_ = 0;
        self->array_ = new Persistent<v8::Array>(isolate, map->AsArray());
    }

    return self;
}

- (id)nextObject {
    Isolate* isolate = self->isolate_;
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Array> array = self->array_->Get(isolate);

    if (self->index_ < array->Length() - 1) {
        Local<Value> key;
        bool success = array->Get(context, self->index_).ToLocal(&key);
        assert(success);
        self->index_ += 2;
        std::string keyStr = tns::ToString(self->isolate_, key);
        NSString* result = [NSString stringWithUTF8String:keyStr.c_str()];
        return result;
    }

    return nil;
}

- (void)dealloc {
    self->array_->Reset();
}

@end

@interface DictionaryAdapterObjectKeysEnumerator : NSEnumerator

- (instancetype)initWithProperties:(Local<v8::Array>)properties isolate:(Isolate*)isolate;

@end

@implementation DictionaryAdapterObjectKeysEnumerator {
    Isolate* isolate_;
    Persistent<v8::Array>* properties_;
    NSUInteger index_;
}

- (instancetype)initWithProperties:(Local<v8::Array>)properties isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->properties_ = new Persistent<v8::Array>(isolate, properties);
        self->index_ = 0;
    }

    return self;
}

- (id)nextObject {
    Isolate* isolate = self->isolate_;
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Array> properties = self->properties_->Get(self->isolate_);
    if (self->index_ < properties->Length()) {
        Local<Value> value;
        bool success = properties->Get(context, (uint)self->index_).ToLocal(&value);
        assert(success);
        self->index_++;
        std::string result = tns::ToString(self->isolate_, value);
        return [NSString stringWithUTF8String:result.c_str()];
    }

    return nil;
}

- (NSArray*)allObjects {
    Isolate* isolate = self->isolate_;
    Local<Context> context = isolate->GetCurrentContext();
    NSMutableArray* array = [NSMutableArray array];
    Local<v8::Array> properties = self->properties_->Get(self->isolate_);
    for (int i = 0; i < properties->Length(); i++) {
        Local<Value> value;
        bool success = properties->Get(context, i).ToLocal(&value);
        assert(success);
        std::string result = tns::ToString(self->isolate_, value);
        [array addObject:[NSString stringWithUTF8String:result.c_str()]];
    }

    return array;
}

- (void)dealloc {
    self->properties_->Reset();
}

@end

@implementation DictionaryAdapter {
    Isolate* isolate_;
    Persistent<Object>* object_;
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->isolate_ = isolate;
        self->object_ = new Persistent<Object>(isolate, jsObject);
    }

    return self;
}

- (NSUInteger)count {
    Local<Object> obj = self->object_->Get(self->isolate_);

    if (obj->IsMap()) {
        return obj.As<Map>()->Size();
    }

    Local<Context> context = self->isolate_->GetCurrentContext();
    Local<v8::Array> properties;
    assert(obj->GetOwnPropertyNames(context).ToLocal(&properties));

    uint32_t length = properties->Length();

    return length;
}

- (id)objectForKey:(id)aKey {
    Isolate* isolate = self->isolate_;
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> obj = self->object_->Get(self->isolate_);

    Local<Value> value;
    if ([aKey isKindOfClass:[NSNumber class]]) {
        unsigned int key = [aKey unsignedIntValue];
        bool success = obj->Get(context, key).ToLocal(&value);
        assert(success);
    } else if ([aKey isKindOfClass:[NSString class]]) {
        const char* key = [aKey UTF8String];
        Local<v8::String> keyV8Str = tns::ToV8String(isolate, key);

        if (obj->IsMap()) {
            Local<Context> context = isolate->GetCurrentContext();
            Local<Map> map = obj.As<Map>();
            bool success = map->Get(context, keyV8Str).ToLocal(&value);
            assert(success);
        } else {
            bool success = obj->Get(context, keyV8Str).ToLocal(&value);
            assert(success);
        }
    } else {
        // TODO: unsupported key type
        assert(false);
    }

    id result = Interop::ToObject(self->isolate_, value);

    return result;
}

- (NSEnumerator*)keyEnumerator {
    Local<Object> obj = self->object_->Get(self->isolate_);

    if (obj->IsMap()) {
        return [[DictionaryAdapterMapKeysEnumerator alloc] initWithMap:obj.As<Map>() isolate:self->isolate_];
    }

    Local<Context> context = self->isolate_->GetCurrentContext();
    Local<v8::Array> properties;
    assert(obj->GetOwnPropertyNames(context).ToLocal(&properties));

    return [[DictionaryAdapterObjectKeysEnumerator alloc] initWithProperties:properties isolate:self->isolate_];
}

- (void)dealloc {
    self->object_->Reset();
}

@end
