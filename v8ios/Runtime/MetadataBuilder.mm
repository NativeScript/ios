#include <Foundation/Foundation.h>
#include "MetadataBuilder.h"
#include "Strings.h"

using namespace v8;

namespace tns {

MetadataBuilder::MetadataBuilder() {
}

void MetadataBuilder::Init(Isolate* isolate) {
    isolate_ = isolate;

    argConverter_.Init(isolate, objectManager_);

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    const GlobalTable* globalTable = MetaFile::instance()->globalTable();

    for (auto it = globalTable->begin(); it != globalTable->end(); it++) {
        const Meta* meta = (*it);

        switch (meta->type()) {
        case MetaType::Function: {
            const FunctionMeta* funcMeta = static_cast<const FunctionMeta*>(meta);
            RegisterCFunction(funcMeta);
            break;
        }
        case MetaType::JsCode: {
            DataWrapper* wrapper = new DataWrapper(nullptr, meta);
            Local<Object> enumValue = argConverter_.CreateEmptyObject(context);
            Local<External> ext = External::New(isolate, wrapper);
            enumValue->SetInternalField(0, ext);
            global->Set(Strings::ToV8String(isolate, meta->jsName()), enumValue);
            break;
        }
        case MetaType::ProtocolType: {
            break;
        }
        case MetaType::Interface: {
            const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
            GetOrCreateConstructorFunctionTemplate(interfaceMeta);

            auto itMetaCache = Caches::Metadata.find(interfaceMeta->jsName());
            if (itMetaCache == Caches::Metadata.end()) {
                Caches::Metadata.insert(std::make_pair(interfaceMeta->jsName(), interfaceMeta));
            }
            break;
        }
        default: {
            continue;
        }
        }
    }
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplate(const InterfaceMeta* interfaceMeta) {
    Local<FunctionTemplate> ctorFuncTemplate;
    auto it = ctorFuncTemplatesCache_.find(interfaceMeta);
    if (it != ctorFuncTemplatesCache_.end()) {
        ctorFuncTemplate = Local<FunctionTemplate>::New(isolate_, *it->second);
        return ctorFuncTemplate;
    }

    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, nullptr, this);
    Local<External> ext = External::New(isolate_, item);

    ctorFuncTemplate = FunctionTemplate::New(isolate_, ClassConstructorCallback, ext);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(Strings::ToV8String(isolate_, interfaceMeta->jsName()));
    Local<v8::Function> baseCtorFunc;

    while (true) {
        const InterfaceMeta* baseMeta = interfaceMeta->baseMeta();
        if (baseMeta != nullptr) {
            Local<FunctionTemplate> baseCtorFuncTemplate = GetOrCreateConstructorFunctionTemplate(baseMeta);
            ctorFuncTemplate->Inherit(baseCtorFuncTemplate);
            auto it = ctorFuncsCache_.find(baseMeta);
            if (it != ctorFuncsCache_.end()) {
                baseCtorFunc = Local<v8::Function>::New(isolate_, *it->second);
            }
        }
        break;
    }

    RegisterInstanceMethods(ctorFuncTemplate, interfaceMeta);
    RegisterInstanceProperties(ctorFuncTemplate, interfaceMeta);
    RegisterInstanceProtocols(ctorFuncTemplate, interfaceMeta);

    Local<Context> context = isolate_->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    ctorFuncsCache_.insert(std::make_pair(interfaceMeta, new Persistent<v8::Function>(isolate_, ctorFunc)));
    Local<Object> global = context->Global();
    global->Set(Strings::ToV8String(isolate_, interfaceMeta->jsName()), ctorFunc);

    if (!baseCtorFunc.IsEmpty()) {
        bool success;
        if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            assert(false);
        }
    }

    RegisterAllocMethod(ctorFunc, interfaceMeta);
    RegisterStaticMethods(ctorFunc, interfaceMeta);
    RegisterStaticProperties(ctorFunc, interfaceMeta);
    RegisterStaticProtocols(ctorFunc, interfaceMeta);

    ctorFuncTemplatesCache_.insert(std::make_pair(interfaceMeta, new Persistent<FunctionTemplate>(isolate_, ctorFuncTemplate)));

    Local<Value> prototype = ctorFunc->Get(Strings::ToV8String(isolate_, "prototype"));
    Persistent<Value>* poPrototype = new Persistent<Value>(isolate_, prototype);
    Caches::Prototypes.insert(std::make_pair(interfaceMeta, poPrototype));

    return ctorFuncTemplate;
}

void MetadataBuilder::RegisterCFunction(const FunctionMeta* funcMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<v8::Function> func;
    CacheItem<FunctionMeta>* item = new CacheItem<FunctionMeta>(funcMeta, nullptr, this);
    Local<External> ext = External::New(isolate_, item);
    if (!v8::Function::New(context, CFunctionCallback, ext).ToLocal(&func)) {
        assert(false);
    }
    global->Set(Strings::ToV8String(isolate_, funcMeta->jsName()), func);
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
    ctorFunc->Set(Strings::ToV8String(isolate_, "alloc"), allocFunc);
}

