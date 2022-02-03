#include <Foundation/Foundation.h>
#include "MetadataBuilder.h"
#include "NativeScriptException.h"
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "InlineFunctions.h"
#include "SymbolLoader.h"
#include "Constants.h"
#include "Helpers.h"
#include "Interop.h"
#include "Worker.h"
#include "Caches.h"
#include "Tasks.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace tns {

void MetadataBuilder::RegisterConstantsOnGlobalObject(Isolate* isolate, Local<ObjectTemplate> globalTemplate, bool isWorkerThread) {
    GlobalHandlerContext* handlerContext = new GlobalHandlerContext(isWorkerThread);
    Local<External> ext = External::New(isolate, handlerContext);

    NamedPropertyHandlerConfiguration config(MetadataBuilder::GlobalPropertyGetter, nullptr, nullptr, nullptr, nullptr, ext, PropertyHandlerFlags::kNonMasking);
    globalTemplate->SetHandler(config);
}

void MetadataBuilder::GlobalPropertyGetter(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    std::string propName = tns::ToString(isolate, property);

    GlobalHandlerContext* ctx = static_cast<GlobalHandlerContext*>(info.Data().As<External>()->Value());

    if (ctx->isWorkerThread_ && std::find(Worker::GlobalFunctions.begin(), Worker::GlobalFunctions.end(), propName) != Worker::GlobalFunctions.end()) {
        return;
    }

    if (InlineFunctions::IsGlobalFunction(propName)) {
        return;
    }

    const Meta* meta = ArgConverter::GetMeta(propName);
    if (meta == nullptr || !meta->isAvailable()) {
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();

    if (meta->type() == MetaType::Interface || meta->type() == MetaType::ProtocolType) {
        const BaseClassMeta* classMeta = static_cast<const BaseClassMeta*>(meta);
        Class knownClass = meta->type() == MetaType::Interface ? objc_getClass(meta->name()) : nil;
        KnownUnknownClassPair pair(knownClass);
        MetadataBuilder::GetOrCreateConstructorFunctionTemplate(context, classMeta, pair);

        bool isInterface = meta->type() == MetaType::Interface;
        std::string name = meta->name();
        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        if (isInterface) {
            auto it = cache->CtorFuncs.find(name);
            if (it != cache->CtorFuncs.end()) {
                Local<v8::Function> func = it->second->Get(isolate);
                info.GetReturnValue().Set(func);
            }
        } else {
            auto it = cache->ProtocolCtorFuncs.find(name);
            if (it != cache->ProtocolCtorFuncs.end()) {
                Local<v8::Function> func = it->second->Get(isolate);
                info.GetReturnValue().Set(func);
            }
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
        void* functionPointer = SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
        if (functionPointer == nullptr) {
            Log(@"Unable to load \"%s\" function", meta->name());
            tns::Assert(false, isolate);
        }

        CacheItem<FunctionMeta>* item = new CacheItem<FunctionMeta>(funcMeta, std::string(), functionPointer);
        Local<External> ext = External::New(isolate, item);
        Local<v8::Function> func;
        bool success = v8::Function::New(context, CFunctionCallback, ext).ToLocal(&func);
        tns::Assert(success, isolate);

        tns::SetValue(isolate, func, new FunctionWrapper(funcMeta));
        MetadataBuilder::DefineFunctionLengthProperty(context, funcMeta->encodings(), func);

        cache->CFunctions.emplace(funcName, std::make_unique<Persistent<v8::Function>>(isolate, func));

        info.GetReturnValue().Set(func);
    } else if (meta->type() == MetaType::Var) {
        void* dataSymbol = SymbolLoader::instance().loadDataSymbol(meta->topLevelModule(), meta->name());
        if (!dataSymbol) {
            return;
        }

        const VarMeta* varMeta = static_cast<const VarMeta*>(meta);

        BaseCall bc((uint8_t*)dataSymbol);
        const TypeEncoding* typeEncoding = varMeta->encoding();
        Local<Value> result = Interop::GetResult(context, typeEncoding, &bc, true);
        info.GetReturnValue().Set(result);
    } else if (meta->type() == MetaType::JsCode) {
        const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
        std::string jsCode = jsCodeMeta->jsCode();
        Local<Script> script;
        if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
            tns::Assert(false, isolate);
        }
        tns::Assert(!script.IsEmpty(), isolate);

        Local<Value> result;
        if (!script->Run(context).ToLocal(&result)) {
            tns::Assert(false, isolate);
        }
        info.GetReturnValue().Set(result);
    } else if (meta->type() == MetaType::Struct) {
        const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
        StructInfo structInfo = FFICall::GetStructInfo(structMeta);
        Local<v8::Function> structCtorFunc = MetadataBuilder::GetOrCreateStructCtorFunction(context, structInfo);
        info.GetReturnValue().Set(structCtorFunc);
    }
}

Local<v8::Function> MetadataBuilder::GetOrCreateStructCtorFunction(Local<Context> context, StructInfo structInfo) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    auto it = cache->StructConstructorFunctions.find(structInfo.Name());
    if (it != cache->StructConstructorFunctions.end()) {
        return it->second->Get(isolate);
    }

    StructTypeWrapper* wrapper = new StructTypeWrapper(structInfo);
    Local<External> ext = External::New(isolate, wrapper);
    Local<v8::Function> structCtorFunc;
    bool success = v8::Function::New(context, StructConstructorCallback, ext).ToLocal(&structCtorFunc);
    tns::Assert(success, isolate);

    tns::SetValue(isolate, structCtorFunc, wrapper);

    Local<v8::Function> equalsFunc;
    success = v8::Function::New(context, StructEqualsCallback).ToLocal(&equalsFunc);
    tns::Assert(success, isolate);

    success = structCtorFunc->Set(context, tns::ToV8String(isolate, "equals"), equalsFunc).FromMaybe(false);
    tns::Assert(success, isolate);

    cache->StructConstructorFunctions.emplace(structInfo.Name(), std::make_unique<Persistent<v8::Function>>(isolate, structCtorFunc));

    return structCtorFunc;
}

