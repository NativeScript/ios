#include <Foundation/Foundation.h>
#include "MetadataBuilder.h"

using namespace v8;

namespace tns {

MetadataBuilder::MetadataBuilder() {
}

void MetadataBuilder::Init(Isolate* isolate) {
    isolate_ = isolate;
    Local<Context> context = isolate_->GetCurrentContext();
    Local<Object> global = context->Global();

    MetaFile* metaFile = MetaFile::instance();
    auto globalTable = metaFile->globalTable();
    for (auto it = globalTable->begin(); it != globalTable->end(); it++) {
        const BaseClassMeta* meta = static_cast<const BaseClassMeta*>(*it);

        if (meta->type() != MetaType::Interface) {
            // Currently only classes are supported
            continue;
        }

        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const InterfaceMeta* baseMeta = interfaceMeta->baseMeta();

        Local<FunctionTemplate> ctorFuncTemplate = GetOrCreateConstructor(interfaceMeta);
        if (baseMeta != nullptr) {
            Local<FunctionTemplate> parentCtorFuncTemplate = GetOrCreateConstructor(baseMeta);
            ctorFuncTemplate->Inherit(parentCtorFuncTemplate);
        }
    }

    // TODO: Try to avoid the second pass through the metadata. Instantiating the FunctionTemplate should be done
    // only once all the prototype inheritance is configured between the classes
    for (auto it = globalTable->begin(); it != globalTable->end(); it++) {
        const BaseClassMeta* meta = static_cast<const BaseClassMeta*>(*it);

        if (meta->type() != MetaType::Interface) {
            // Currently only classes are supported
            continue;
        }

        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        Local<FunctionTemplate> ctorFuncTemplate = GetOrCreateConstructor(interfaceMeta);

        Local<v8::Function> ctorFunc;
        if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
            assert(false);
        }

        if (!global->Set(v8::String::NewFromUtf8(isolate_, interfaceMeta->name()), ctorFunc)) {
            assert(false);
        }

        RegisterStaticMethods(ctorFunc, interfaceMeta);
        RegisterStaticProperties(ctorFunc, interfaceMeta);

        Persistent<v8::Function>* poCtorFunc = new Persistent<v8::Function>(isolate_, ctorFunc);
        ctorsCache_.insert(std::make_pair(interfaceMeta, poCtorFunc));
    }
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructor(const InterfaceMeta* interfaceMeta) {
    Local<FunctionTemplate> ctorFuncTemplate;

    auto it = ctorTemplatesCache_.find(interfaceMeta);
    if (it != ctorTemplatesCache_.end()) {
        Persistent<FunctionTemplate>* poCtorFuncTemplate = it->second;
        ctorFuncTemplate = Local<FunctionTemplate>::New(isolate_, *poCtorFuncTemplate);
    } else {
        CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, nullptr, this);
        Local<External> ext = External::New(isolate_, item);

        ctorFuncTemplate = FunctionTemplate::New(isolate_, ClassConstructorCallback, ext);
        ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
        ctorFuncTemplate->SetClassName(v8::String::NewFromUtf8(isolate_, interfaceMeta->jsName()));

        RegisterInstanceMethods(ctorFuncTemplate, interfaceMeta);
        RegisterInstanceProperties(ctorFuncTemplate, interfaceMeta);

        ctorTemplatesCache_.insert(std::make_pair(interfaceMeta, new Persistent<FunctionTemplate>(isolate_, ctorFuncTemplate)));
    }

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

        bool instanceMethod = info.This()->InternalFieldCount() > 0;
        std::vector<Local<Value>> args;
        for (int i = 0; i < info.Length(); i++) {
            args.push_back(info[i]);
        }

        Local<Value> result = instanceMethod
            ? item->builder_->InvokeMethod(isolate, item->meta_, info.This(), args, item->interfaceMeta_->jsName())
            : item->builder_->InvokeMethod(isolate, item->meta_, Local<Object>(), args, item->interfaceMeta_->jsName());

        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        Local<Object> receiver = info.This();
        Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), receiver, { }, item->interfaceMeta_->jsName());
        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertySetterCallback(Local<v8::String> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        Local<Object> receiver = info.This();
        item->builder_->InvokeMethod(isolate, item->meta_->setter(), receiver, { value }, item->interfaceMeta_->jsName());
    }
}

void MetadataBuilder::PropertyNameGetterCallback(Local<Name> name, const PropertyCallbackInfo<Value> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), Local<Object>(), { }, item->interfaceMeta_->jsName());
        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    @autoreleasepool {
        Isolate* isolate = info.GetIsolate();
        CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
        item->builder_->InvokeMethod(isolate, item->meta_->setter(), Local<Object>(), { value }, item->interfaceMeta_->jsName());
    }
}

Local<Value> MetadataBuilder::InvokeMethod(Isolate* isolate, const MethodMeta* meta, Local<Object> receiver, const std::vector<Local<Value>> args, const char* containingClass) {
    NSString* className = [NSString stringWithUTF8String:containingClass];
    Class klass = NSClassFromString(className);
    SEL selector = meta->selector();

    bool instanceMethod = !receiver.IsEmpty();
    NSMethodSignature* signature = instanceMethod
        ? [klass instanceMethodSignatureForSelector:selector]
        : [klass methodSignatureForSelector:selector];
    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:selector];

    const TypeEncoding* typeEncoding = meta->encodings()->first();
    for (int i = 0; i < args.size(); i++) {
        Local<Value> v8Arg = args[i];
        if (typeEncoding != nullptr) {
            typeEncoding = typeEncoding->next();
        } else {
            assert(false);
        }
        bool shouldRelease = false;
        const void* arg = ConvertArgument(isolate, v8Arg, typeEncoding, shouldRelease);
        if (shouldRelease) {
            CFBridgingRelease(arg);
        }
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

    const char* returnType = signature.methodReturnType;
    if (strcmp(returnType, "v") != 0) {
        id result = nil;
        [invocation getReturnValue:&result];
        if (result) {
            CFBridgingRetain(result);
            return ConvertArgument(isolate, result);
        }
    }

    return Local<Value>();
}

