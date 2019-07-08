#include <Foundation/Foundation.h>
#include <map>
#include "MetadataBuilder.h"
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "InlineFunctions.h"
#include "SymbolLoader.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Interop.h"
#include "Worker.h"
#include "Caches.h"
#include "Tasks.h"

using namespace v8;

namespace tns {

MetadataBuilder::MetadataBuilder() {
}

void MetadataBuilder::Init(Isolate* isolate, bool isWorkerThread) {
    this->isolate_ = isolate;
    this->isWorkerThread_ = isWorkerThread;

    ArgConverter::Init(isolate, MetadataBuilder::StructPropertyGetterCallback, MetadataBuilder::StructPropertySetterCallback);
    Interop::RegisterInteropTypes(isolate);
    poToStringFunction_ = CreateToStringFunction(isolate);

    classBuilder_.RegisterBaseTypeScriptExtendsFunction(isolate); // Register the __extends function to the global object
    classBuilder_.RegisterNativeTypeScriptExtendsFunction(isolate); // Override the __extends function for native objects
}

void MetadataBuilder::RegisterConstantsOnGlobalObject(Isolate* isolate, Local<ObjectTemplate> global, bool isWorkerThread) {
    this->isWorkerThread_ = isWorkerThread;

    Local<External> ext = External::New(isolate, this);

    global->SetHandler(NamedPropertyHandlerConfiguration([](Local<Name> property, const PropertyCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        std::string propName = tns::ToString(isolate, property);

        MetadataBuilder* builder = static_cast<MetadataBuilder*>(info.Data().As<External>()->Value());

        if (builder->isWorkerThread_ && std::find(Worker::GlobalFunctions.begin(), Worker::GlobalFunctions.end(), propName) != Worker::GlobalFunctions.end()) {
            return;
        }

        if (std::find(InlineFunctions::GlobalFunctions.begin(), InlineFunctions::GlobalFunctions.end(), propName) != InlineFunctions::GlobalFunctions.end()) {
            return;
        }

        const Meta* meta = ArgConverter::GetMeta(propName);
        if (meta == nullptr || !meta->isAvailable()) {
            return;
        }

        if (meta->type() == MetaType::Interface || meta->type() == MetaType::ProtocolType) {
            const BaseClassMeta* classMeta = static_cast<const BaseClassMeta*>(meta);
            builder->GetOrCreateConstructorFunctionTemplate(classMeta);

            bool isInterface = meta->type() == MetaType::Interface;
            auto cache = isInterface ? Caches::Get(isolate)->CtorFuncs : Caches::Get(isolate)->ProtocolCtorFuncs;
            std::string name = meta->name();
            auto it = cache.find(name);
            if (it != cache.end()) {
                Local<v8::Function> func = it->second->Get(isolate);
                info.GetReturnValue().Set(func);
            }
        } else if (meta->type() == MetaType::Function) {
            auto cache = Caches::Get(isolate);
            std::string funcName = meta->name();
            auto it = cache->CFunctions.find(funcName);
            if (it != cache->CFunctions.end()) {
                Local<v8::Function> func = it->second->Get(isolate);
                info.GetReturnValue().Set(func);
                return;
            }

            const FunctionMeta* funcMeta = static_cast<const FunctionMeta*>(meta);
            Local<Context> context = isolate->GetCurrentContext();

            CacheItem<FunctionMeta>* item = new CacheItem<FunctionMeta>(funcMeta, std::string(), builder);
            Local<External> ext = External::New(isolate, item);
            Local<v8::Function> func;
            bool success = v8::Function::New(context, CFunctionCallback, ext).ToLocal(&func);
            assert(success);

            tns::SetValue(isolate, func, new FunctionWrapper(funcMeta));
            builder->DefineFunctionLengthProperty(context, funcMeta->encodings(), func);

            cache->CFunctions.insert(std::make_pair(funcName, new Persistent<v8::Function>(isolate, func)));

            info.GetReturnValue().Set(func);
        } else if (meta->type() == MetaType::Var) {
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
            if (result == nil) {
                info.GetReturnValue().Set(Null(isolate));
                return;
            }

            if ([result isKindOfClass:[NSString class]]) {
                Local<v8::String> strResult = tns::ToV8String(isolate, [result UTF8String]);
                info.GetReturnValue().Set(strResult);
                return;
            } else if ([result isKindOfClass:[NSNumber class]]) {
                Local<Number> numResult = Number::New(isolate, [result doubleValue]);
                info.GetReturnValue().Set(numResult);
                return;
            }

            std::string className = object_getClassName(result);
            ObjCDataWrapper* wrapper = new ObjCDataWrapper(className, result);
            Local<Value> jsResult = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>());
            info.GetReturnValue().Set(jsResult);
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
            Local<v8::Function> structCtorFunc = builder->GetOrCreateStructCtorFunction(isolate, structMeta);
            info.GetReturnValue().Set(structCtorFunc);
        }
    }, nullptr, nullptr, nullptr, nullptr, ext));
}