void MetadataBuilder::StructConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    try {
        StructTypeWrapper* typeWrapper = static_cast<StructTypeWrapper*>(info.Data().As<External>()->Value());

        StructInfo structInfo = typeWrapper->StructInfo();

        void* dest = nullptr;

        if (info.IsConstructCall()) {
            // A new structure is allocated
            Local<Value> initializer = info.Length() > 0 ? info[0] : Local<Value>();
            dest = malloc(structInfo.FFIType()->size);
            Interop::InitializeStruct(context, dest, structInfo.Fields(), initializer);
        } else {
            // The structure is not used as constructor and in this case we assume a pointer is passed to the function
            // This pointer will be used as backing memory for the structure
            BaseDataWrapper* wrapper = nullptr;
            if (info.Length() < 1 || !(wrapper = tns::GetValue(isolate, info[0])) || wrapper->Type() != WrapperType::Pointer) {
                throw NativeScriptException("A pointer instance must be passed to the structure initializer");
            }

            PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
            dest = pw->Data();
        }

        StructWrapper* wrapper = new StructWrapper(structInfo, dest, nullptr);
        Local<Context> context = isolate->GetCurrentContext();
        Local<Value> result = ArgConverter::ConvertArgument(context, wrapper);

        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        std::shared_ptr<Persistent<Value>> poResult = ObjectManager::Register(context, result);
        std::pair<void*, std::string> key = std::make_pair(wrapper->Data(), structInfo.Name());
        cache->StructInstances.emplace(key, poResult);

        info.GetReturnValue().Set(result);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void MetadataBuilder::StructEqualsCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    tns::Assert(info.Length() == 2, isolate);

    Local<Object> arg1 = info[0].As<Object>();
    Local<Object> arg2 = info[1].As<Object>();

    if (arg1.IsEmpty() || !arg1->IsObject() || arg1->IsNullOrUndefined() ||
        arg2.IsEmpty() || !arg2->IsObject() || arg2->IsNullOrUndefined()) {
        info.GetReturnValue().Set(false);
        return;
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
    if (wrapper == nullptr || wrapper->Type() != WrapperType::StructType) {
        info.GetReturnValue().Set(false);
        return;
    }

    StructTypeWrapper* structTypeWrapper = static_cast<StructTypeWrapper*>(wrapper);
    StructInfo structInfo = structTypeWrapper->StructInfo();

    std::pair<ffi_type*, void*> pair1 = MetadataBuilder::GetStructData(context, arg1, structInfo);
    std::pair<ffi_type*, void*> pair2 = MetadataBuilder::GetStructData(context, arg2, structInfo);

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

std::pair<ffi_type*, void*> MetadataBuilder::GetStructData(Local<Context> context, Local<Object> initializer, StructInfo structInfo) {
    ffi_type* ffiType = nullptr;
    void* data = nullptr;

    if (initializer->InternalFieldCount() < 1) {
        ffiType = structInfo.FFIType();
        data = malloc(ffiType->size);
        Interop::InitializeStruct(context, data, structInfo.Fields(), initializer);
    } else {
        Local<External> ext = initializer->GetInternalField(0).As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        if (wrapper->Type() != WrapperType::Struct) {
            return std::make_pair(ffiType, data);
        }

        StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
        data = structWrapper->Data();
        ffiType = structWrapper->StructInfo().FFIType();
    }

    return std::make_pair(ffiType, data);
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplate(Local<Context> context, const BaseClassMeta* meta, KnownUnknownClassPair pair, const std::vector<std::string>& additionalProtocols) {
    robin_hood::unordered_map<std::string, uint8_t> instanceMembers;
    robin_hood::unordered_map<std::string, uint8_t> staticMembers;
    return MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(context, meta, pair, instanceMembers, staticMembers, additionalProtocols);
}

Local<FunctionTemplate> MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(Local<Context> context, const BaseClassMeta* meta, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& instanceMembers, robin_hood::unordered_map<std::string, uint8_t>& staticMembers, const std::vector<std::string>& additionalProtocols) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> ctorFuncTemplate;
    auto cache = Caches::Get(isolate);

    if (additionalProtocols.empty()) {
        auto it = cache->CtorFuncTemplates.find(meta);
        if (it != cache->CtorFuncTemplates.end()) {
            ctorFuncTemplate = it->second->Get(isolate);
            return ctorFuncTemplate;
        }
    }

    std::string className;
    CacheItem<BaseClassMeta>* item = new CacheItem<BaseClassMeta>(meta, className);
    Local<External> ext = External::New(isolate, item);

    ctorFuncTemplate = FunctionTemplate::New(isolate, ClassConstructorCallback, ext);
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, meta->name()));

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
                    Local<FunctionTemplate> baseCtorFuncTemplate = MetadataBuilder::GetOrCreateConstructorFunctionTemplateInternal(context, baseMeta, pair, instanceMembers, staticMembers);
                    ctorFuncTemplate->Inherit(baseCtorFuncTemplate);
                    auto it = cache->CtorFuncs.find(baseMeta->name());
                    if (it != cache->CtorFuncs.end()) {
                        baseCtorFunc = it->second->Get(isolate);
                    }
                }
            }
            break;
        }
    }

    MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, meta, meta->name(), pair, instanceMembers);
    MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, meta, pair, instanceMembers);
    MetadataBuilder::RegisterInstanceProtocols(context, ctorFuncTemplate, meta, meta->name(), pair, instanceMembers);
    MetadataBuilder::RegisterAdditionalProtocols(context, ctorFuncTemplate, pair, additionalProtocols, instanceMembers);

    ctorFuncTemplate->PrototypeTemplate()->Set(tns::ToV8String(isolate, "toString"), FunctionTemplate::New(isolate, MetadataBuilder::ToStringFunctionCallback));

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        MetadataBuilder::RegisterAllocMethod(isolate, ctorFuncTemplate, interfaceMeta);
        ctorFuncTemplate->Set(tns::ToV8String(isolate, "extend"), ClassBuilder::GetExtendFunction(isolate, interfaceMeta));
    }

    NamedPropertyHandlerConfiguration config(nullptr, MetadataBuilder::SwizzledInstanceMethodCallback, nullptr, nullptr, nullptr, MetadataBuilder::SwizzledPropertyCallback, nullptr, ext);
    ctorFuncTemplate->PrototypeTemplate()->SetHandler(config);

    Local<v8::Function> ctorFunc;
    bool success = ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc);
    tns::Assert(success, isolate);

    if (meta->type() == MetaType::ProtocolType) {
        const ProtocolMeta* protoMeta = static_cast<const ProtocolMeta*>(meta);
        tns::SetValue(isolate, ctorFunc, new ObjCProtocolWrapper(objc_getProtocol(meta->name()), protoMeta));
        cache->ProtocolCtorFuncs.emplace(meta->name(), new Persistent<v8::Function>(isolate, ctorFunc));
    } else {
        Class klass = objc_getClass(meta->name());
        if (klass == nil) {
            SymbolLoader::instance().ensureModule(meta->topLevelModule());
            klass = objc_getClass(meta->name());
        }
        tns::SetValue(isolate, ctorFunc, new ObjCClassWrapper(klass));
        cache->CtorFuncs.emplace(meta->name(), std::make_unique<Persistent<v8::Function>>(isolate, ctorFunc));
    }

    Local<Object> global = context->Global();
    success = global->Set(context, tns::ToV8String(isolate, meta->jsName()), ctorFunc).FromMaybe(false);
    tns::Assert(success, isolate);

    if (!baseCtorFunc.IsEmpty()) {
        bool success;
        if (!ctorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            tns::Assert(false, isolate);
        }
    }

    MetadataBuilder::RegisterStaticMethods(context, ctorFunc, meta, pair, staticMembers);
    MetadataBuilder::RegisterStaticProperties(context, ctorFunc, meta, meta->name(), pair, staticMembers);
    MetadataBuilder::RegisterStaticProtocols(context, ctorFunc, meta, meta->name(), pair, staticMembers);

    cache->CtorFuncTemplates.emplace(meta, std::make_unique<Persistent<FunctionTemplate>>(isolate, ctorFuncTemplate));

    Local<Value> prototypeValue;
    success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
    tns::Assert(success, isolate);
    Local<Object> prototype = prototypeValue.As<Object>();

    Persistent<Value>* poPrototype = new Persistent<Value>(isolate, prototype);
    cache->Prototypes.emplace(meta, poPrototype);

    return ctorFuncTemplate;
}

