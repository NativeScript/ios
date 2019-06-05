#include <Foundation/Foundation.h>
#include <map>
#include "MetadataBuilder.h"
#include "ArgConverter.h"
#include "SymbolLoader.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Interop_impl.h"
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

    classBuilder_.RegisterBaseTypeScriptExtendsFunction(isolate); // Register the __extends function to the global object
    classBuilder_.RegisterNativeTypeScriptExtendsFunction(isolate); // Override the __extends function for native objects

    for (auto it = globalTable->begin(); it != globalTable->end(); it++) {
        const Meta* meta = (*it);

        switch (meta->type()) {
        case MetaType::Function: {
            const FunctionMeta* funcMeta = static_cast<const FunctionMeta*>(meta);
            RegisterCFunction(funcMeta);
            break;
        }
        case MetaType::ProtocolType: {
            Local<Object> proto = ArgConverter::CreateEmptyObject(context);

            BaseDataWrapper* wrapper = new BaseDataWrapper(meta->name());
            Local<External> ext = External::New(isolate, wrapper);
            proto->SetInternalField(0, ext);

            Caches::ProtocolInstances.insert(std::make_pair(meta->name(), new Persistent<Object>(isolate, proto)));
            global->Set(tns::ToV8String(isolate, meta->jsName()), proto);
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
        if (meta == nullptr) {
            return;
        }

        if (meta->type() == MetaType::Var) {
            void* dataSymbol = SymbolLoader::instance().loadDataSymbol(meta->topLevelModule(), meta->name());
            if (!dataSymbol) {
                return;
            }

            const VarMeta* varMeta = static_cast<const VarMeta*>(meta);

            if (varMeta->encoding()->type == BinaryTypeEncodingType::IntEncoding) {
                int value = *static_cast<int*>(dataSymbol);
                Local<Number> numResult = Number::New(isolate, value);
                info.GetReturnValue().Set(numResult);
                return;
            }

            if (varMeta->encoding()->type == BinaryTypeEncodingType::DoubleEncoding) {
                double value = *static_cast<double*>(dataSymbol);
                Local<Number> numResult = Number::New(isolate, value);
                info.GetReturnValue().Set(numResult);
                return;
            }

            if (varMeta->encoding()->type == BinaryTypeEncodingType::BoolEncoding) {
                bool value = *static_cast<bool*>(dataSymbol);
                Local<Value> numResult = v8::Boolean::New(isolate, value);
                info.GetReturnValue().Set(numResult);
                return;
            }

            id result = *static_cast<const id*>(dataSymbol);
            if ([result isKindOfClass:[NSString class]]) {
                Local<v8::String> strResult = tns::ToV8String(isolate, [result UTF8String]);
                info.GetReturnValue().Set(strResult);
                return;
            }

            // TODO: Handle other data variable types than NSString
            assert(false);
        } else if (meta->type() == MetaType::JsCode) {
            const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
            std::string jsCode = jsCodeMeta->jsCode();
            Local<Context> context = isolate->GetCurrentContext();
            Local<Script> script;
            if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
                assert(false);
            }
            assert(!script.IsEmpty());

            Local<Value> result;
            if (!script->Run(context).ToLocal(&result)) {
                assert(false);
            }
            info.GetReturnValue().Set(result);
        } else if (meta->type() == MetaType::Struct) {
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            Local<v8::Function> structCtorFunc = MetadataBuilder::GetOrCreateStructCtorFunction(isolate, structMeta);
            info.GetReturnValue().Set(structCtorFunc);
        }
    }));
}

