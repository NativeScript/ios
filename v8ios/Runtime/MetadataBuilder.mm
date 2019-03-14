#include <Foundation/Foundation.h>
#include "MetadataBuilder.h"

using namespace v8;

namespace tns {

MetadataBuilder::MetadataBuilder() {
}

void MetadataBuilder::Init(Isolate* isolate) {
    isolate_ = isolate;

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();

    MetaFile* metaFile = MetaFile::instance();
    auto globalTable = metaFile->globalTable();
    for (auto it = globalTable->begin(); it != globalTable->end(); it++) {
        const BaseClassMeta* baseMeta = static_cast<const BaseClassMeta*>(*it);
        if (baseMeta->type() == MetaType::Interface) {
            const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(baseMeta);
            Local<FunctionTemplate> ctorFuncTemplate = RegisterConstructor(interfaceMeta);
            RegisterInstanceMethods(ctorFuncTemplate, interfaceMeta);
            RegisterInstanceProperties(ctorFuncTemplate, interfaceMeta);

            Local<v8::Function> ctorFunc;
            if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
                assert(false);
            }

            if (!global->Set(v8::String::NewFromUtf8(isolate_, interfaceMeta->name()), ctorFunc)) {
                assert(false);
            }

            RegisterStaticMethods(ctorFunc, interfaceMeta);
            RegisterStaticProperties(ctorFunc, interfaceMeta);
        }
    }
}

Local<FunctionTemplate> MetadataBuilder::RegisterConstructor(const InterfaceMeta* interfaceMeta) {
    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, nullptr, this);
    Local<External> ext = External::New(isolate_, item);

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate_, ClassConstructorCallback, ext);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    return ctorFuncTemplate;
}

void MetadataBuilder::RegisterStaticMethods(Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    for (auto methodIt = interfaceMeta->staticMethods->begin(); methodIt != interfaceMeta->staticMethods->end(); methodIt++) {
        const MethodMeta* methodMeta = (*methodIt).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, interfaceMeta, this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        Local<v8::Function> staticMethod;
        if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)){
            assert(false);
        }
        ctorFunc->Set(v8::String::NewFromUtf8(isolate_, methodMeta->jsName()), staticMethod);
    }
}

void MetadataBuilder::RegisterInstanceMethods(Local<FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto methodIt = interfaceMeta->instanceMethods->begin(); methodIt != interfaceMeta->instanceMethods->end(); methodIt++) {
        const MethodMeta* methodMeta = (*methodIt).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, interfaceMeta, this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> instanceMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        proto->Set(v8::String::NewFromUtf8(isolate_, methodMeta->jsName()), instanceMethodTemplate);
    }
}

void MetadataBuilder::RegisterInstanceProperties(Local<FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto propIt = interfaceMeta->instanceProps->begin(); propIt != interfaceMeta->instanceProps->end(); propIt++) {
        const PropertyMeta* propMeta = (*propIt).valuePtr();

        AccessorGetterCallback getter = nullptr;
        AccessorSetterCallback setter = nullptr;
        if (propMeta->hasGetter()) {
            getter = PropertyGetterCallback;
        }

        if (propMeta->hasSetter()) {
            setter = PropertySetterCallback;
        }

        if (getter || setter) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, interfaceMeta, this);
            Local<External> ext = External::New(isolate_, item);
            Local<v8::String> propName = v8::String::NewFromUtf8(isolate_, propMeta->jsName());
            proto->SetAccessor(propName, getter, setter, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
        }
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta) {
    for (auto propIt = interfaceMeta->staticProps->begin(); propIt != interfaceMeta->staticProps->end(); propIt++) {
        const PropertyMeta* propMeta = (*propIt).valuePtr();

        AccessorNameGetterCallback getter = nullptr;
        AccessorNameSetterCallback setter = nullptr;
        if (propMeta->hasGetter()) {
            getter = PropertyNameGetterCallback;
        }

        if (propMeta->hasSetter()) {
            setter = PropertyNameSetterCallback;
        }

        if (getter || setter) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, interfaceMeta, this);
            Local<External> ext = External::New(isolate_, item);

            Local<v8::String> propName = v8::String::NewFromUtf8(isolate_, propMeta->jsName());
            Local<Context> context = isolate_->GetCurrentContext();
            bool success;
            Maybe<bool> maybeSuccess = ctorFunc->SetAccessor(context, propName, getter, setter, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
            if (!maybeSuccess.To(&success) || !success) {
                assert(false);
            }
        }
    }
}