void MetadataBuilder::ToStringFunctionCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);

    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
        info.GetReturnValue().Set(thiz);
        return;
    }

    ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = dataWrapper->Data();
    if (target == nil) {
        info.GetReturnValue().Set(thiz);
        return;
    }

    std::string description = [[target description] UTF8String];
    Local<v8::String> returnValue = tns::ToV8String(info.GetIsolate(), description);
    info.GetReturnValue().Set(returnValue);
}

void MetadataBuilder::RegisterAllocMethod(Isolate* isolate, Local<FunctionTemplate> ctorFuncTemplate, const InterfaceMeta* interfaceMeta) {
    std::string className;
    CacheItem<InterfaceMeta>* item = new CacheItem<InterfaceMeta>(interfaceMeta, className);
    Local<External> ext = External::New(isolate, item);
    Local<FunctionTemplate> allocFuncTemplate = FunctionTemplate::New(isolate, AllocCallback, ext);
    ctorFuncTemplate->Set(tns::ToV8String(isolate, "alloc"), allocFuncTemplate);
}

void MetadataBuilder::RegisterInstanceMethods(Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    Isolate* isolate = context->GetIsolate();
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        if (!methodMeta->isAvailableInClasses(pair, false)) {
            continue;
        }

        std::string methodName = methodMeta->name();
        auto methodsIt = names.find(methodName);
        if (methodsIt == names.end()) {
            CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name());
            Local<External> ext = External::New(isolate, item);
            Local<FunctionTemplate> instanceMethodTemplate = FunctionTemplate::New(isolate, MethodCallback, ext);
            proto->Set(tns::ToV8String(isolate, methodMeta->jsName()), instanceMethodTemplate);
            names.emplace(methodName, 0);
        }
    }
}

