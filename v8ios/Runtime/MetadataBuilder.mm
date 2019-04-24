#include <Foundation/Foundation.h>
#include <map>
#include "MetadataBuilder.h"
#include "ArgConverter.h"
#include "SymbolLoader.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Caches.h"
#include "Tasks.h"

using namespace v8;

namespace tns {

MetadataBuilder::MetadataBuilder() {
}

void MetadataBuilder::Init(Isolate* isolate) {
    isolate_ = isolate;

    ArgConverter::Init(isolate, MetadataBuilder::StructPropertyGetterCallback, MetadataBuilder::StructPropertySetterCallback);
    Interop::RegisterInteropTypes(isolate);
    poToStringFunction_ = CreateToStringFunction(isolate);

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
            BaseDataWrapper* wrapper = new BaseDataWrapper(meta);
            Local<Object> enumValue = ArgConverter::CreateEmptyObject(context);
            Local<External> ext = External::New(isolate, wrapper);
            enumValue->SetInternalField(0, ext);
            global->Set(tns::ToV8String(isolate, meta->jsName()), enumValue);
            break;
        }
        case MetaType::ProtocolType: {
            const ProtocolMeta* protoMeta = static_cast<const ProtocolMeta*>(meta);
            Local<Object> proto = ArgConverter::CreateEmptyObject(context);

            BaseDataWrapper* wrapper = new BaseDataWrapper(protoMeta);
            Local<External> ext = External::New(isolate, wrapper);
            proto->SetInternalField(0, ext);

            global->Set(tns::ToV8String(isolate, meta->jsName()), proto);
            break;
        }
        case MetaType::Struct: {
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

void MetadataBuilder::RegisterConstantsOnGlobalObject(v8::Local<v8::ObjectTemplate> global) {
    global->SetHandler(NamedPropertyHandlerConfiguration([](Local<Name> property, const PropertyCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        std::string propName = tns::ToString(info.GetIsolate(), property);
        const Meta* meta = ArgConverter::GetMeta(propName);
        if (meta == nullptr || meta->type() != MetaType::Var) {
            return;
        }

        void* dataSymbol = SymbolLoader::instance().loadDataSymbol(meta->topLevelModule(), meta->name());
        if (!dataSymbol) {
            return;
        }

        id result = *static_cast<const id*>(dataSymbol);
        if ([result isKindOfClass:[NSString class]]) {
            Local<v8::String> strResult = tns::ToV8String(isolate, [result UTF8String]);
            info.GetReturnValue().Set(strResult);
        }

        // TODO: Handle other data variable types than NSString
    }));
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplate(const InterfaceMeta* interfaceMeta) {
    Local<FunctionTemplate> ctorFuncTemplate;
    auto it = Caches::CtorFuncTemplates.find(interfaceMeta);
    if (it != Caches::CtorFuncTemplates.end()) {
        ctorFuncTemplate = Local<FunctionTemplate>::New(isolate_, *it->second);
        return ctorFuncTemplate;
    }

    std::string className;
    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, className, this);
    Local<External> ext = External::New(isolate_, item);

    ctorFuncTemplate = FunctionTemplate::New(isolate_, ClassConstructorCallback, ext);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate_, interfaceMeta->jsName()));
    Local<v8::Function> baseCtorFunc;

    while (true) {
        const char* baseName = interfaceMeta->baseName();
        if (baseName != nullptr) {
            const Meta* baseClassMeta = ArgConverter::GetMeta(baseName);
            if (baseClassMeta && baseClassMeta->type() == MetaType::Interface) {
                const InterfaceMeta* baseMeta = static_cast<const InterfaceMeta*>(baseClassMeta);
                if (baseMeta != nullptr) {
                    Local<FunctionTemplate> baseCtorFuncTemplate = GetOrCreateConstructorFunctionTemplate(baseMeta);
                    ctorFuncTemplate->Inherit(baseCtorFuncTemplate);
                    auto it = Caches::CtorFuncs.find(baseMeta);
                    if (it != Caches::CtorFuncs.end()) {
                        baseCtorFunc = Local<v8::Function>::New(isolate_, *it->second);
                    }
                }
            }
        }
        break;
    }

