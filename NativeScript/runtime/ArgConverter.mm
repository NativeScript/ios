#include <Foundation/Foundation.h>
#include <sstream>
#include "ArgConverter.h"
#include "NativeScriptException.h"
#include "DictionaryAdapter.h"
#include "ObjectManager.h"
#include "Caches.h"
#include "Interop.h"
#include "Helpers.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate, GenericNamedPropertyGetterCallback structPropertyGetter, GenericNamedPropertySetterCallback structPropertySetter) {
    auto cache = Caches::Get(isolate);
    cache->EmptyObjCtorFunc = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate));
    cache->EmptyStructCtorFunc = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate, structPropertyGetter, structPropertySetter));
}

Local<Value> ArgConverter::Invoke(Isolate* isolate, Class klass, Local<Object> receiver, const std::vector<Local<Value>> args, const MethodMeta* meta, bool isMethodCallback) {
    id target = nil;
    bool instanceMethod = !receiver.IsEmpty();
    bool callSuper = false;
    if (instanceMethod) {
        assert(receiver->InternalFieldCount() > 0);

        Local<External> ext = receiver->GetInternalField(0).As<External>();
        // TODO: Check the actual type of the DataWrapper
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
        target = wrapper->Data();

        std::string className = object_getClassName(target);
        auto cache = Caches::Get(isolate);
        auto it = cache->ClassPrototypes.find(className);
        // For extended classes we will call the base method
        callSuper = isMethodCallback && it != cache->ClassPrototypes.end();
    }

    // TODO: Take into account an optional error out parameter when considering for method overloads - meta->hasErrorOutParameter()
    if (args.size() != meta->encodings()->count - 1) {
        // Arguments number mismatch -> search for a possible method overload in the class hierarchy
        std::string methodName = meta->jsName();
        std::string className = class_getName(klass);
        MemberType type = instanceMethod ? MemberType::InstanceMethod : MemberType::StaticMethod;
        std::vector<const MethodMeta*> overloads;
        ArgConverter::FindMethodOverloads(klass, methodName, type, overloads);
        if (overloads.size() > 0) {
            for (auto it = overloads.begin(); it != overloads.end(); it++) {
                const MethodMeta* methodMeta = (*it);
                if (args.size() == methodMeta->encodings()->count - 1) {
                    meta = methodMeta;
                    break;
                }
            }
        }
    }

    return Interop::CallFunction(isolate, meta, target, klass, args, callSuper);
}

Local<Value> ArgConverter::ConvertArgument(Isolate* isolate, BaseDataWrapper* wrapper) {
    if (wrapper == nullptr) {
        return Null(isolate);
    }

    Local<Value> result = CreateJsWrapper(isolate, wrapper, Local<Object>());
    return result;
}

