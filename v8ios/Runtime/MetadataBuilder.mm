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

            Local<v8::Function> ctorFunc;
            if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
                assert(false);
            }

            if (!global->Set(v8::String::NewFromUtf8(isolate_, interfaceMeta->name()), ctorFunc)) {
                assert(false);
            }

            RegisterStaticMethods(ctorFunc, interfaceMeta);
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

void MetadataBuilder::ClassConstructorCallback(const FunctionCallbackInfo<Value>& args) {
    assert(args.Length() == 0);

    @autoreleasepool {
        Isolate* isolate = args.GetIsolate();
        CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(args.Data().As<External>()->Value());
        const InterfaceMeta* meta = item->meta_;

        NSString* className = [NSString stringWithUTF8String:meta->jsName()];
        Class klass = NSClassFromString(className);
        id obj = [[klass alloc] init];
        MethodCallbackData* data = new MethodCallbackData((void*)CFBridgingRetain(obj));

        Local<External> ext = External::New(isolate, data);
        Local<Object> thiz = args.This();
        thiz->SetInternalField(0, ext);

        item->builder_->objectManager_.Register(isolate, thiz);
    }
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& args) {
    @autoreleasepool {
        CacheItem<MethodMeta>* item = static_cast<CacheItem<MethodMeta>*>(args.Data().As<External>()->Value());
        const MethodMeta* meta = item->meta_;
        MetadataBuilder* thiz = item->builder_;

        NSString* className = [NSString stringWithUTF8String:item->interfaceMeta_->jsName()];
        Class klass = NSClassFromString(className);

        Local<Object> receiver = args.This();
        bool isInstanceMethod = receiver->InternalFieldCount() > 0;
        SEL selector = meta->selector();
        NSMethodSignature* signature = isInstanceMethod
            ? [klass instanceMethodSignatureForSelector:selector]
            : [klass methodSignatureForSelector:selector];
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:selector];

        Isolate* isolate = args.GetIsolate();

        for (int i = 0; i < args.Length(); i++) {
            Local<Value> v8Arg = args[i];
            id arg = thiz->ConvertArgument(isolate, v8Arg);
            [invocation setArgument:&arg atIndex:i+2];
        }

        if (isInstanceMethod) {
            Local<External> ext = receiver->GetInternalField(0).As<External>();
            MethodCallbackData* methodCallbackData = reinterpret_cast<MethodCallbackData*>(ext->Value());
            id target = (__bridge_transfer id)methodCallbackData->data_;
            [invocation invokeWithTarget:target];
        } else {
            [invocation setTarget:klass];
            [invocation invoke];
        }

        const TypeEncoding* encoding = meta->encodings()[0].first();
        if (encoding != nullptr && encoding->type != VoidEncoding) {
            id result = nil;
            [invocation getReturnValue:&result];
            if (result) {
                CFBridgingRetain(result);
                thiz->SetReturnValue(result, args);
            }
        }
    }
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

void MetadataBuilder::SetReturnValue(id obj, const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if ([obj isKindOfClass:[NSString class]]) {
        const char* str = [obj UTF8String];
        Local<v8::String> res = v8::String::NewFromUtf8(isolate, str);
        args.GetReturnValue().Set(res);
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        args.GetReturnValue().Set(Number::New(isolate, [obj doubleValue]));
    } else if ([obj isKindOfClass:[NSDate class]]) {
        Local<Context> context = isolate->GetCurrentContext();
        double time = [obj timeIntervalSince1970];
        Local<Value> date;
        if (!Date::New(context, time).ToLocal(&date)) {
            assert(false);
        }
        args.GetReturnValue().Set(date);
    } else {
        MethodCallbackData* data = new MethodCallbackData((void*)CFBridgingRetain(obj));
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

        args.GetReturnValue().Set(jsResult);
    }
}

}