    std::vector<std::string> names;
    RegisterInstanceProperties(ctorFuncTemplate, interfaceMeta, interfaceMeta->name(), names);
    RegisterInstanceMethods(ctorFuncTemplate, interfaceMeta, names);
    RegisterInstanceProtocols(ctorFuncTemplate, interfaceMeta, interfaceMeta->name(), names);

    Local<Context> context = isolate_->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    Class clazz = objc_getClass(interfaceMeta->name());
    Local<External> ctorFuncExtData = External::New(isolate_, new ObjCDataWrapper(interfaceMeta, clazz));
    tns::SetPrivateValue(isolate_, ctorFunc, tns::ToV8String(isolate_, "metadata"), ctorFuncExtData);

    Caches::CtorFuncs.insert(std::make_pair(interfaceMeta, new Persistent<v8::Function>(isolate_, ctorFunc)));
    Local<Object> global = context->Global();
    global->Set(tns::ToV8String(isolate_, interfaceMeta->jsName()), ctorFunc);

    if (!baseCtorFunc.IsEmpty()) {
        bool success;
        if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            assert(false);
        }
    }

    RegisterAllocMethod(ctorFunc, interfaceMeta);
    RegisterStaticMethods(ctorFunc, interfaceMeta);
    RegisterStaticProperties(ctorFunc, interfaceMeta, interfaceMeta->name());
    RegisterStaticProtocols(ctorFunc, interfaceMeta);

    Local<v8::Function> extendFunc = classBuilder_.GetExtendFunction(context, interfaceMeta);
    ctorFunc->Set(tns::ToV8String(isolate_, "extend"), extendFunc);

    Caches::CtorFuncTemplates.insert(std::make_pair(interfaceMeta, new Persistent<FunctionTemplate>(isolate_, ctorFuncTemplate)));

    Local<Value> prototype = ctorFunc->Get(tns::ToV8String(isolate_, "prototype"));

    prototype.As<Object>()->Set(tns::ToV8String(isolate_, "toString"), poToStringFunction_->Get(isolate_));

    Persistent<Value>* poPrototype = new Persistent<Value>(isolate_, prototype);
    Caches::Prototypes.insert(std::make_pair(interfaceMeta, poPrototype));

    return ctorFuncTemplate;
}

Persistent<v8::Function>* MetadataBuilder::CreateToStringFunction(Isolate* isolate) {
    Local<FunctionTemplate> toStringFuncTemplate = FunctionTemplate::New(isolate_, MetadataBuilder::ToStringFunctionCallback);

    Local<v8::Function> toStringFunc;
    assert(toStringFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&toStringFunc));

    return new Persistent<v8::Function>(isolate, toStringFunc);
}

void MetadataBuilder::ToStringFunctionCallback(const FunctionCallbackInfo<v8::Value>& info) {
    Local<Object> thiz = info.This();
    if (thiz->InternalFieldCount() < 1) {
        info.GetReturnValue().Set(thiz);
        return;
    }

    Local<External> ext = thiz->GetInternalField(0).As<External>();
    BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
    if (wrapper->Type() != WrapperType::ObjCObject) {
        info.GetReturnValue().Set(thiz);
        return;
    }

    ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(ext->Value());
    id target = dataWrapper->Data();
    if (target == nil) {
        info.GetReturnValue().Set(thiz);
        return;
    }

    std::string description = [[target description] UTF8String];
    Local<v8::String> returnValue = tns::ToV8String(info.GetIsolate(), description);
    info.GetReturnValue().Set(returnValue);
}

void MetadataBuilder::RegisterCFunction(const FunctionMeta* funcMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<v8::Function> func;
    std::string className;
    CacheItem<FunctionMeta>* item = new CacheItem<FunctionMeta>(funcMeta, className, this);
    Local<External> ext = External::New(isolate_, item);
    if (!v8::Function::New(context, CFunctionCallback, ext).ToLocal(&func)) {
        assert(false);
    }
    global->Set(tns::ToV8String(isolate_, funcMeta->jsName()), func);
}