Local<v8::Function> MetadataBuilder::GetOrCreateStructCtorFunction(Isolate* isolate, const StructMeta* structMeta) {
    auto it = Caches::StructConstructorFunctions.find(structMeta);
    if (it != Caches::StructConstructorFunctions.end()) {
        return it->second->Get(isolate);
    }

    CacheItem<StructMeta>* item = new CacheItem<StructMeta>(structMeta, std::string(), nullptr);
    Local<External> ext = External::New(isolate, item);
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> structCtorFunc;

    bool success = v8::Function::New(context, StructConstructorCallback, ext).ToLocal(&structCtorFunc);
    assert(success);

    tns::SetPrivateValue(isolate, structCtorFunc, tns::ToV8String(isolate, "metadata"), ext);

    Local<v8::Function> equalsFunc;
    success = v8::Function::New(context, StructEqualsCallback).ToLocal(&equalsFunc);
    assert(success);
    structCtorFunc->Set(tns::ToV8String(isolate, "equals"), equalsFunc);

    Persistent<v8::Function>* poStructCtorFunc = new Persistent<v8::Function>(isolate, structCtorFunc);
    Caches::StructConstructorFunctions.insert(std::make_pair(structMeta, poStructCtorFunc));

    return structCtorFunc;
}

void MetadataBuilder::StructConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    assert(info.IsConstructCall());

    CacheItem<StructMeta>* item = static_cast<CacheItem<StructMeta>*>(info.Data().As<External>()->Value());

    std::vector<StructField> fields;
    ffi_type* ffiType = FFICall::GetStructFFIType(item->meta_, fields);

    Local<Value> initializer = info.Length() > 0 ? info[0] : Local<Value>();
    void* dest = calloc(1, ffiType->size);
    Interop::InitializeStruct(info.GetIsolate(), dest, fields, initializer);

    Isolate* isolate = info.GetIsolate();
    StructDataWrapper* wrapper = new StructDataWrapper(item->meta_, dest, ffiType);
    Local<Value> result = ArgConverter::ConvertArgument(isolate, wrapper);
    info.GetReturnValue().Set(result);
}

void MetadataBuilder::StructEqualsCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    assert(info.Length() == 2);

    Local<Object> arg1 = info[0].As<Object>();
    Local<Object> arg2 = info[1].As<Object>();

    if (arg1.IsEmpty() || !arg1->IsObject() || arg1->IsNullOrUndefined() ||
        arg2.IsEmpty() || !arg2->IsObject() || arg2->IsNullOrUndefined()) {
        info.GetReturnValue().Set(false);
        return;
    }

    Isolate* isolate = info.GetIsolate();
    Local<Value> metadataProp = tns::GetPrivateValue(isolate, info.This(), tns::ToV8String(isolate, "metadata"));
    if (metadataProp.IsEmpty() || !metadataProp->IsExternal()) {
        info.GetReturnValue().Set(false);
        return;
    }

    Local<External> ext = metadataProp.As<External>();
    CacheItem<StructMeta>* item = static_cast<CacheItem<StructMeta>*>(ext->Value());
    const StructMeta* structMeta = item->meta_;

    std::pair<ffi_type*, void*> pair1 = MetadataBuilder::GetStructData(isolate, arg1, structMeta);
    std::pair<ffi_type*, void*> pair2 = MetadataBuilder::GetStructData(isolate, arg2, structMeta);

    if (pair1.first == nullptr || pair1.second == nullptr ||
        pair2.first == nullptr || pair2.second == nullptr) {
        info.GetReturnValue().Set(false);
        return;
    }

    ffi_type* ffiType1 = pair1.first;
    void* arg1Data = pair1.second;
    void* arg2Data = pair2.second;

    int result = memcmp(arg1Data, arg2Data, ffiType1->size);
    bool areEqual = result == 0;

    info.GetReturnValue().Set(areEqual);
}