void ArgConverter::MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData) {
    void (^cb)() = ^{
        MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);

        Isolate* isolate = data->isolate_;

        HandleScope handle_scope(isolate);

        Persistent<Value>* poCallback = data->callback_;
        ObjectWeakCallbackState* weakCallbackState = new ObjectWeakCallbackState(poCallback);
        poCallback->SetWeak(weakCallbackState, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

        std::vector<Local<Value>> v8Args;
        const TypeEncoding* typeEncoding = data->typeEncoding_;
        for (int i = 0; i < data->paramsCount_; i++) {
            typeEncoding = typeEncoding->next();
            int argIndex = i + data->initialParamIndex_;

            uint8_t* argBuffer = (uint8_t*)argValues[argIndex];
            BaseCall call(argBuffer);
            Local<Value> jsWrapper = Interop::GetResult(isolate, typeEncoding, &call, true);

            if (!jsWrapper.IsEmpty()) {
                v8Args.push_back(jsWrapper);
            } else {
                v8Args.push_back(v8::Undefined(isolate));
            }
        }

        Local<Context> context = isolate->GetCurrentContext();
        Local<Object> thiz = context->Global();
        if (data->initialParamIndex_ > 0) {
            id self_ = *static_cast<const id*>(argValues[0]);
            auto cache = Caches::Get(isolate);
            auto it = cache->Instances.find(self_);
            if (it != cache->Instances.end()) {
                thiz = it->second->Get(data->isolate_).As<Object>();
            } else {
                std::string className = object_getClassName(self_);
                ObjCDataWrapper* wrapper = new ObjCDataWrapper(self_);
                thiz = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>()).As<Object>();

                auto it = cache->ClassPrototypes.find(className);
                if (it != cache->ClassPrototypes.end()) {
                    Local<Context> context = isolate->GetCurrentContext();
                    thiz->SetPrototype(context, it->second->Get(isolate)).ToChecked();
                }

                //TODO: We are creating a persistent object here that will never be GCed
                // We need to determine the lifetime of this object
                Persistent<Value>* poObj = new Persistent<Value>(data->isolate_, thiz);
                cache->Instances.insert(std::make_pair(self_, poObj));
            }
        }

        Local<Value> result;
        TryCatch tc(isolate);
        Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();
        if (!callback->Call(context, thiz, (int)v8Args.size(), v8Args.data()).ToLocal(&result)) {
            memset(retValue, 0, cif->rtype->size);
            throw NativeScriptException(isolate, tc, "Error calling function");
        }

        ArgConverter::SetValue(isolate, retValue, result, data->typeEncoding_);
    };

    if ([NSThread isMainThread]) {
        try {
            cb();
        } catch (NativeScriptException& ex) {
            MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);
            Isolate* isolate = data->isolate_;
            ex.ReThrowToV8(isolate);
        }
    } else {
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        tns::ExecuteOnMainThread([cb, group, userData]() {
            try {
                cb();
            } catch (NativeScriptException& ex) {
                MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);
                Isolate* isolate = data->isolate_;
                ex.ReThrowToV8(isolate);
            }
            dispatch_group_leave(group);
        });

        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
            assert(false);
        }
    }
}