void MetadataBuilder::RegisterAllocMethod(Local<v8::Function> ctorFunc, const InterfaceMeta* interfaceMeta) {
    Local<Context> context = isolate_->GetCurrentContext();
    std::string className;
    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, className, this);
    Local<External> ext = External::New(isolate_, item);
    Local<FunctionTemplate> allocFuncTemplate = FunctionTemplate::New(isolate_, AllocCallback, ext);
    Local<v8::Function> allocFunc;
    if (!allocFuncTemplate->GetFunction(context).ToLocal(&allocFunc)) {
        assert(false);
    }
    ctorFunc->Set(tns::ToV8String(isolate_, "alloc"), allocFunc);
}

void MetadataBuilder::RegisterInstanceMethods(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, std::vector<std::string>& names) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();

        std::string name = methodMeta->jsName();
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name(), this);
            Local<External> ext = External::New(isolate_, item);
            Local<FunctionTemplate> instanceMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
            proto->Set(tns::ToV8String(isolate_, name), instanceMethodTemplate);
            names.push_back(name);
        }
    }
}

void MetadataBuilder::RegisterInstanceProperties(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();

        std::string name = propMeta->jsName();
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            AccessorGetterCallback getter = nullptr;
            AccessorSetterCallback setter = nullptr;
            if (propMeta->hasGetter()) {
                getter = PropertyGetterCallback;
            }

            if (propMeta->hasSetter()) {
                setter = PropertySetterCallback;
            }

            if (getter || setter) {
                CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className, this);
                Local<External> ext = External::New(isolate_, item);
                Local<v8::String> propName = tns::ToV8String(isolate_, name);
                proto->SetAccessor(propName, getter, setter, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
                names.push_back(name);
            }
        }
    }
}

void MetadataBuilder::RegisterInstanceProtocols(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
    if (meta->type() == MetaType::ProtocolType) {
        RegisterInstanceMethods(ctorFuncTemplate, meta, names);
        RegisterInstanceProperties(ctorFuncTemplate, meta, className, names);
    }

    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName.c_str());
        if (m != nullptr) {
            const BaseClassMeta* protoMeta = static_cast<const BaseClassMeta*>(m);
            RegisterInstanceProtocols(ctorFuncTemplate, protoMeta, className, names);
        }
    }
}

void MetadataBuilder::RegisterStaticMethods(Local<v8::Function> ctorFunc, const BaseClassMeta* meta) {
    Local<Context> context = isolate_->GetCurrentContext();
    for (auto it = meta->staticMethods->begin(); it != meta->staticMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name(), this);
        Local<External> ext = External::New(isolate_, item);
        Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
        Local<v8::Function> staticMethod;
        if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
            assert(false);
        }
        ctorFunc->Set(tns::ToV8String(isolate_, methodMeta->jsName()), staticMethod);
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className) {
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
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className, this);
            Local<External> ext = External::New(isolate_, item);

            Local<v8::String> propName = tns::ToV8String(isolate_, propMeta->jsName());
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
//    assert(info.Length() == 0);
    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;

    NSString* className = [NSString stringWithUTF8String:meta->jsName()];
    Class klass = NSClassFromString(className);
    id obj = [[klass alloc] init];

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(meta, obj);
    ArgConverter::CreateJsWrapper(isolate, wrapper, info.This());
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;
    Class klass = objc_getClass(meta->jsName());
    id obj = [klass alloc];

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(meta, obj);
    Local<Value> result = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>());
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

    const std::string className = item->className_;
    Local<Value> result = instanceMethod
        ? item->builder_->InvokeMethod(isolate, item->meta_, info.This(), args, className, true)
        : item->builder_->InvokeMethod(isolate, item->meta_, Local<Object>(), args, className, true);

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();

    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), receiver, { }, item->className_, false);
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertySetterCallback(Local<v8::String> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), receiver, { value }, item->className_, false);
}

void MetadataBuilder::PropertyNameGetterCallback(Local<Name> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), Local<Object>(), { }, item->className_, false);
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), Local<Object>(), { value }, item->className_, false);
}