Local<v8::Function> MetadataBuilder::GetOrCreateStructCtorFunction(Isolate* isolate, const StructMeta* structMeta) {
    auto cache = Caches::Get(isolate);
    auto it = cache->StructConstructorFunctions.find(structMeta);
    if (it != cache->StructConstructorFunctions.end()) {
        return it->second->Get(isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();

    StructTypeWrapper* wrapper = new StructTypeWrapper(structMeta);
    Local<External> ext = External::New(isolate, wrapper);
    Local<v8::Function> structCtorFunc;
    bool success = v8::Function::New(context, StructConstructorCallback, ext).ToLocal(&structCtorFunc);
    assert(success);

    tns::SetValue(isolate, structCtorFunc, wrapper);

    Local<v8::Function> equalsFunc;
    success = v8::Function::New(context, StructEqualsCallback).ToLocal(&equalsFunc);
    assert(success);

    success = structCtorFunc->Set(context, tns::ToV8String(isolate, "equals"), equalsFunc).FromMaybe(false);
    assert(success);

    Persistent<v8::Function>* poStructCtorFunc = new Persistent<v8::Function>(isolate, structCtorFunc);
    cache->StructConstructorFunctions.insert(std::make_pair(structMeta, poStructCtorFunc));

    return structCtorFunc;
}

void MetadataBuilder::StructConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    StructTypeWrapper* typeWrapper = static_cast<StructTypeWrapper*>(info.Data().As<External>()->Value());

    std::vector<StructField> fields;
    ffi_type* ffiType = FFICall::GetStructFFIType(typeWrapper->Meta(), fields);

    void* dest = nullptr;

    if (info.IsConstructCall()) {
        // A new structure is allocated
        Local<Value> initializer = info.Length() > 0 ? info[0] : Local<Value>();
        dest = malloc(ffiType->size);
        Interop::InitializeStruct(info.GetIsolate(), dest, fields, initializer);
    } else {
        // The structure is not used as constructor and in this case we assume a pointer is passed to the function
        // This pointer will be used as backing memory for the structure
        BaseDataWrapper* wrapper = nullptr;
        if (info.Length() < 1 || !(wrapper = tns::GetValue(isolate, info[0])) || wrapper->Type() != WrapperType::Pointer) {
            tns::ThrowError(isolate, "A pointer instance must be passed to the structure initializer");
            return;
        }

        PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
        dest = pw->Data();
    }

    StructWrapper* wrapper = new StructWrapper(typeWrapper->Meta(), dest, ffiType);
    Local<Value> result = ArgConverter::ConvertArgument(isolate, wrapper);
    info.GetReturnValue().Set(result);
}

void MetadataBuilder::StructEqualsCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 2);

    Local<Object> arg1 = info[0].As<Object>();
    Local<Object> arg2 = info[1].As<Object>();

    if (arg1.IsEmpty() || !arg1->IsObject() || arg1->IsNullOrUndefined() ||
        arg2.IsEmpty() || !arg2->IsObject() || arg2->IsNullOrUndefined()) {
        info.GetReturnValue().Set(false);
        return;
    }

    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    if (wrapper == nullptr || wrapper->Type() != WrapperType::StructType) {
        info.GetReturnValue().Set(false);
        return;
    }

    StructTypeWrapper* structTypeWrapper = static_cast<StructTypeWrapper*>(wrapper);
    const StructMeta* structMeta = structTypeWrapper->Meta();

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
        data = malloc(ffiType->size);
        Interop::InitializeStruct(isolate, data, fields, initializer);
    } else {
        Local<External> ext = initializer->GetInternalField(0).As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        if (wrapper->Type() != WrapperType::Struct) {
            return std::make_pair(ffiType, data);
        }
        StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
        if (structWrapper->Meta() != structMeta) {
            return std::make_pair(ffiType, data);
        }

        data = structWrapper->Data();
        ffiType = structWrapper->FFIType();
    }

    return std::make_pair(ffiType, data);
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplate(const BaseClassMeta* meta) {
    Local<FunctionTemplate> ctorFuncTemplate;
    auto cache = Caches::Get(isolate_);
    auto it = cache->CtorFuncTemplates.find(meta);
    if (it != cache->CtorFuncTemplates.end()) {
        ctorFuncTemplate = Local<FunctionTemplate>::New(isolate_, *it->second);
        return ctorFuncTemplate;
    }

    std::string className;
    CacheItem<BaseClassMeta>* item = new CacheItem<BaseClassMeta>(meta, className, this);
    Local<External> ext = External::New(isolate_, item);

    ctorFuncTemplate = FunctionTemplate::New(isolate_, ClassConstructorCallback, ext);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate_, meta->jsName()));
    Local<v8::Function> baseCtorFunc;

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const InterfaceMeta* currentMeta = interfaceMeta;
        while (true) {
            const char* baseName = currentMeta->baseName();
            if (baseName != nullptr) {
                const Meta* baseClassMeta = ArgConverter::GetMeta(baseName);
                if (baseClassMeta == nullptr || baseClassMeta->type() != MetaType::Interface) {
                    break;
                }

                if (!baseClassMeta->isAvailable()) {
                    // Skip base classes that are not available in the current iOS version
                    currentMeta = static_cast<const InterfaceMeta*>(baseClassMeta);
                    continue;
                }

                const InterfaceMeta* baseMeta = static_cast<const InterfaceMeta*>(baseClassMeta);
                if (baseMeta != nullptr) {
                    Local<FunctionTemplate> baseCtorFuncTemplate = GetOrCreateConstructorFunctionTemplate(baseMeta);
                    ctorFuncTemplate->Inherit(baseCtorFuncTemplate);
                    auto it = cache->CtorFuncs.find(baseMeta->name());
                    if (it != cache->CtorFuncs.end()) {
                        baseCtorFunc = Local<v8::Function>::New(isolate_, *it->second);
                    }
                }
            }
            break;
        }
    }

    std::vector<std::string> instanceMembers;
    RegisterInstanceProperties(ctorFuncTemplate, meta, meta->name(), instanceMembers);
    RegisterInstanceMethods(ctorFuncTemplate, meta, instanceMembers);
    RegisterInstanceProtocols(ctorFuncTemplate, meta, meta->name(), instanceMembers);

    Local<Context> context = isolate_->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    bool success = ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc);
    assert(success);

    if (meta->type() == MetaType::ProtocolType) {
        tns::SetValue(isolate_, ctorFunc, new ObjCProtocolWrapper(objc_getProtocol(meta->name())));
        cache->ProtocolCtorFuncs.insert(std::make_pair(meta->name(), new Persistent<v8::Function>(isolate_, ctorFunc)));
    } else {
        tns::SetValue(isolate_, ctorFunc, new ObjCClassWrapper(objc_getClass(meta->name())));
        cache->CtorFuncs.insert(std::make_pair(meta->name(), new Persistent<v8::Function>(isolate_, ctorFunc)));
    }

    Local<Object> global = context->Global();
    success = global->Set(context, tns::ToV8String(isolate_, meta->jsName()), ctorFunc).FromMaybe(false);
    assert(success);

    if (!baseCtorFunc.IsEmpty()) {
        bool success;
        if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            assert(false);
        }
    }

    std::vector<std::string> staticMembers;
    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        RegisterAllocMethod(ctorFunc, interfaceMeta);

        Local<v8::Function> extendFunc = classBuilder_.GetExtendFunction(context, interfaceMeta);
        bool success = ctorFunc->Set(context, tns::ToV8String(isolate_, "extend"), extendFunc).FromMaybe(false);
        assert(success);
    }

    RegisterStaticMethods(ctorFunc, meta, staticMembers);
    RegisterStaticProperties(ctorFunc, meta, meta->name(), staticMembers);
    RegisterStaticProtocols(ctorFunc, meta, meta->name(), staticMembers);

    cache->CtorFuncTemplates.insert(std::make_pair(meta, new Persistent<FunctionTemplate>(isolate_, ctorFuncTemplate)));

    Local<Value> prototypeValue;
    success = ctorFunc->Get(context, tns::ToV8String(isolate_, "prototype")).ToLocal(&prototypeValue);
    assert(success);
    Local<Object> prototype = prototypeValue.As<Object>();

    success = prototype->Set(context, tns::ToV8String(isolate_, "toString"), poToStringFunction_->Get(isolate_)).FromMaybe(false);
    assert(success);

    Persistent<Value>* poPrototype = new Persistent<Value>(isolate_, prototype);
    cache->Prototypes.insert(std::make_pair(meta, poPrototype));

    return ctorFuncTemplate;
}