const void* MetadataBuilder::ConvertArgument(Isolate* isolate, Local<Value> arg, const TypeEncoding* typeEncoding, bool& shouldRelease) {
    if (arg->IsNull()) {
        return nil;
    }

    shouldRelease = false;
    if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        Local<v8::String> strArg = arg.As<v8::String>();
        v8::String::Utf8Value str(isolate, strArg);
        NSString* selector = [NSString stringWithUTF8String:*str];
        SEL res = NSSelectorFromString(selector);
        return res;
    }

    Local<Context> context = isolate->GetCurrentContext();
    shouldRelease = true;
    if (arg->IsString()) {
        Local<v8::String> strArg = arg.As<v8::String>();
        v8::String::Utf8Value str(isolate, strArg);
        NSString* result = [NSString stringWithUTF8String:*str];
        return CFBridgingRetain(result);
    } else if (arg->IsNumber() || arg->IsDate()) {
        double res;
        if (!arg->NumberValue(context).To(&res)) {
            assert(false);
        }
        if (arg->IsNumber()) {
            return CFBridgingRetain([NSNumber numberWithDouble:res]);
        } else {
            return CFBridgingRetain([NSDate dateWithTimeIntervalSince1970:res / 1000.0]);
        }
    } else if (arg->IsFunction() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        Local<v8::Function> callback = arg.As<v8::Function>();
        Persistent<v8::Function>* poCallback = new Persistent<v8::Function>(isolate, callback);

        id block = ^(id first, ...) {
            va_list args;
            int argsCount = typeEncoding->details.block.signature.count - 1;
            std::vector<id> arguments;
            for (int i = 0; i < argsCount; i++) {
                id val;
                if (i == 0) {
                    va_start(args, first);
                    val = first;
                } else {
                    val = va_arg(args, id);
                }
                arguments.push_back(val);
            }
            va_end(args);

            dispatch_async(dispatch_get_main_queue(), ^{
                Local<Value> res;
                HandleScope handle_scope(isolate);
                Local<Context> ctx = isolate->GetCurrentContext();
                Local<v8::Function> callback = Local<v8::Function>::New(isolate, *poCallback);

                std::vector<Local<Value>> v8Args;
                for (int i = 0; i < argsCount; i++) {
                    Local<Value> jsWrapper = ConvertArgument(isolate, arguments[i]);
                    v8Args.push_back(jsWrapper);
                }

                if (!callback->Call(ctx, ctx->Global(), argsCount, v8Args.data()).ToLocal(&res)) {
                    assert(false);
                }

                delete poCallback;
            });
        };
        return CFBridgingRetain(block);
    } else if (arg->IsObject()) {
        Local<Object> obj = arg.As<Object>();
        if (obj->InternalFieldCount() > 0) {
            Local<External> ext = obj->GetInternalField(0).As<External>();
            MethodCallbackData* methodCallbackData = reinterpret_cast<MethodCallbackData*>(ext->Value());
            return CFBridgingRetain(methodCallbackData->data_);
        }
    }

    assert(false);
}

Local<Value> MetadataBuilder::ConvertArgument(Isolate* isolate, id obj) {
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

    Local<Object> jsObject = CreateJsWrapper(isolate, obj);
    return jsObject;
}

Local<Object> MetadataBuilder::CreateJsWrapper(Isolate* isolate, id obj) {
    MethodCallbackData* data = new MethodCallbackData(obj);
    Local<External> ext = External::New(isolate, data);

    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);
    objTemplate->SetInternalFieldCount(1);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> jsResult;
    if (!objTemplate->NewInstance(context).ToLocal(&jsResult)) {
        assert(false);
    }

    const InterfaceMeta* meta = GetInterfaceMeta(obj);
    if (meta != nullptr) {
        auto it = ctorsCache_.find(meta);
        if (it != ctorsCache_.end()) {
            Persistent<v8::Function>* poCtorFunc = it->second;
            Local<v8::Function> ctorFunc = Local<v8::Function>::New(isolate, *poCtorFunc);
            bool success;
            if (!jsResult->SetPrototype(context, ctorFunc->Get(v8::String::NewFromUtf8(isolate, "prototype"))).To(&success) || !success) {
                assert(false);
            }
        }
    }

    jsResult->SetInternalField(0, ext);
    objectManager_.Register(isolate, jsResult);

    return jsResult;
}

const InterfaceMeta* MetadataBuilder::GetInterfaceMeta(id obj) {
    if (obj == nullptr) {
        return nullptr;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    Class klass = [obj class];
    while (true) {
        NSString* className = NSStringFromClass(klass);
        const InterfaceMeta* result = globalTable->findInterfaceMeta([className UTF8String]);
        if (result != nullptr) {
            return result;
        }

        klass = class_getSuperclass(klass);
        if (klass == nullptr) {
            break;
        }
    }

    return nullptr;
}

}