void MetadataBuilder::StructPropertyGetterCallback(v8::Local<v8::Name> property, const v8::PropertyCallbackInfo<v8::Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();

    std::string propertyName = tns::ToString(isolate, property);

    if (propertyName == "") {
        info.GetReturnValue().Set(thiz);
        return;
    }

    Local<External> ext = thiz->GetInternalField(0).As<External>();
    RecordDataWrapper* wrapper = static_cast<RecordDataWrapper*>(ext->Value());
    const StructMeta* structMeta = static_cast<const StructMeta*>(wrapper->Metadata());

    std::map<std::string, RecordField> fields;
    FFICall::GetStructFFIType(structMeta, fields);
    auto it = fields.find(propertyName);
    if (it == fields.end()) {
        info.GetReturnValue().Set(v8::Undefined(isolate));
        return;
    }

    RecordField field = it->second;
    const TypeEncoding* fieldEncoding = field.Encoding();
    ptrdiff_t offset = field.Offset();
    void* buffer = wrapper->Data();
    BaseFFICall call((uint8_t*)buffer, offset);
    ffi_type* ffiType = wrapper->FFIType();

    Local<Value> result = Interop::GetResult(isolate, fieldEncoding, ffiType, &call);

    info.GetReturnValue().Set(result);
}

void MetadataBuilder::StructPropertySetterCallback(Local<Name> property, Local<Value> value, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();

    std::string propertyName = tns::ToString(isolate, property);

    if (propertyName == "") {
        info.GetReturnValue().Set(thiz);
        return;
    }

    Local<External> ext = thiz->GetInternalField(0).As<External>();
    RecordDataWrapper* wrapper = static_cast<RecordDataWrapper*>(ext->Value());
    const StructMeta* structMeta = static_cast<const StructMeta*>(wrapper->Metadata());

    std::map<std::string, RecordField> fields;
    FFICall::GetStructFFIType(structMeta, fields);
    auto it = fields.find(propertyName);
    if (it == fields.end()) {
        return;
    }

    RecordField field = it->second;
    Interop::SetStructPropertyValue(wrapper, field, value);
}

Local<Value> MetadataBuilder::InvokeMethod(Isolate* isolate, const MethodMeta* meta, Local<Object> receiver, const std::vector<Local<Value>> args, std::string containingClass, bool isMethodCallback) {
    Class klass = objc_getClass(containingClass.c_str());
    // TODO: Find out if the isMethodCallback property can be determined based on a UITableViewController.prototype.viewDidLoad.call(this) or super.viewDidLoad() call
    return ArgConverter::Invoke(isolate, klass, receiver, args, meta, isMethodCallback);
}

void MetadataBuilder::CFunctionCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    CacheItem<FunctionMeta>* item = static_cast<CacheItem<FunctionMeta>*>(info.Data().As<External>()->Value());

    if (strcmp(item->meta_->jsName(), "UIApplicationMain") == 0) {
        std::vector<Persistent<Value>*> args;
        for (int i = 0; i < info.Length(); i++) {
            args.push_back(new Persistent<Value>(isolate, info[i]));
        }

        void* userData = new TaskContext(isolate, item->meta_, args);
        Tasks::Register([](void* userData) {
            TaskContext* context = static_cast<TaskContext*>(userData);
            std::vector<Local<Value>> args;
            HandleScope handle_scope(context->isolate_);
            for (int i = 0; i < context->args_.size(); i++) {
                Local<Value> arg = context->args_[i]->Get(context->isolate_);
                args.push_back(arg);
            }
            Interop::CallFunction(context->isolate_, context->meta_, nil, nil, args);
        }, userData);
        return;
    }

    std::vector<Local<Value>> args;
    for (int i = 0; i < info.Length(); i++) {
        args.push_back(info[i]);
    }

    Local<Value> result = Interop::CallFunction(isolate, item->meta_, nil, nil, args);
    if (item->meta_->encodings()->first()->type != BinaryTypeEncodingType::VoidEncoding) {
        info.GetReturnValue().Set(result);
    }
}

}