void MetadataBuilder::RegisterInstanceMethods(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta, this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> instanceMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        proto->Set(Strings::ToV8String(isolate_, methodMeta->jsName()), instanceMethodTemplate);
    }
}

void MetadataBuilder::RegisterInstanceProperties(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();

        AccessorGetterCallback getter = nullptr;
        AccessorSetterCallback setter = nullptr;
        if (propMeta->hasGetter()) {
            getter = PropertyGetterCallback;
        }

        if (propMeta->hasSetter()) {
            setter = PropertySetterCallback;
        }

        if (getter || setter) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, meta, this);
            Local<External> ext = External::New(isolate_, item);
            Local<v8::String> propName = Strings::ToV8String(isolate_, propMeta->jsName());
            proto->SetAccessor(propName, getter, setter, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
        }
    }
}

void MetadataBuilder::RegisterInstanceProtocols(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta) {
    if (meta->type() == MetaType::ProtocolType) {
        RegisterInstanceMethods(ctorFuncTemplate, meta);
        RegisterInstanceProperties(ctorFuncTemplate, meta);
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());
        if (protoMeta != nullptr) {
            RegisterInstanceProtocols(ctorFuncTemplate, protoMeta);
        }
    }
}

void MetadataBuilder::RegisterStaticMethods(Local<v8::Function> ctorFunc, const BaseClassMeta* meta) {
    Local<Context> context = isolate_->GetCurrentContext();
    for (auto it = meta->staticMethods->begin(); it != meta->staticMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta, this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        Local<v8::Function> staticMethod;
        if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
            assert(false);
        }
        ctorFunc->Set(Strings::ToV8String(isolate_, methodMeta->jsName()), staticMethod);
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<v8::Function> ctorFunc, const BaseClassMeta* meta) {
    for (auto it = meta->staticProps->begin(); it != meta->staticProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();

        AccessorNameGetterCallback getter = nullptr;
        AccessorNameSetterCallback setter = nullptr;
        if (propMeta->hasGetter()) {
            getter = PropertyNameGetterCallback;
        }

        if (propMeta->hasSetter()) {
            setter = PropertyNameSetterCallback;
        }

        if (getter || setter) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, meta, this);
            Local<External> ext = External::New(isolate_, item);

            Local<v8::String> propName = Strings::ToV8String(isolate_, propMeta->jsName());
            Local<Context> context = isolate_->GetCurrentContext();
            bool success;
            Maybe<bool> maybeSuccess = ctorFunc->SetAccessor(context, propName, getter, setter, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
            if (!maybeSuccess.To(&success) || !success) {
                assert(false);
            }
        }
    }
}

void MetadataBuilder::RegisterStaticProtocols(v8::Local<v8::Function> ctorFunc, const BaseClassMeta* meta) {
    if (meta->type() == MetaType::ProtocolType) {
        RegisterStaticMethods(ctorFunc, meta);
        //RegisterStaticProperties(ctorFunc, meta);
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());
        if (protoMeta != nullptr) {
            RegisterStaticProtocols(ctorFunc, protoMeta);
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

    item->builder_->argConverter_.CreateJsWrapper(isolate, obj, info.This());
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;
    Class klass = objc_getClass(meta->jsName());
    id obj = [klass alloc];
    Local<Object> result = item->builder_->argConverter_.CreateJsWrapper(isolate, obj, Local<Object>());
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
        ? item->builder_->InvokeMethod(isolate, item->meta_, info.This(), args, item->classMeta_->jsName())
        : item->builder_->InvokeMethod(isolate, item->meta_, Local<Object>(), args, item->classMeta_->jsName());

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::CFunctionCallback(const FunctionCallbackInfo<Value>& info) {
    //Isolate* isolate = info.GetIsolate();
    //CacheItem<FunctionMeta>* item = static_cast<CacheItem<FunctionMeta>*>(info.Data().As<External>()->Value());
    // TODO: libffi to call the function
}

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), receiver, { }, item->classMeta_->jsName());
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertySetterCallback(Local<v8::String> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), receiver, { value }, item->classMeta_->jsName());
}

void MetadataBuilder::PropertyNameGetterCallback(Local<Name> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), Local<Object>(), { }, item->classMeta_->jsName());
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), Local<Object>(), { value }, item->classMeta_->jsName());
}

Local<Value> MetadataBuilder::InvokeMethod(Isolate* isolate, const MethodMeta* meta, Local<Object> receiver, const std::vector<Local<Value>> args, std::string containingClass) {
    Class klass = objc_getClass(containingClass.c_str());
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
        argConverter_.SetArgument(invocation, i + 2, isolate, v8Arg, typeEncoding);
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

    return argConverter_.ConvertArgument(isolate, invocation, signature.methodReturnType);
}

}
