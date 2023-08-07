#import <Foundation/NSString.h>
#include "DictionaryAdapter.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Caches.h"
#include "IsolateWrapper.h"

using namespace v8;
using namespace tns;

@interface DictionaryAdapterMapKeysEnumerator : NSEnumerator

- (instancetype)initWithMap:(std::shared_ptr<Persistent<Value>>)map isolate:(Isolate*)isolate cache:(std::shared_ptr<Caches>)cache;

@end

@implementation DictionaryAdapterMapKeysEnumerator {
    IsolateWrapper* wrapper_;
    uint32_t index_;
    std::shared_ptr<Persistent<Value>> map_;
}

- (instancetype)initWithMap:(std::shared_ptr<Persistent<Value>>)map isolate:(Isolate*)isolate cache:(std::shared_ptr<Caches>)cache {
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
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> array = self->map_->Get(isolate).As<Map>()->AsArray();

    if (self->index_ < array->Length() - 1) {
        Local<Value> key;
        bool success = array->Get(context, self->index_).ToLocal(&key);
        tns::Assert(success, isolate);
        self->index_ += 2;
        NSString* result = tns::ToNSString(isolate, key);
        return result;
    }

    return nil;
}

- (void)dealloc {
    self->map_ = nil;
    delete self->wrapper_;
    
    [super dealloc];
}

@end

@interface DictionaryAdapterObjectKeysEnumerator : NSEnumerator

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary isolate:(Isolate*)isolate cache:(std::shared_ptr<Caches>)cache;
- (Local<v8::Array>)getProperties;

@end

@implementation DictionaryAdapterObjectKeysEnumerator {
    IsolateWrapper* wrapper_;
    std::shared_ptr<Persistent<Value>> dictionary_;
    NSUInteger index_;
}

- (instancetype)initWithProperties:(std::shared_ptr<Persistent<Value>>)dictionary isolate:(Isolate*)isolate cache:(std::shared_ptr<Caches>)cache {
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
    tns::Assert(dictionary->GetOwnPropertyNames(context).ToLocal(&properties), isolate);
    return handle_scope.Escape(properties);
}

- (id)nextObject {
    if (!wrapper_->IsValid()) {
        return nil;
    }
    Isolate* isolate = wrapper_->Isolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> properties = [self getProperties];
    if (self->index_ < properties->Length()) {
        Local<Value> value;
        bool success = properties->Get(context, (uint)self->index_).ToLocal(&value);
        tns::Assert(success, isolate);
        self->index_++;
        std::string result = tns::ToString(isolate, value);
        return [NSString stringWithUTF8String:result.c_str()];
    }

    return nil;
}

- (NSArray*)allObjects {
    if (!wrapper_->IsValid()) {
        return nil;
    }
    Isolate* isolate = wrapper_->Isolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    NSMutableArray* array = [NSMutableArray array];
    Local<v8::Array> properties = [self getProperties];
    for (int i = 0; i < properties->Length(); i++) {
        Local<Value> value;
        bool success = properties->Get(context, i).ToLocal(&value);
        tns::Assert(success, isolate);
        std::string result = tns::ToString(isolate, value);
        [array addObject:[NSString stringWithUTF8String:result.c_str()]];
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
}

- (instancetype)initWithJSObject:(Local<Object>)jsObject isolate:(Isolate*)isolate {
    if (self) {
        self->wrapper_ = new IsolateWrapper(isolate);
        self->object_ = std::make_shared<Persistent<Value>>(isolate, jsObject);
        self->wrapper_->GetCache()->Instances.emplace(self, self->object_);
        tns::SetValue(isolate, jsObject, new ObjCDataWrapper(self));
    }

    return self;
}

- (NSUInteger)count {
    if (!wrapper_->IsValid()) {
        return 0;
    }
    Isolate* isolate = wrapper_->Isolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Object> obj = self->object_->Get(isolate).As<Object>();

    if (obj->IsMap()) {
        return obj.As<Map>()->Size();
    }

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<v8::Array> properties;
    tns::Assert(obj->GetOwnPropertyNames(context).ToLocal(&properties), isolate);

    uint32_t length = properties->Length();

    return length;
}

- (id)objectForKey:(id)aKey {
    if (!wrapper_->IsValid()) {
        return nil;
    }
    Isolate* isolate = wrapper_->Isolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    Local<Context> context = wrapper_->GetCache()->GetContext();
    Local<Object> obj = self->object_->Get(isolate).As<Object>();

    Local<Value> value;
    if ([aKey isKindOfClass:[NSNumber class]]) {
        unsigned int key = [aKey unsignedIntValue];
        bool success = obj->Get(context, key).ToLocal(&value);
        tns::Assert(success, isolate);
    } else if ([aKey isKindOfClass:[NSString class]]) {
        const char* key = [aKey UTF8String];
        Local<v8::String> keyV8Str = tns::ToV8String(isolate, key);

        if (obj->IsMap()) {
            Local<Map> map = obj.As<Map>();
            bool success = map->Get(context, keyV8Str).ToLocal(&value);
            tns::Assert(success, isolate);
        } else {
            bool success = obj->Get(context, keyV8Str).ToLocal(&value);
            tns::Assert(success, isolate);
        }
    } else {
        // TODO: unsupported key type
        tns::Assert(false, isolate);
    }

    id result = Interop::ToObject(context, value);

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
        return [[[DictionaryAdapterMapKeysEnumerator alloc] initWithMap:self->object_ isolate:isolate cache:wrapper_->GetCache()] autorelease];
    }
    
    return [[[DictionaryAdapterObjectKeysEnumerator alloc] initWithProperties:self->object_ isolate:isolate cache:wrapper_->GetCache()] autorelease];
}

- (void)dealloc {
    if(wrapper_->IsValid()) {
        Isolate* isolate = wrapper_->Isolate();
        wrapper_->GetCache()->Instances.erase(self);
        Local<Value> value = self->object_->Get(isolate);
        BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
        if (wrapper != nullptr) {
            tns::DeleteValue(isolate, value);
            delete wrapper;
        }
    }
    self->object_ = nil;
    self->object_ = nullptr;
    delete self->wrapper_;
    
    [super dealloc];
}

@end