Persistent<v8::Function>* MetadataBuilder::CreateToStringFunction(Isolate* isolate) {
    Local<FunctionTemplate> toStringFuncTemplate = FunctionTemplate::New(isolate_, MetadataBuilder::ToStringFunctionCallback);

    Local<v8::Function> toStringFunc;
    assert(toStringFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&toStringFunc));

    return new Persistent<v8::Function>(isolate, toStringFunc);
}

void MetadataBuilder::ToStringFunctionCallback(const FunctionCallbackInfo<Value>& info) {
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

    bool success = ctorFunc->Set(context, tns::ToV8String(isolate_, "alloc"), allocFunc).FromMaybe(false);
    assert(success);
}

void MetadataBuilder::RegisterInstanceMethods(Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, std::vector<std::string>& names) {
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        if (!methodMeta->isAvailable()) {
            continue;
        }

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
        if (!propMeta->isAvailable()) {
            continue;
        }

        std::string name = propMeta->jsName();
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            FunctionCallback getter = nullptr;
            FunctionCallback setter = nullptr;
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
                proto->SetAccessorProperty(propName, FunctionTemplate::New(isolate_, getter, ext), FunctionTemplate::New(isolate_, setter, ext), PropertyAttribute::DontDelete, AccessControl::DEFAULT);
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
        if (!methodMeta->isAvailable()) {
            continue;
        }

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

            bool success = ctorFunc->Set(context, tns::ToV8String(isolate_, methodMeta->jsName()), staticMethod).FromMaybe(false);
            assert(success);

            names.push_back(name);
        }
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
    for (auto it = meta->staticProps->begin(); it != meta->staticProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();
        if (!propMeta->isAvailable()) {
            continue;
        }

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

void MetadataBuilder::RegisterStaticProtocols(Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, std::vector<std::string>& names) {
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
    assert(info.IsConstructCall());
    Isolate* isolate = info.GetIsolate();
    CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(info.Data().As<External>()->Value());
    Class klass = objc_getClass(item->meta_->name());

    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(item->meta_);
    ArgConverter::ConstructObject(isolate, info, klass, interfaceMeta);
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() == 0);

    Isolate* isolate = info.GetIsolate();

    Local<Object> thiz = info.This();
    Class klass;

    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass) {
        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
        klass = classWrapper->Klass();
    } else {
        CacheItem<InterfaceMeta>* item = static_cast<CacheItem<InterfaceMeta>*>(info.Data().As<External>()->Value());
        const InterfaceMeta* meta = item->meta_;
        klass = objc_getClass(meta->name());
    }

    id obj = [klass alloc];

    std::string className = class_getName(klass);
    Local<Value> result = ArgConverter::CreateJsWrapper(isolate, new ObjCDataWrapper(className, obj), Local<Object>());
    info.GetReturnValue().Set(result);
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<MethodMeta>* item = static_cast<CacheItem<MethodMeta>*>(info.Data().As<External>()->Value());

    bool instanceMethod = info.This()->InternalFieldCount() > 0;
    std::vector<Local<Value>> args = tns::ArgsToVector(info);

    std::string className = item->className_;

    Local<Object> thiz = info.This();
    if (thiz->IsFunction()) {
        if (BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz)) {
            ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
            className = class_getName(classWrapper->Klass());
        }
    }

    Local<Value> result = instanceMethod
        ? item->builder_->InvokeMethod(isolate, item->meta_, info.This(), args, className, true)
        : item->builder_->InvokeMethod(isolate, item->meta_, Local<Object>(), args, className, true);

    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyGetterCallback(const FunctionCallbackInfo<Value> &info) {
    Local<Object> receiver = info.This();

    if (receiver->InternalFieldCount() < 1) {
        return;
    }

    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());

    Local<Value> result = item->builder_->InvokeMethod(isolate, item->meta_->getter(), receiver, { }, item->className_, true);
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertySetterCallback(const FunctionCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    Local<Object> receiver = info.This();
    Local<Value> value = info[0];
    item->builder_->InvokeMethod(isolate, item->meta_->setter(), receiver, { value }, item->className_, true);
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

void MetadataBuilder::StructPropertyGetterCallback(Local<Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();

    std::string propertyName = tns::ToString(isolate, property);

    if (propertyName == "") {
        info.GetReturnValue().Set(thiz);
        return;
    }

    Local<External> ext = thiz->GetInternalField(0).As<External>();
    StructWrapper* wrapper = static_cast<StructWrapper*>(ext->Value());
    const StructMeta* structMeta = wrapper->Meta();

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
    BaseCall call((uint8_t*)buffer, offset);

    Local<Value> result = Interop::GetResult(isolate, fieldEncoding, &call, false, field.FFIType());

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
    StructWrapper* wrapper = static_cast<StructWrapper*>(ext->Value());
    const StructMeta* structMeta = wrapper->Meta();

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

    std::vector<Local<Value>> args = tns::ArgsToVector(info);
    Local<Value> result = Interop::CallFunction(isolate, item->meta_, nil, nil, args);
    if (item->meta_->encodings()->first()->type != BinaryTypeEncodingType::VoidEncoding) {
        info.GetReturnValue().Set(result);
    }
}

}