void ArgConverter::SetValue(Isolate* isolate, void* retValue, Local<Value> value, const TypeEncoding* typeEncoding) {
    if (typeEncoding->type == BinaryTypeEncodingType::VoidEncoding) {
        return;
    }

    if (value.IsEmpty() || value->IsNullOrUndefined()) {
        void* nullPtr = nullptr;
        *(ffi_arg *)retValue = (unsigned long)nullPtr;
        return;
    }

    // TODO: Refactor this to reuse some existing logic in Interop::SetFFIParams
    BinaryTypeEncodingType type = typeEncoding->type;

    if (tns::IsBool(value)) {
        bool boolValue = value.As<v8::Boolean>()->Value();
        *(ffi_arg *)retValue = (bool)boolValue;
        return;
    } else if (tns::IsNumber(value)) {
        double numValue = tns::ToNumber(isolate, value);
        switch (type) {
            case BinaryTypeEncodingType::UShortEncoding: {
                *static_cast<unsigned short*>(retValue) = (unsigned short)numValue;
                return;
            }
            case BinaryTypeEncodingType::ShortEncoding: {
                *static_cast<short*>(retValue) = (short)numValue;
                return;
            }
            case BinaryTypeEncodingType::UIntEncoding: {
                *static_cast<unsigned int*>(retValue) = (unsigned int)numValue;
                return;
            }
            case BinaryTypeEncodingType::IntEncoding: {
                *static_cast<int*>(retValue) = (int)numValue;
                return;
            }
            case BinaryTypeEncodingType::ULongEncoding: {
                *static_cast<unsigned long*>(retValue) = (unsigned long)numValue;
                return;
            }
            case BinaryTypeEncodingType::LongEncoding: {
                *static_cast<long*>(retValue) = (long)numValue;
                return;
            }
            case BinaryTypeEncodingType::ULongLongEncoding: {
                *static_cast<unsigned long long*>(retValue) = (unsigned long long)numValue;
                return;
            }
            case BinaryTypeEncodingType::LongLongEncoding: {
                *static_cast<long long*>(retValue) = (long long)numValue;
                return;
            }
            case BinaryTypeEncodingType::FloatEncoding: {
                *static_cast<float*>(retValue) = (float)numValue;
                return;
            }
            case BinaryTypeEncodingType::DoubleEncoding: {
                *static_cast<double*>(retValue) = numValue;
                return;
            }
            default:
                return;
        }
    } else if (value->IsString()) {
        if (type == BinaryTypeEncodingType::IdEncoding ||
            type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            std::string strValue = tns::ToString(isolate, value);
            id data = [NSString stringWithUTF8String:strValue.c_str()];
            *(CFTypeRef*)retValue = CFBridgingRetain(data);
            return;
        }
    } else if (value->IsObject()) {
        if (type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
            type == BinaryTypeEncodingType::InstanceTypeEncoding ||
            type == BinaryTypeEncodingType::IdEncoding) {
            BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
            if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::ObjCObject) {
                ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(baseWrapper);
                id data = wrapper->Data();
                memset(retValue, 0, sizeof(id));
                *static_cast<id __strong *>(retValue) = data;
                return;
            } else {
                id adapter = [[DictionaryAdapter alloc] initWithJSObject:value.As<Object>() isolate:isolate];
                memset(retValue, 0, sizeof(id));
                *static_cast<id __strong *>(retValue) = adapter;
                return;
            }
        } else if (type == BinaryTypeEncodingType::StructDeclarationReference) {
            BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
            if (baseWrapper == nullptr) {
                const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
                const Meta* meta = ArgConverter::GetMeta(structName);
                assert(meta != nullptr && meta->type() == MetaType::Struct);
                const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
                StructInfo structInfo = FFICall::GetStructInfo(structMeta);
                Interop::InitializeStruct(isolate, retValue, structInfo.Fields(), value);
                return;
            } else if (baseWrapper->Type() == WrapperType::Struct) {
                StructWrapper* structWrapper = static_cast<StructWrapper*>(baseWrapper);
                size_t size = structWrapper->StructInfo().FFIType()->size;
                void* data = structWrapper->Data();
                memcpy(retValue, data, size);
                return;
            }
        }
    }

    // TODO: Handle other return types, i.e. assign the retValue parameter from the v8 result
    assert(false);
}

void ArgConverter::ConstructObject(Isolate* isolate, const FunctionCallbackInfo<Value>& info, Class klass, const InterfaceMeta* interfaceMeta) {
    assert(klass != nullptr);

    id result = nil;

    if (info.Length() == 1) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info[0]);
        if (wrapper != nullptr && wrapper->Type() == WrapperType::Pointer) {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            result = CFBridgingRelease(pointerWrapper->Data());
        }
    }

    if (result == nil && interfaceMeta == nullptr) {
        const Meta* meta = ArgConverter::FindMeta(klass);
        if (meta != nullptr && meta->type() == MetaType::Interface) {
            interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        }
    }

    if (result == nil && interfaceMeta != nullptr) {
        const MethodMeta* initializer = ArgConverter::FindInitializer(isolate, klass, interfaceMeta, info);
        if (initializer == nullptr) {
            return;
        }

        result = [klass alloc];

        std::vector<Local<Value>> args = tns::ArgsToVector(info);

        result = Interop::CallInitializer(isolate, initializer, result, klass, args);
    }

    if (result == nil) {
        result = [[klass alloc] init];
    }

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(result);
    Local<Object> thiz = info.This();
    ArgConverter::CreateJsWrapper(isolate, wrapper, thiz);

    Persistent<Value>* poThiz = ObjectManager::Register(isolate, thiz);

    auto cache = Caches::Get(isolate);
    auto it = cache->Instances.find(result);
    if (it == cache->Instances.end()) {
        cache->Instances.insert(std::make_pair(result, poThiz));
    } else {
        Local<Value> obj = it->second->Get(isolate);
        info.GetReturnValue().Set(obj);
    }
}