std::pair<ffi_type*, void*> MetadataBuilder::GetStructData(Isolate* isolate, Local<Object> initializer, const StructMeta* structMeta) {
    ffi_type* ffiType = nullptr;
    void* data = nullptr;

    if (initializer->InternalFieldCount() < 1) {
        std::vector<StructField> fields;
        ffiType = FFICall::GetStructFFIType(structMeta, fields);
        data = calloc(1, ffiType->size);
        Interop::InitializeStruct(isolate, data, fields, initializer);
    } else {
        Local<External> ext = initializer->GetInternalField(0).As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        if (wrapper->Type() != WrapperType::Record) {
            return std::make_pair(ffiType, data);
        }
        StructDataWrapper* structWrapper = static_cast<StructDataWrapper*>(wrapper);
        if (structWrapper->Metadata() != structMeta) {
            return std::make_pair(ffiType, data);
        }

        data = structWrapper->Data();
        ffiType = structWrapper->FFIType();
    }

    return std::make_pair(ffiType, data);
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
                    auto it = Caches::CtorFuncs.find(baseMeta->name());
                    if (it != Caches::CtorFuncs.end()) {
                        baseCtorFunc = Local<v8::Function>::New(isolate_, *it->second);
                    }
                }
            }
        }
        break;
    }

    std::vector<std::string> instanceMembers;
    RegisterInstanceProperties(ctorFuncTemplate, interfaceMeta, interfaceMeta->name(), instanceMembers);
    RegisterInstanceMethods(ctorFuncTemplate, interfaceMeta, instanceMembers);
    RegisterInstanceProtocols(ctorFuncTemplate, interfaceMeta, interfaceMeta->name(), instanceMembers);

    Local<Context> context = isolate_->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    Class clazz = objc_getClass(interfaceMeta->name());
    Local<External> ctorFuncExtData = External::New(isolate_, new ObjCDataWrapper(interfaceMeta->name(), clazz));
    tns::SetPrivateValue(isolate_, ctorFunc, tns::ToV8String(isolate_, "metadata"), ctorFuncExtData);

    Caches::CtorFuncs.insert(std::make_pair(interfaceMeta->name(), new Persistent<v8::Function>(isolate_, ctorFunc)));
    Local<Object> global = context->Global();
    global->Set(tns::ToV8String(isolate_, interfaceMeta->jsName()), ctorFunc);

    if (!baseCtorFunc.IsEmpty()) {
        bool success;
        if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            assert(false);
        }
    }

    std::vector<std::string> staticMembers;
    RegisterAllocMethod(ctorFunc, interfaceMeta);
    RegisterStaticMethods(ctorFunc, interfaceMeta, staticMembers);
    RegisterStaticProperties(ctorFunc, interfaceMeta, interfaceMeta->name(), staticMembers);
    RegisterStaticProtocols(ctorFunc, interfaceMeta, interfaceMeta->name(), staticMembers);

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

    DefineFunctionLengthProperty(context, funcMeta->encodings(), func);
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

void MetadataBuilder::RegisterStaticMethods(Local<v8::Function> ctorFunc, const BaseClassMeta* meta, std::vector<std::string>& names) {
    Local<Context> context = isolate_->GetCurrentContext();
    for (auto it = meta->staticMethods->begin(); it != meta->staticMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();

        std::string name = methodMeta->jsName();
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name(), this);
            Local<External> ext = External::New(isolate_, item);
            Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate_, MethodCallback, ext);
            Local<v8::Function> staticMethod;
            if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
                assert(false);
            }

            DefineFunctionLengthProperty(context, methodMeta->encodings(), staticMethod);
            ctorFunc->Set(tns::ToV8String(isolate_, methodMeta->jsName()), staticMethod);
            names.push_back(name);
        }
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
    for (auto it = meta->staticProps->begin(); it != meta->staticProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();

        std::string name = propMeta->jsName();
        if (std::find(names.begin(), names.end(), name) == names.end()) {
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
                names.push_back(name);
            }
        }
    }
}

void MetadataBuilder::RegisterStaticProtocols(v8::Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
    if (meta->type() == MetaType::ProtocolType) {
        RegisterStaticMethods(ctorFunc, meta, names);
        RegisterStaticProperties(ctorFunc, meta, className, names);
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());
        if (protoMeta != nullptr) {
            RegisterStaticProtocols(ctorFunc, protoMeta, className, names);
        }
    }
}