void MetadataBuilder::RegisterInstanceProperties(Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, const std::string className, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    Isolate* isolate = context->GetIsolate();
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();
        if (!propMeta->isAvailableInClasses(pair, false)) {
            continue;
        }

        uint8_t accessors = 0;
        if (propMeta->hasGetter()) {
            accessors++;
        }
        if (propMeta->hasSetter()) {
            accessors++;
        }

        std::string propertyName = propMeta->name();
        auto propertiesIt = names.find(propertyName);
        if (accessors > 0 && (propertiesIt == names.end() || propertiesIt->second < accessors)) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className);
            Local<External> ext = External::New(isolate, item);
            Local<FunctionTemplate> getter = FunctionTemplate::New(isolate, PropertyGetterCallback, ext);
            Local<FunctionTemplate> setter = FunctionTemplate::New(isolate, PropertySetterCallback, ext);
            proto->SetAccessorProperty(tns::ToV8String(isolate, propMeta->jsName()), getter, setter, PropertyAttribute::None, AccessControl::DEFAULT);
            names.emplace(propertyName, accessors);
        }
    }
}

void MetadataBuilder::RegisterInstanceProtocols(Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, const BaseClassMeta* meta, const std::string className, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    if (meta->type() == MetaType::ProtocolType) {
        MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, meta, pair, names);
        MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, meta, className, pair, names);
    }

    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName.c_str());
        if (m != nullptr) {
            const BaseClassMeta* protoMeta = static_cast<const BaseClassMeta*>(m);
            MetadataBuilder::RegisterInstanceProtocols(context, ctorFuncTemplate, protoMeta, className, pair, names);
        }
    }
}

void MetadataBuilder::RegisterAdditionalProtocols(Local<Context> context, Local<FunctionTemplate> ctorFuncTemplate, KnownUnknownClassPair pair, const std::vector<std::string>& additionalProtocols, robin_hood::unordered_map<std::string, uint8_t>& names) {
    for (std::string protocolName : additionalProtocols) {
        const Meta* meta = ArgConverter::GetMeta(protocolName.c_str());
        if (meta != nullptr) {
            const BaseClassMeta* baseMeta = static_cast<const BaseClassMeta*>(meta);
            MetadataBuilder::RegisterInstanceMethods(context, ctorFuncTemplate, baseMeta, pair, names);
            MetadataBuilder::RegisterInstanceProperties(context, ctorFuncTemplate, baseMeta, baseMeta->name(), pair, names);

            std::vector<std::string> metaProtocols;
            for (auto it = baseMeta->protocols->begin(); it != baseMeta->protocols->end(); it++) {
                std::string name = (*it).valuePtr();
                metaProtocols.push_back(name);
            }

            MetadataBuilder::RegisterAdditionalProtocols(context, ctorFuncTemplate, pair, metaProtocols, names);
        }
    }
}

