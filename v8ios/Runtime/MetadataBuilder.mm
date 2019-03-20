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
        const Meta* meta = static_cast<const Meta*>(*it);

        if (meta->type() == MetaType::JsCode) {
            Local<Context> context = isolate->GetCurrentContext();
            Local<Object> global = context->Global();
            DataWrapper* wrapper = new DataWrapper(nullptr, meta);
            Local<Object> enumValue = CreateEmptyObject(context);
            Local<External> ext = External::New(isolate, wrapper);
            enumValue->SetInternalField(0, ext);
            global->Set(v8::String::NewFromUtf8(isolate, meta->jsName()), enumValue);
            continue;
        }

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

        RegisterAllocMethod(ctorFunc, interfaceMeta);
        RegisterStaticMethods(ctorFunc, interfaceMeta);
        RegisterStaticProperties(ctorFunc, interfaceMeta);

        Local<Value> prototype = ctorFunc->Get(v8::String::NewFromUtf8(isolate, "prototype"));
        Persistent<Value>* poPrototype = new Persistent<Value>(isolate, prototype);
        prototypesCache_.insert(std::make_pair(interfaceMeta, poPrototype));
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

void MetadataBuilder::RegisterAllocMethod(Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, nullptr, this);
    Local<External> ext = External::New(isolate_, item);
    Local<FunctionTemplate> allocFuncTemplate = FunctionTemplate::New(isolate_, AllocCallback, ext);
    Local<v8::Function> allocFunc;
    if (!allocFuncTemplate->GetFunction(context).ToLocal(&allocFunc)) {
        assert(false);
    }
    ctorFunc->Set(v8::String::NewFromUtf8(isolate_, "alloc"), allocFunc);
}

void MetadataBuilder::RegisterStaticMethods(Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    for (auto methodIt = interfaceMeta->staticMethods->begin(); methodIt != interfaceMeta->staticMethods->end(); methodIt++) {
        const MethodMeta* methodMeta = (*methodIt).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, interfaceMeta, this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        Local<v8::Function> staticMethod;
        if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
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

    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;

    NSString* className = [NSString stringWithUTF8String:meta->jsName()];
    Class klass = NSClassFromString(className);
    id obj = [[klass alloc] init];

    item->builder_->CreateJsWrapper(isolate, obj, info.This());
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;

    NSString* className = [NSString stringWithUTF8String:meta->jsName()];
    id obj = [NSClassFromString(className) alloc];
    Local<Object> result = item->builder_->CreateJsWrapper(isolate, obj, Local<Object>());
    info.GetReturnValue().Set(result);
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& info) {
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

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), receiver, { }, item->interfaceMeta_->jsName());
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertySetterCallback(Local<v8::String> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), receiver, { value }, item->interfaceMeta_->jsName());
}

