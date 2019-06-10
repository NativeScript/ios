#import <Foundation/NSString.h>
#include "DictionaryAdapter.h"
#include "ArrayAdapter.h"
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
    Local<v8::Array> array = self->array_->Get(isolate);

    if (self->index_ < array->Length() - 1) {
        Local<Value> key = array->Get(self->index_);
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
    Local<v8::Array> properties = self->properties_->Get(self->isolate_);
    if (self->index_ < properties->Length()) {
        Local<Value> value = properties->Get((uint)self->index_);
        self->index_++;
        std::string result = tns::ToString(self->isolate_, value);
        return [NSString stringWithUTF8String:result.c_str()];
    }

    return nil;
}

- (NSArray*)allObjects {
    NSMutableArray* array = [NSMutableArray array];
    Local<v8::Array> properties = self->properties_->Get(self->isolate_);
    for (int i = 0; i < properties->Length(); i++) {
        Local<Value> value = properties->Get(i);
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
    Local<Object> obj = self->object_->Get(self->isolate_);

    Local<Value> value;
    if ([aKey isKindOfClass:[NSNumber class]]) {
        unsigned int key = [aKey unsignedIntValue];
        value = obj->Get(key);
    } else if ([aKey isKindOfClass:[NSString class]]) {
        const char* key = [aKey UTF8String];

        if (obj->IsMap()) {
            Local<Context> context = self->isolate_->GetCurrentContext();
            bool success = obj.As<Map>()->Get(context, tns::ToV8String(self->isolate_, key)).ToLocal(&value);
            assert(success);
        } else {
            value = obj->Get(tns::ToV8String(self->isolate_, key));
        }
    } else {
        // TODO: unsupported key type
        assert(false);
    }

    if (value.IsEmpty() || value->IsNullOrUndefined()) {
        return nil;
    }

    if (tns::IsString(value)) {
        std::string str = tns::ToString(self->isolate_, value);
        return [NSString stringWithUTF8String:str.c_str()];
    }

    if (tns::IsNumber(value)) {
        double result = tns::ToNumber(value);
        return @(result);
    }

    if (tns::IsBool(value)) {
        bool result = tns::ToBool(value);
        return @(result);
    }

    if (value->IsArray()) {
        ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:value.As<v8::Array>() isolate:self->isolate_];
        return adapter;
    }

    if (value->IsObject()) {
        Local<Object> obj = value.As<Object>();
        if (obj->InternalFieldCount() > 0) {
            Local<External> ext = obj->GetInternalField(0).As<External>();
            BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
            if (wrapper->Type() == WrapperType::ObjCObject) {
                ObjCDataWrapper* objCDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                id data = objCDataWrapper->Data();
                return data;
            }
            // TODO: Handle other possible wrapper types such as Enum, Record or Primitive
        }

        DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:obj isolate:self->isolate_];
        return adapter;
    }

    assert(false);
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