const MethodMeta* ArgConverter::FindInitializer(Isolate* isolate, Class klass, const InterfaceMeta* interfaceMeta, const FunctionCallbackInfo<Value>& info) {
    std::vector<const MethodMeta*> candidates;
    do {
        KnownUnknownClassPair klasses(klass);
        std::vector<const MethodMeta*> initializers = interfaceMeta->initializersWithProtocols(klasses, ProtocolMetas());
        for (const MethodMeta* candidate: initializers) {
            if (ArgConverter::CanInvoke(isolate, candidate, info)) {
                candidates.push_back(candidate);
            }
        }
        interfaceMeta = interfaceMeta->baseMeta();
    } while (interfaceMeta);

    if (candidates.size() == 0) {
        throw NativeScriptException("No initializer found that matches constructor invocation.");
    } else if (candidates.size() > 1) {
        if (info.Length() == 0) {
            auto it = std::find_if(candidates.begin(), candidates.end(), [](const MethodMeta* c) -> bool { return strcmp(c->name(), "init") == 0; });
            if (it != candidates.end()) {
                return (*it);
            }
        }

        std::stringstream ss;
        ss << "More than one initializer found that matches constructor invocation:";
        for (int i = 0; i < candidates.size(); i++) {
            ss << " ";
            ss << candidates[i]->selectorAsString();
        }
        std::string errorMessage = ss.str();
        throw NativeScriptException(errorMessage);
    }

    return candidates[0];
}

bool ArgConverter::CanInvoke(Isolate* isolate, const MethodMeta* candidate, const FunctionCallbackInfo<Value>& info) {
    if (candidate->encodings()->count - 1 != info.Length()) {
        return false;
    }

    if (info.Length() == 0) {
        return true;
    }

    const TypeEncoding* typeEncoding = candidate->encodings()->first();
    for (int i = 0; i < info.Length(); i++) {
        typeEncoding = typeEncoding->next();
        Local<Value> arg = info[i];

        if (!CanInvoke(isolate, typeEncoding, arg)) {
            return false;
        }
    }

    return true;
}