void MetadataBuilder::RegisterStaticMethods(Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    Isolate* isolate = context->GetIsolate();
    for (auto it = meta->staticMethods->begin(); it != meta->staticMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        if (!methodMeta->isAvailableInClasses(pair, true)) {
            continue;
        }

        std::string methodName = methodMeta->name();
        auto methodsIt = names.find(methodName);
        if (methodsIt == names.end()) {
            CacheItem<MethodMeta>* item = new CacheItem<MethodMeta>(methodMeta, meta->name());
            Local<External> ext = External::New(isolate, item);
            Local<FunctionTemplate> staticMethodTemplate = FunctionTemplate::New(isolate, MethodCallback, ext);
            Local<v8::Function> staticMethod;
            if (!staticMethodTemplate->GetFunction(context).ToLocal(&staticMethod)) {
                tns::Assert(false, isolate);
            }

            DefineFunctionLengthProperty(context, methodMeta->encodings(), staticMethod);

            if (!ctorFunc->Has(context, tns::ToV8String(isolate, methodMeta->jsName())).FromJust()) {
                bool success = ctorFunc->Set(context, tns::ToV8String(isolate, methodMeta->jsName()), staticMethod).FromMaybe(false);
                tns::Assert(success, isolate);
            }

            names.emplace(methodName, 0);
            
        }
    }
}

void MetadataBuilder::RegisterStaticProperties(Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    Isolate* isolate = context->GetIsolate();

    for (auto it = meta->staticProps->begin(); it != meta->staticProps->end(); it++) {
        const PropertyMeta* propMeta = (*it).valuePtr();
        if (!propMeta->isAvailableInClasses(pair, true)) {
            continue;
        }

        uint8_t accessors = 0;
        if (propMeta->hasGetter()) {
            accessors++;
        }

        if (propMeta->hasSetter()) {
            accessors++;
        }

        std::string propertyName = propMeta->name();
        auto propertiesIt = names.find(propertyName);
        if (accessors > 0 && (propertiesIt == names.end() || propertiesIt->second < accessors)) {
            CacheItem<PropertyMeta>* item = new CacheItem<PropertyMeta>(propMeta, className);
            Local<External> ext = External::New(isolate, item);

            Local<v8::String> propName = tns::ToV8String(isolate, propMeta->jsName());
            bool success;
            Maybe<bool> maybeSuccess = ctorFunc->SetAccessor(context, propName, PropertyNameGetterCallback, PropertyNameSetterCallback, ext, AccessControl::DEFAULT, PropertyAttribute::DontDelete);
            if (!maybeSuccess.To(&success) || !success) {
                tns::Assert(false, isolate);
            }
            names.emplace(propertyName, accessors);
        }
    }
}

void MetadataBuilder::RegisterStaticProtocols(Local<Context> context, Local<v8::Function> ctorFunc, const BaseClassMeta* meta, const std::string className, KnownUnknownClassPair pair, robin_hood::unordered_map<std::string, uint8_t>& names) {
    if (meta->type() == MetaType::ProtocolType) {
        MetadataBuilder::RegisterStaticMethods(context, ctorFunc, meta, pair, names);
        MetadataBuilder::RegisterStaticProperties(context, ctorFunc, meta, className, pair, names);
    }

    const GlobalTable<GlobalTableType::ByJsName>* globalTable = MetaFile::instance()->globalTableJs();
    for (auto itProto = meta->protocols->begin(); itProto != meta->protocols->end(); itProto++) {
        std::string protocolName = (*itProto).valuePtr();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());
        if (protoMeta != nullptr) {
            MetadataBuilder::RegisterStaticProtocols(context, ctorFunc, protoMeta, className, pair, names);
        }
    }
}