void MetadataBuilder::ClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
//    assert(info.Length() == 0);
    Isolate* isolate = info.GetIsolate();
    CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
    const InterfaceMeta* meta = item->meta_;

    NSString* className = [NSString stringWithUTF8String:meta->name()];
    Class klass = NSClassFromString(className);
    id obj = [[klass alloc] init];

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(meta->name(), obj);
    ArgConverter::CreateJsWrapper(isolate, wrapper, info.This());
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    Isolate* isolate = info.GetIsolate();

    Local<Object> thiz = info.This();
    std::string className;

    Local<Value> metadataProp = tns::GetPrivateValue(isolate, thiz, tns::ToV8String(isolate, "metadata"));
    if (!metadataProp.IsEmpty() && !metadataProp->IsNullOrUndefined() && metadataProp->IsExternal()) {
        Local<External> e = metadataProp.As<External>();
        ObjCDataWrapper* wr = static_cast<ObjCDataWrapper*>(e->Value());
        className = wr->Name();
    } else {
        CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
        const InterfaceMeta* meta = item->meta_;
        className = meta->name();
    }

    Class klass = objc_getClass(className.c_str());
    id obj = [klass alloc];

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(className, obj);
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

    std::string className = item->className_;

    Local<Object> thiz = info.This();
    if (thiz->IsFunction()) {
        Local<Value> metadataProp = tns::GetPrivateValue(isolate, thiz, tns::ToV8String(isolate, "metadata"));
        if (metadataProp->IsExternal()) {
            ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(metadataProp.As<External>()->Value());
            className = wrapper->Name();
        }
    }

    Local<Value> result = instanceMethod
        ? item->builder_->InvokeMethod(isolate, item->meta_, info.This(), args, className, true)
        : item->builder_->InvokeMethod(isolate, item->meta_, Local<Object>(), args, className, true);

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyGetterCallback(Local<v8::String> name, const PropertyCallbackInfo<Value> &info) {
    Local<Object> receiver = info.This();

    if (receiver->InternalFieldCount() < 1) {
        return;
    }

    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());

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
    StructDataWrapper* wrapper = static_cast<StructDataWrapper*>(ext->Value());
    const StructMeta* structMeta = static_cast<const StructMeta*>(wrapper->Metadata());

    std::vector<StructField> fields;
    FFICall::GetStructFFIType(structMeta, fields);
    auto it = std::find_if(fields.begin(), fields.end(), [&propertyName](StructField &f) { return f.Name() == propertyName; });
    if (it == fields.end()) {
        info.GetReturnValue().Set(v8::Undefined(isolate));
        return;
    }

    StructField field = *it;
    const TypeEncoding* fieldEncoding = field.Encoding();
    ptrdiff_t offset = field.Offset();
    void* buffer = wrapper->Data();
    BaseFFICall call((uint8_t*)buffer, offset);
    ffi_type* structFFIType = wrapper->FFIType();

    Local<Value> result = Interop::GetResult(isolate, fieldEncoding, structFFIType, &call, false, field.FFIType());

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
    StructDataWrapper* wrapper = static_cast<StructDataWrapper*>(ext->Value());
    const StructMeta* structMeta = static_cast<const StructMeta*>(wrapper->Metadata());

    std::vector<StructField> fields;
    FFICall::GetStructFFIType(structMeta, fields);

    auto it = std::find_if(fields.begin(), fields.end(), [&propertyName](StructField &f) { return f.Name() == propertyName; });
    if (it == fields.end()) {
        return;
    }

    StructField field = *it;
    Interop::SetStructPropertyValue(wrapper, field, value);
}

void MetadataBuilder::DefineFunctionLengthProperty(Local<Context> context, const TypeEncodingsList<ArrayCount>* encodings, Local<v8::Function> func) {
    Isolate* isolate = context->GetIsolate();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    int paramsCount = std::max(0, encodings->count - 1);
    bool success = func->DefineOwnProperty(context, tns::ToV8String(isolate, "length"), Number::New(isolate, paramsCount), readOnlyFlags).FromMaybe(false);
    assert(success);
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