void MetadataBuilder::ClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
        const InterfaceMeta* meta = item->meta_;

        NSString* className = [NSString stringWithUTF8String:meta->jsName()];
        Class klass = NSClassFromString(className);
        id obj = [[klass alloc] init];
        MethodCallbackData* data = new MethodCallbackData(obj);

        Local<External> ext = External::New(isolate, data);
        Local<Object> thiz = info.This();
        thiz->SetInternalField(0, ext);

        item->builder_->objectManager_.Register(isolate, thiz);
    }
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<MethodMeta>* item = static_cast<CacheItem<MethodMeta>*>(info.Data().As<External>()->Value());
        SEL selector = item->meta_->selector();
        bool instanceMethod = info.This()->InternalFieldCount() > 0;
        std::vector<Local<Value>> args;
        for (int i = 0; i < info.Length(); i++) {
            args.push_back(info[i]);
        }

        Local<Value> result = instanceMethod
            ? item->builder_->InvokeMethod(isolate, item, info.This(), selector, args)
            : item->builder_->InvokeMethod(isolate, item, Local<Object>(), selector, args);

        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        SEL selector = item->meta_->getter()->selector();
        Local<Object> receiver = info.This();
        Local<Value> result = item->builder_->InvokeMethod(isolate, item, receiver, selector, { });
        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertySetterCallback(Local<v8::String> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        SEL selector = item->meta_->setter()->selector();
        Local<Object> receiver = info.This();
        item->builder_->InvokeMethod(isolate, item, receiver, selector, { value });
    }
}

void MetadataBuilder::PropertyNameGetterCallback(Local<Name> name, const PropertyCallbackInfo<Value> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        SEL selector = item->meta_->getter()->selector();
        Local<Value> result = item->builder_->InvokeMethod(isolate, item, Local<Object>(), selector, { });
        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        SEL selector = item->meta_->setter()->selector();
        item->builder_->InvokeMethod(isolate, item, Local<Object>(), selector, { value });
    }
}

template<class T>
Local<Value> MetadataBuilder::InvokeMethod(Isolate* isolate, CacheItem<T>* item, Local<Object> receiver, SEL selector, const std::vector<Local<Value>> args) {
    static_assert(std::is_base_of<Meta, T>::value, "Derived not derived from Meta");

    NSString* className = [NSString stringWithUTF8String:item->interfaceMeta_->jsName()];
    Class klass = NSClassFromString(className);

    bool instanceMethod = !receiver.IsEmpty();
    NSMethodSignature* signature = instanceMethod
        ? [klass instanceMethodSignatureForSelector:selector]
        : [klass methodSignatureForSelector:selector];
    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:selector];

    for (int i = 0; i < args.size(); i++) {
        Local<Value> v8Arg = args[i];
        id arg = ConvertArgument(isolate, v8Arg);
        [invocation setArgument:&arg atIndex:i+2];
    }

    if (instanceMethod) {
        Local<External> ext = receiver->GetInternalField(0).As<External>();
        MethodCallbackData* methodCallbackData = reinterpret_cast<MethodCallbackData*>(ext->Value());
        id target = methodCallbackData->data_;
        [invocation invokeWithTarget:target];
    } else {
        [invocation setTarget:klass];
        [invocation invoke];
    }

    Method m = class_getInstanceMethod(klass, selector);
    char type[128];
    method_getReturnType(m, type, sizeof(type));
    if (strcmp(type, "v") != 0) {
        id result = nil;
        [invocation getReturnValue:&result];
        if (result) {
            CFBridgingRetain(result);
            return GetReturnValue(isolate, result);
        }
    }

    return Local<Value>();
}

id MetadataBuilder::ConvertArgument(Isolate* isolate, v8::Local<v8::Value> arg) {
    Local<Context> context = isolate->GetCurrentContext();
    if (arg->IsString()) {
        Local<v8::String> strArg = arg.As<v8::String>();
        v8::String::Utf8Value str(isolate, strArg);
        NSString* result = [NSString stringWithUTF8String:*str];
        return result;
    } else if (arg->IsNumber() || arg->IsDate()) {
        double res;
        if (!arg->NumberValue(context).To(&res)) {
            assert(false);
        }
        if (arg->IsNumber()) {
            return [NSNumber numberWithDouble:res];
        } else {
            return [NSDate dateWithTimeIntervalSince1970:res / 1000.0];
        }
    }

    assert(false);
}

Local<Value> MetadataBuilder::GetReturnValue(Isolate* isolate, id obj) {
    if ([obj isKindOfClass:[NSString class]]) {
        const char* str = [obj UTF8String];
        Local<v8::String> res = v8::String::NewFromUtf8(isolate, str);
        return res;
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        return Number::New(isolate, [obj doubleValue]);
    } else if ([obj isKindOfClass:[NSDate class]]) {
        Local<Context> context = isolate->GetCurrentContext();
        double time = [obj timeIntervalSince1970] * 1000.0;
        Local<Value> date;
        if (!Date::New(context, time).ToLocal(&date)) {
            assert(false);
        }
        return date;
    }
    MethodCallbackData* data = new MethodCallbackData(obj);
    Local<External> ext = External::New(isolate, data);

    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);
    objTemplate->SetInternalFieldCount(1);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> jsResult;
    if (!objTemplate->NewInstance(context).ToLocal(&jsResult)) {
        assert(false);
    }

    jsResult->SetInternalField(0, ext);
    objectManager_.Register(isolate, jsResult);

    return jsResult;
}

}