void MetadataBuilder::PropertyNameGetterCallback(Local<Name> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), Local<Object>(), { }, item->interfaceMeta_->jsName());
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), Local<Object>(), { value }, item->interfaceMeta_->jsName());
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
        SetArgument(invocation, i + 2, isolate, v8Arg, typeEncoding);
    }

    if (instanceMethod) {
        Local<External> ext = receiver->GetInternalField(0).As<External>();
        DataWrapper* wrapper = reinterpret_cast<DataWrapper*>(ext->Value());
        id target = wrapper->data_;
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

void MetadataBuilder::SetArgument(NSInvocation* invocation, int index, Isolate* isolate, Local<Value> arg, const TypeEncoding* typeEncoding) {
    if (arg->IsNull()) {
        id nullArg = nil;
        [invocation setArgument:&nullArg atIndex:index];
        return;
    }

    if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        Local<v8::String> strArg = arg.As<v8::String>();
        v8::String::Utf8Value str(isolate, strArg);
        NSString* selector = [NSString stringWithUTF8String:*str];
        SEL res = NSSelectorFromString(selector);
        [invocation setArgument:&res atIndex:index];
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();
    if (arg->IsString()) {
        Local<v8::String> strArg = arg.As<v8::String>();
        v8::String::Utf8Value str(isolate, strArg);
        NSString* result = [NSString stringWithUTF8String:*str];
        [invocation setArgument:&result atIndex:index];
        return;
    }

    if (arg->IsNumber() || arg->IsDate()) {
        double value;
        if (!arg->NumberValue(context).To(&value)) {
            assert(false);
        }

        if (arg->IsNumber() || arg->IsNumberObject()) {
            SetNumericArgument(invocation, index, value, typeEncoding);
            return;
        } else {
            NSDate* date = [NSDate dateWithTimeIntervalSince1970:value / 1000.0];
            [invocation setArgument:&date atIndex:index];
        }
    }

    if (arg->IsFunction() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
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
        const void* ptr = CFBridgingRetain(block);
        [invocation setArgument:&ptr atIndex:index];
        return;
    }

    if (arg->IsObject()) {
        Local<Object> obj = arg.As<Object>();
        if (obj->InternalFieldCount() > 0) {
            Local<External> ext = obj->GetInternalField(0).As<External>();
            DataWrapper* wrapper = reinterpret_cast<DataWrapper*>(ext->Value());
            const Meta* meta = wrapper->meta_;
            if (meta != nullptr && meta->type() == MetaType::JsCode) {
                const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
                const char* jsCode = jsCodeMeta->jsCode();

                Local<Script> script;
                if (!Script::Compile(context, v8::String::NewFromUtf8(isolate, jsCode)).ToLocal(&script)) {
                    assert(false);
                }
                assert(!script.IsEmpty());

                Local<Value> result;
                if (!script->Run(context).ToLocal(&result) && !result.IsEmpty()) {
                    assert(false);
                }

                assert(result->IsNumber());

                double value = result.As<Number>()->Value();
                SetNumericArgument(invocation, index, value, typeEncoding);
                return;
            }

            if (wrapper->data_ != nullptr) {
                [invocation setArgument:&wrapper->data_ atIndex:index];
                return;
            }
        }
    }

    assert(false);
}

Local<Value> MetadataBuilder::ConvertArgument(Isolate* isolate, id obj) {
    if (obj == nullptr) {
        return Null(isolate);
    } else if ([obj isKindOfClass:[NSString class]]) {
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

    Local<Object> jsObject = CreateJsWrapper(isolate, obj, Local<Object>());
    return jsObject;
}

Local<Object> MetadataBuilder::CreateJsWrapper(Isolate* isolate, id obj, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (receiver.IsEmpty()) {
        receiver = CreateEmptyObject(context);
    }

    const InterfaceMeta* meta = GetInterfaceMeta(obj);
    if (meta != nullptr) {
        auto it = prototypesCache_.find(meta);
        if (it != prototypesCache_.end()) {
            Persistent<Value>* poPrototype = it->second;
            Local<Value> prototype = Local<Value>::New(isolate, *poPrototype);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                assert(false);
            }
        }
    }

    DataWrapper* wrapper = new DataWrapper(obj);
    Local<External> ext = External::New(isolate, wrapper);
    receiver->SetInternalField(0, ext);
    objectManager_.Register(isolate, receiver);

    return receiver;
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

Local<Object> MetadataBuilder::CreateEmptyObject(Local<Context> context) {
    Local<ObjectTemplate> tmpl = ObjectTemplate::New(context->GetIsolate());
    tmpl->SetInternalFieldCount(1);
    Local<Object> result;
    if (!tmpl->NewInstance(context).ToLocal(&result)) {
        assert(false);
    }
    return result;
}

void MetadataBuilder::SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
        case BinaryTypeEncodingType::ShortEncoding: {
            short arg = (short)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::UShortEncoding: {
            ushort arg = (ushort)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            int arg = (int)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            uint arg = (uint)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::LongEncoding: {
            long arg = (long)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            unsigned long arg = (unsigned long)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            long long arg = (long long)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            unsigned long long arg = (unsigned long long)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            float arg = (float)value;
            [invocation setArgument:&arg atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            [invocation setArgument:&value atIndex:index];
            break;
        }
        case BinaryTypeEncodingType::IdEncoding: {
            [invocation setArgument:&value atIndex:index];
            break;
        }
        default: {
            assert(false);
            break;
        }
    }
}

}