void MetadataBuilder::ClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    tns::Assert(info.IsConstructCall(), isolate);
    try {
        CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(info.Data().As<External>()->Value());
        Class klass = objc_getClass(item->meta_->name());

        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(item->meta_);
        ArgConverter::ConstructObject(context, info, klass, interfaceMeta);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void MetadataBuilder::AllocCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    tns::Assert(info.Length() == 0, isolate);

    try {
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

        Local<Context> context = isolate->GetCurrentContext();
        ObjCAllocDataWrapper* allocWrapper = new ObjCAllocDataWrapper(klass);
        Local<Value> result = ArgConverter::CreateJsWrapper(context, allocWrapper, Local<Object>());
        info.GetReturnValue().Set(result);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void MetadataBuilder::MethodCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<MethodMeta>* item = static_cast<CacheItem<MethodMeta>*>(info.Data().As<External>()->Value());

    bool instanceMethod = info.This()->InternalFieldCount() > 0;
    V8FunctionCallbackArgs args(info);

    std::string className = item->className_;

    Local<Object> thiz = info.This();
    if (thiz->IsFunction()) {
        if (BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz)) {
            ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
            className = class_getName(classWrapper->Klass());
        }
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = instanceMethod
        ? MetadataBuilder::InvokeMethod(context, item->meta_, info.This(), args, className, true)
        : MetadataBuilder::InvokeMethod(context, item->meta_, Local<Object>(), args, className, true);

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
    if (!item->meta_->hasGetter()) {
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Property is not readable."));
        isolate->ThrowException(error);
        return;
    }

    V8EmptyValueArgs args;
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = MetadataBuilder::InvokeMethod(context, item->meta_->getter(), receiver, args, item->className_, true);
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertySetterCallback(const FunctionCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    if (!item->meta_->hasSetter()) {
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Attempted to assign to readonly property."));
        isolate->ThrowException(error);
        return;
    }

    Local<Object> receiver = info.This();
    Local<Value> value = info[0];
    V8SimpleValueArgs args(value);
    Local<Context> context = isolate->GetCurrentContext();
    MetadataBuilder::InvokeMethod(context, item->meta_->setter(), receiver, args, item->className_, true);
}

void MetadataBuilder::PropertyNameGetterCallback(Local<v8::Name> name, const PropertyCallbackInfo<Value> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    if (!item->meta_->hasGetter()) {
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Property is not readable."));
        isolate->ThrowException(error);
        return;
    }

    V8EmptyValueArgs args;
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = MetadataBuilder::InvokeMethod(context, item->meta_->getter(), Local<Object>(), args, item->className_, false);
    if (!result.IsEmpty()) {
        info.GetReturnValue().Set(result);
    }
}

void MetadataBuilder::PropertyNameSetterCallback(Local<v8::Name> name, Local<Value> value, const PropertyCallbackInfo<void> &info) {
    Isolate* isolate = info.GetIsolate();
    CacheItem<PropertyMeta>* item = static_cast<CacheItem<PropertyMeta>*>(info.Data().As<External>()->Value());
    if (!item->meta_->hasSetter()) {
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, "Attempted to assign to readonly property."));
        isolate->ThrowException(error);
        return;
    }

    V8SimpleValueArgs args(value);
    Local<Context> context = isolate->GetCurrentContext();
    MetadataBuilder::InvokeMethod(context, item->meta_->setter(), Local<Object>(), args, item->className_, false);
}

void MetadataBuilder::StructPropertyGetterCallback(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();

    std::string propertyName = tns::ToString(isolate, property);

    if (propertyName == "") {
        info.GetReturnValue().Set(thiz);
        return;
    }

    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, thiz);
    tns::Assert(baseWrapper != nullptr && baseWrapper->Type() == WrapperType::Struct, isolate);
    StructWrapper* wrapper = static_cast<StructWrapper*>(baseWrapper);

    StructInfo structInfo = wrapper->StructInfo();

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    std::pair<void*, std::string> key = std::make_pair(wrapper->Data(), structInfo.Name());
    std::shared_ptr<Persistent<Value>> parentStruct = nullptr;
    auto x = cache->StructInstances.find(key);
    if (x != cache->StructInstances.end()) {
        parentStruct = x->second;
    }

    std::vector<StructField> fields = structInfo.Fields();
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

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = Interop::GetResult(context, fieldEncoding, &call, false, parentStruct, true);

    info.GetReturnValue().Set(result);
}

void MetadataBuilder::StructPropertySetterCallback(Local<v8::Name> property, Local<Value> value, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> thiz = info.This();

    std::string propertyName = tns::ToString(isolate, property);

    if (propertyName == "") {
        info.GetReturnValue().Set(thiz);
        return;
    }

    Local<External> ext = thiz->GetInternalField(0).As<External>();
    StructWrapper* wrapper = static_cast<StructWrapper*>(ext->Value());

    StructInfo structInfo = wrapper->StructInfo();
    std::vector<StructField> fields = structInfo.Fields();

    auto it = std::find_if(fields.begin(), fields.end(), [&propertyName](StructField &f) { return f.Name() == propertyName; });
    if (it == fields.end()) {
        return;
    }

    StructField field = *it;
    Interop::SetStructPropertyValue(context, wrapper, field, value);
}

void MetadataBuilder::DefineFunctionLengthProperty(Local<Context> context, const TypeEncodingsList<ArrayCount>* encodings, Local<v8::Function> func) {
    Isolate* isolate = context->GetIsolate();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    int paramsCount = std::max(0, encodings->count - 1);
    bool success = func->DefineOwnProperty(context, tns::ToV8String(isolate, "length"), Number::New(isolate, paramsCount), readOnlyFlags).FromMaybe(false);
    tns::Assert(success, isolate);
}