bool ArgConverter::CanInvoke(Isolate* isolate, const TypeEncoding* typeEncoding, Local<Value> arg) {
    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        return true;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
        const char* name = typeEncoding->details.declarationReference.name.valuePtr();
        if (strcmp(name, "NSNumber") == 0 && tns::IsNumber(arg)) {
            return true;
        }

        if (strcmp(name, "NSString") == 0 && tns::IsString(arg)) {
            return true;
        }

        if (strcmp(name, "NSArray") == 0 && arg->IsArray()) {
            return true;
        }
    }

    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        return arg->IsObject();
    }

    if (tns::IsBool(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::BoolEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IdEncoding;
    }

    if (tns::IsNumber(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UShortEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ShortEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UIntEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IntEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ULongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::LongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ULongLongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::LongLongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::FloatEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UCharEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::CharEncoding;
    }

    if (tns::IsString(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UnicharEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::CStringEncoding;
    }

    if (arg->IsFunction()) {
        return typeEncoding->type == BinaryTypeEncodingType::BlockEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding;
    }

    if (arg->IsArrayBuffer() || arg->IsArrayBufferView()) {
        return typeEncoding->type == BinaryTypeEncodingType::IncompleteArrayEncoding;
    }

    return false;
}

Local<Value> ArgConverter::CreateJsWrapper(Isolate* isolate, BaseDataWrapper* wrapper, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (wrapper == nullptr) {
        return Null(isolate);
    }

    if (wrapper->Type() == WrapperType::Struct) {
        if (receiver.IsEmpty()) {
            receiver = CreateEmptyStruct(context);
        }

        StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
        StructInfo structInfo = structWrapper->StructInfo();
        auto cache = Caches::Get(isolate);
        Local<v8::Function> structCtorFunc = cache->StructCtorInitializer(isolate, structInfo);
        Local<Value> proto;
        bool success = structCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&proto);
        assert(success);

        if (!proto.IsEmpty()) {
            bool success = receiver->SetPrototype(context, proto).FromMaybe(false);
            assert(success);
        }

        tns::SetValue(isolate, receiver, structWrapper);

        return receiver;
    }

    id target = nil;
    if (wrapper->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
        target = dataWrapper->Data();
    }

    if (target == nil) {
        return Null(isolate);
    }

    auto cache = Caches::Get(isolate);
    if (receiver.IsEmpty()) {
       auto it = cache->Instances.find(target);
       if (it != cache->Instances.end()) {
           receiver = it->second->Get(isolate).As<Object>();
       } else {
           receiver = CreateEmptyObject(context);
           cache->Instances.insert(std::make_pair(target, new Persistent<Value>(isolate, receiver)));
       }
   }

    Class klass = [target class];
    const Meta* meta = FindMeta(klass);
    if (meta != nullptr) {
        std::string className = object_getClassName(target);
        auto it = cache->ClassPrototypes.find(className);
        if (it != cache->ClassPrototypes.end()) {
            Local<Value> prototype = it->second->Get(isolate);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                assert(false);
            }
        } else {
            cache->ObjectCtorInitializer(isolate, static_cast<const BaseClassMeta*>(meta));
            auto it = cache->Prototypes.find(meta);
            if (it != cache->Prototypes.end()) {
                Local<Value> prototype = it->second->Get(isolate);
                bool success;
                if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                    assert(false);
                }
            }
        }
    }

    Class metaClass = object_getClass(target);
    if (class_isMetaClass(metaClass)) {
        if (tns::GetValue(isolate, receiver) == nullptr) {
            ObjCClassWrapper* wrapper = new ObjCClassWrapper(klass);
            tns::SetValue(isolate, receiver, wrapper);
        }
    }

    tns::SetValue(isolate, receiver, wrapper);

    return receiver;
}

const Meta* ArgConverter::FindMeta(Class klass) {
    std::string origClassName = class_getName(klass);
    const Meta* meta = Caches::Metadata.Get(origClassName);
    if (meta != nullptr) {
        return meta;
    }

    std::string className = origClassName;

    while (true) {
        const Meta* result = GetMeta(className);
        if (result != nullptr) {
            Caches::Metadata.Insert(origClassName, result);
            return result;
        }

        klass = class_getSuperclass(klass);
        if (klass == nullptr) {
            break;
        }

        className = class_getName(klass);
    }

    return nullptr;
}

const Meta* ArgConverter::GetMeta(std::string name) {
    const Meta* meta = Caches::Metadata.Get(name);
    if (meta != nullptr) {
        return meta;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const Meta* result = globalTable->findMeta(name.c_str(), false /** onlyIfAvailable **/);

    if (result == nullptr) {
        return nullptr;
    }

    return result;
}

const ProtocolMeta* ArgConverter::FindProtocolMeta(Protocol* protocol) {
    std::string protocolName = protocol_getName(protocol);
    const Meta* meta = ArgConverter::GetMeta(protocolName);
    if (meta != nullptr && meta->type() != MetaType::ProtocolType) {
        std::string newProtocolName = protocolName + "Protocol";

        size_t protocolIndex = 2;
        while (objc_getProtocol(newProtocolName.c_str())) {
            newProtocolName = protocolName + "Protocol" + std::to_string(protocolIndex++);
        }

        meta = ArgConverter::GetMeta(newProtocolName);
    }

    if (meta == nullptr) {
        return nullptr;
    }

    assert(meta->type() == MetaType::ProtocolType);
    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(meta);
    return protocolMeta;
}

Local<Object> ArgConverter::CreateEmptyObject(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Persistent<v8::Function>* ctorFunc = Caches::Get(isolate)->EmptyObjCtorFunc;
    assert(ctorFunc != nullptr);
    return ArgConverter::CreateEmptyInstance(context, ctorFunc);
}

Local<Object> ArgConverter::CreateEmptyStruct(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Persistent<v8::Function>* ctorFunc = Caches::Get(isolate)->EmptyStructCtorFunc;
    assert(ctorFunc != nullptr);
    return ArgConverter::CreateEmptyInstance(context, ctorFunc);
}

Local<Object> ArgConverter::CreateEmptyInstance(Local<Context> context, Persistent<v8::Function>* ctorFunc) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> emptyCtorFunc = ctorFunc->Get(isolate);
    Local<Value> value;
    if (!emptyCtorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        assert(false);
    }
    Local<Object> result = value.As<Object>();

    ObjectManager::Register(isolate, result);

    return result;
}