Local<Value> MetadataBuilder::InvokeMethod(Local<Context> context, const MethodMeta* meta, Local<Object> receiver, V8Args& args, std::string containingClass, bool isMethodCallback) {
    Class klass = objc_getClass(containingClass.c_str());
    // TODO: Find out if the isMethodCallback property can be determined based on a UITableViewController.prototype.viewDidLoad.call(this) or super.viewDidLoad() call

    if (RuntimeConfig.IsDebug) {
        NSString* message = [NSString stringWithFormat:@"MetadataBuilder::InvokeMethod class {%s}, selector {%s}, isInitializer {%s}, type {%s}, lib {%s}",
                             containingClass.c_str(),
                             meta->selectorAsString(),
                             meta->isInitializer() ? "true":"false",
                             meta->typeName(),
                             meta->topLevelModule()->getName()];
        Log(@"%@", message);
    }
    
    try {
        return ArgConverter::Invoke(context, klass, receiver, args, meta, isMethodCallback);
    } catch (NativeScriptException& ex) {
        Isolate* isolate = context->GetIsolate();
        ex.ReThrowToV8(isolate);
        return Local<Value>();
    }
}

void MetadataBuilder::CFunctionCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    try {
        CacheItem<FunctionMeta>* item = static_cast<CacheItem<FunctionMeta>*>(info.Data().As<External>()->Value());

        if (strcmp(item->meta_->jsName(), "UIApplicationMain") == 0) {
            std::vector<std::shared_ptr<Persistent<Value>>> args;
            for (int i = 0; i < info.Length(); i++) {
                args.push_back(std::make_shared<Persistent<Value>>(isolate, info[i]));
            }

            Tasks::Register([isolate, item, args]() {
                v8::Locker locker(isolate);
                Isolate::Scope isolate_scope(isolate);
                HandleScope handle_scope(isolate);
                std::vector<Local<Value>> localArgs;
                localArgs.reserve(args.size());
                for (int i = 0; i < args.size(); i++) {
                    Local<Value> arg = args[i]->Get(isolate);
                    localArgs.push_back(arg);
                }
                const TypeEncoding* typeEncoding = item->meta_->encodings()->first();
                V8VectorArgs vectorArgs(localArgs);
                Local<Context> context = Caches::Get(isolate)->GetContext();
                v8::Unlocker unlocker(isolate);
                CMethodCall methodCall(context, item->userData_, typeEncoding, vectorArgs, item->meta_->ownsReturnedCocoaObject(), false);
                Interop::CallFunction(methodCall);
            });

            return;
        }

        V8FunctionCallbackArgs args(info);
        const TypeEncoding* typeEncoding = item->meta_->encodings()->first();
        Local<Context> context = isolate->GetCurrentContext();
        const FunctionMeta* funcMeta = item->meta_;
        CMethodCall methodCall(context, item->userData_, typeEncoding, args, funcMeta->ownsReturnedCocoaObject(), funcMeta->returnsUnmanaged());
        Local<Value> result = Interop::CallFunction(methodCall);

        if (typeEncoding->type != BinaryTypeEncodingType::VoidEncoding) {
            info.GetReturnValue().Set(result);
        }
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void MetadataBuilder::SwizzledInstanceMethodCallback(Local<v8::Name> property, Local<Value> value, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    std::string methodName = tns::ToString(isolate, property);

    CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(info.Data().As<External>()->Value());
    const BaseClassMeta* meta = item->meta_;

    Class klass = objc_getClass(meta->name());
    if (klass == nil) {
        return;
    }

    int index = meta->instanceMethods->binarySearch([methodName](const PtrTo<MethodMeta>& current) {
        const MethodMeta* methodMeta = current.valuePtr();
        return strcmp(methodMeta->jsName(), methodName.c_str());
    });

    if (index < 0) {
        return;
    }

    const MethodMeta* methodMeta = meta->instanceMethods->operator[](index).valuePtr();

    const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
    int argsCount = methodMeta->encodings()->count - 1;
    std::string compilerEncoding = ClassBuilder::GetTypeEncoding(typeEncoding, argsCount);
    std::shared_ptr<Persistent<Value>> poCallback = std::make_shared<Persistent<Value>>(isolate, value);
    MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
    IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
    IMP nativeImp = class_replaceMethod(klass, methodMeta->selector(), methodBody, compilerEncoding.c_str());
    if (nativeImp) {
        std::string selector = methodMeta->selectorAsString();
        SEL nativeSelector = sel_registerName((Constants::SwizzledPrefix + selector).c_str());
        class_addMethod(klass, nativeSelector, nativeImp, compilerEncoding.c_str());
    }
}

void MetadataBuilder::SwizzledPropertyCallback(Local<v8::Name> property, const PropertyDescriptor& desc, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    std::string propertyName = tns::ToString(isolate, property);

    CacheItem<BaseClassMeta>* item = static_cast<CacheItem<BaseClassMeta>*>(info.Data().As<External>()->Value());
    const BaseClassMeta* meta = item->meta_;

    Class klass = objc_getClass(meta->name());
    if (klass == nil) {
        return;
    }

    int index = meta->instanceProps->binarySearch([propertyName](const PtrTo<PropertyMeta>& current) {
        const PropertyMeta* propertyMeta = current.valuePtr();
        return strcmp(propertyMeta->jsName(), propertyName.c_str());
    });

    if (index < 0) {
        return;
    }

    const PropertyMeta* propertyMeta = meta->instanceProps->operator[](index).valuePtr();

    if (desc.has_get()) {
        FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
            PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
            v8::Locker locker(context->isolate_);
            Isolate::Scope isolate_scope(context->isolate_);
            HandleScope handle_scope(context->isolate_);
            Local<v8::Function> getterFunc = context->callback_->Get(context->isolate_);
            Local<Value> res;

            id thiz = *static_cast<const id*>(argValues[0]);
            auto cache = Caches::Get(context->isolate_);
            auto it = cache->Instances.find(thiz);

            Local<Context> v8Context = Caches::Get(context->isolate_)->GetContext();
            Local<Object> self_ = it != cache->Instances.end()
                ? it->second->Get(context->isolate_).As<Object>()
                : ArgConverter::CreateJsWrapper(v8Context, new ObjCDataWrapper(thiz), Local<Object>()).As<Object>();
            tns::Assert(getterFunc->Call(v8Context, self_, 0, nullptr).ToLocal(&res), context->isolate_);

            const TypeEncoding* typeEncoding = context->meta_->getter()->encodings()->first();
            ArgConverter::SetValue(v8Context, retValue, res, typeEncoding);
        };

        const char* compilerEncoding = "@@:";
        const TypeEncoding* typeEncoding = propertyMeta->getter()->encodings()->first();

        Local<Value> getter = desc.get();
        std::shared_ptr<Persistent<v8::Function>> poGetterFunc = std::make_shared<Persistent<v8::Function>>(isolate, getter.As<v8::Function>());
        PropertyCallbackContext* userData = new PropertyCallbackContext(isolate, poGetterFunc, nullptr, propertyMeta);
        IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback, userData);
        IMP nativeImp = class_replaceMethod(klass, propertyMeta->getter()->selector(), impGetter, compilerEncoding);
        std::string selector = propertyMeta->getter()->selectorAsString();
        SEL nativeSelector = sel_registerName((Constants::SwizzledPrefix + selector).c_str());
        class_addMethod(klass, nativeSelector, nativeImp, compilerEncoding);
    }

    if (desc.has_set()) {
        FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
            PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
            v8::Locker locker(context->isolate_);
            Isolate::Scope isolate_scope(context->isolate_);
            HandleScope handle_scope(context->isolate_);
            Local<v8::Function> setterFunc = context->callback_->Get(context->isolate_);
            Local<Value> res;

            Local<Context> v8Context = Caches::Get(context->isolate_)->GetContext();

            id thiz = *static_cast<const id*>(argValues[0]);
            auto cache = Caches::Get(context->isolate_);
            auto it = cache->Instances.find(thiz);
            Local<Object> self_ = it != cache->Instances.end()
                ? it->second->Get(context->isolate_).As<Object>()
                : ArgConverter::CreateJsWrapper(v8Context, new ObjCDataWrapper(thiz), Local<Object>()).As<Object>();

            uint8_t* argBuffer = (uint8_t*)argValues[2];
            const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
            BaseCall call(argBuffer);
            Local<Value> jsWrapper = Interop::GetResult(v8Context, typeEncoding, &call, true);
            Local<Value> params[1] = { jsWrapper };

            tns::Assert(setterFunc->Call(context->isolate_->GetCurrentContext(), self_, 1, params).ToLocal(&res), context->isolate_);
        };

        const TypeEncoding* typeEncoding = propertyMeta->setter()->encodings()->first();
        Local<Value> setter = desc.set();
        std::shared_ptr<Persistent<v8::Function>> poSetterFunc = std::make_shared<Persistent<v8::Function>>(isolate, setter.As<v8::Function>());
        PropertyCallbackContext* userData = new PropertyCallbackContext(isolate, poSetterFunc, nullptr, propertyMeta);
        IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

        const char* compilerEncoding = "v@:@";
        IMP nativeImp = class_replaceMethod(klass, propertyMeta->setter()->selector(), impSetter, compilerEncoding);
        std::string selector = propertyMeta->setter()->selectorAsString();
        SEL nativeSelector = sel_registerName((Constants::SwizzledPrefix + selector).c_str());
        class_addMethod(klass, nativeSelector, nativeImp, compilerEncoding);
    }
}

}