Local<v8::Function> ArgConverter::CreateEmptyInstanceFunction(Isolate* isolate, GenericNamedPropertyGetterCallback propertyGetter, GenericNamedPropertySetterCallback propertySetter) {
    Local<FunctionTemplate> emptyInstanceCtorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    Local<ObjectTemplate> instanceTemplate = emptyInstanceCtorFuncTemplate->InstanceTemplate();
    instanceTemplate->SetInternalFieldCount(2);

    if (propertyGetter != nullptr || propertySetter != nullptr) {
        NamedPropertyHandlerConfiguration config(propertyGetter, propertySetter);
        instanceTemplate->SetHandler(config);
    }

    instanceTemplate->SetIndexedPropertyHandler(IndexedPropertyGetterCallback, IndexedPropertySetterCallback);

    Local<v8::Function> emptyInstanceCtorFunc;
    if (!emptyInstanceCtorFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&emptyInstanceCtorFunc)) {
        assert(false);
    }
    return emptyInstanceCtorFunc;
}

void ArgConverter::IndexedPropertyGetterCallback(uint32_t index, const PropertyCallbackInfo<Value>& args) {
    Local<Object> thiz = args.This();
    Isolate* isolate = args.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = objcDataWrapper->Data();
    if (![target isKindOfClass:[NSArray class]]) {
        return;
    }

    NSArray* array = (NSArray*)target;
    if (index >= [array count]) {
        return;
    }

    id obj = [array objectAtIndex:index];
    Local<Value> result = ArgConverter::ConvertArgument(isolate, new ObjCDataWrapper(obj));
    args.GetReturnValue().Set(result);
}

void ArgConverter::IndexedPropertySetterCallback(uint32_t index, Local<Value> value, const PropertyCallbackInfo<Value>& args) {
    Local<Object> thiz = args.This();
    Isolate* isolate = args.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper == nullptr && wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = objcDataWrapper->Data();
    if (![target isKindOfClass:[NSMutableArray class]]) {
        return;
    }

    NSMutableArray* array = (NSMutableArray*)target;
    if (index >= [array count]) {
        return;
    }

    BaseDataWrapper* itemWrapper = tns::GetValue(isolate, value);
    if (itemWrapper == nullptr || itemWrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcItemDataWrapper = static_cast<ObjCDataWrapper*>(itemWrapper);
    id item = objcItemDataWrapper->Data();
    [target replaceObjectAtIndex:index withObject:item];
}

void ArgConverter::FindMethodOverloads(Class klass, std::string methodName, MemberType type, std::vector<const MethodMeta*>& overloads) {
    const Meta* meta = ArgConverter::FindMeta(klass);
    if (klass == nullptr || meta == nullptr || meta->type() != MetaType::Interface) {
        return;
    }

    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    MembersCollection members = interfaceMeta->members(methodName.c_str(), methodName.length(), type, true, true, ProtocolMetas());
    for (auto it = members.begin(); it != members.end(); it++) {
        const MethodMeta* methodMeta = static_cast<const MethodMeta*>(*it);
        overloads.push_back(methodMeta);
    }

    if (interfaceMeta->baseName() != nullptr) {
        Class baseClass = objc_getClass(interfaceMeta->baseName());
        ArgConverter::FindMethodOverloads(baseClass, methodName, type, overloads);
    }
}

}
