#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Caches.h"
#include "Interop.h"
#include "Interop_impl.h"
#include "Helpers.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate, GenericNamedPropertyGetterCallback structPropertyGetter, GenericNamedPropertySetterCallback structPropertySetter) {
    poEmptyObjCtorFunc_ = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate));
    poEmptyStructCtorFunc_ = new Persistent<v8::Function>(isolate, ArgConverter::CreateEmptyInstanceFunction(isolate, structPropertyGetter, structPropertySetter));
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
        auto it = Caches::ClassPrototypes.find(className);
        // For extended classes we will call the base method
        callSuper = isMethodCallback && it != Caches::ClassPrototypes.end();
    }

    // TODO: Take into account an optional error out parameter when considering for method overloads - meta->hasErrorOutParameter()
    if (args.size() != meta->encodings()->count - 1) {
        // Arguments number mismatch -> search for a possible method overload in the class hierarchy
        std::string methodName = meta->jsName();
        std::string className = class_getName(klass);
        MemberType type = instanceMethod ? MemberType::InstanceMethod : MemberType::StaticMethod;
        std::vector<const MethodMeta*> overloads;
        ArgConverter::FindMethodOverloads(className, methodName, type, overloads);
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
    // TODO: Check the actual DataWrapper type
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

        Persistent<Object>* poCallback = data->callback_;
        ObjectWeakCallbackState* weakCallbackState = new ObjectWeakCallbackState(poCallback);
        poCallback->SetWeak(weakCallbackState, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

        Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();

        std::vector<Local<Value>> v8Args;
        const TypeEncoding* typeEncoding = data->typeEncoding_;
        for (int i = 0; i < data->paramsCount_; i++) {
            typeEncoding = typeEncoding->next();
            int argIndex = i + data->initialParamIndex_;

            uint8_t* argBuffer = (uint8_t*)argValues[argIndex];
            BaseCall call(argBuffer);
            Local<Value> jsWrapper = Interop::GetResult(isolate, typeEncoding, &call, true);

            v8Args.push_back(jsWrapper);
        }

        Local<Context> context = isolate->GetCurrentContext();
        Local<Object> thiz = context->Global();
        if (data->initialParamIndex_ > 0) {
            id self_ = *static_cast<const id*>(argValues[0]);
            auto it = Caches::Instances.find(self_);
            if (it != Caches::Instances.end()) {
                thiz = it->second->Get(data->isolate_);
            } else {
                std::string className = object_getClassName(self_);
                ObjCDataWrapper* wrapper = new ObjCDataWrapper(className, self_);
                thiz = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>()).As<Object>();

                auto it = Caches::ClassPrototypes.find(className);
                if (it != Caches::ClassPrototypes.end()) {
                    Local<Context> context = isolate->GetCurrentContext();
                    thiz->SetPrototype(context, it->second->Get(isolate)).ToChecked();
                }

                //TODO: We are creating a persistent object here that will never be GCed
                // We need to determine the lifetime of this object
                Persistent<Object>* poObj = new Persistent<Object>(data->isolate_, thiz);
                Caches::Instances.insert(std::make_pair(self_, poObj));
            }
        }

        Local<Value> result;
        if (!callback->Call(context, thiz, (int)v8Args.size(), v8Args.data()).ToLocal(&result)) {
            assert(false);
        }

        if (!result.IsEmpty() && !result->IsUndefined()) {
            if (result->IsNumber() || result->IsNumberObject()) {
                if (data->typeEncoding_->type == BinaryTypeEncodingType::LongEncoding) {
                    long value = result.As<Number>()->Value();
                    *static_cast<long*>(retValue) = value;
                    return;
                } else if (data->typeEncoding_->type == BinaryTypeEncodingType::DoubleEncoding) {
                    double value = result.As<Number>()->Value();
                    *static_cast<double*>(retValue) = value;
                    return;
                }
            } else if (result->IsObject()) {
                if (data->typeEncoding_->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
                    data->typeEncoding_->type == BinaryTypeEncodingType::InstanceTypeEncoding ||
                    data->typeEncoding_->type == BinaryTypeEncodingType::IdEncoding) {
                    Local<External> ext = result.As<Object>()->GetInternalField(0).As<External>();
                    ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
                    id data = wrapper->Data();
                    *(ffi_arg*)retValue = (unsigned long)data;
                    return;
                }
            } else if (result->IsBoolean()) {
                bool boolValue = result.As<v8::Boolean>()->Value();
                *(ffi_arg *)retValue = (bool)boolValue;
                return;
            }

            // TODO: Handle other return types, i.e. assign the retValue parameter from the v8 result
            assert(false);
        }
    };

    if ([NSThread isMainThread]) {
        cb();
    } else {
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb();
            dispatch_group_leave(group);
        });

        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
            assert(false);
        }
    }
}

Local<Value> ArgConverter::CreateJsWrapper(Isolate* isolate, BaseDataWrapper* wrapper, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (wrapper == nullptr) {
        return Null(isolate);
    }

    if (wrapper->Type() == WrapperType::Record) {
        if (receiver.IsEmpty()) {
            receiver = CreateEmptyStruct(context);
        }

        if (wrapper->Type() == WrapperType::Record) {
            StructDataWrapper* structWrapper = static_cast<StructDataWrapper*>(wrapper);
            if (structWrapper->Metadata()->type() == MetaType::Struct) {
                const StructMeta* structMeta = static_cast<const StructMeta*>(structWrapper->Metadata());

                auto it = Caches::StructConstructorFunctions.find(structMeta);
                if (it != Caches::StructConstructorFunctions.end()) {
                    Local<v8::Function> structCtorFunc = it->second->Get(isolate);
                    Local<Value> proto = structCtorFunc->Get(tns::ToV8String(isolate, "prototype"));
                    if (!proto.IsEmpty()) {
                        bool success = receiver->SetPrototype(context, proto).FromMaybe(false);
                        assert(success);
                    }
                }
            }
        }

        Local<External> ext = External::New(isolate, wrapper);
        receiver->SetInternalField(0, ext);

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

   if (receiver.IsEmpty()) {
       auto it = Caches::Instances.find(target);
       if (it != Caches::Instances.end()) {
           receiver = it->second->Get(isolate);
       } else {
           receiver = CreateEmptyObject(context);
           Caches::Instances.insert(std::make_pair(target, new Persistent<Object>(isolate, receiver)));
       }
   }

    Class klass = [target class];
    const Meta* meta = FindMeta(klass);
    if (meta != nullptr) {
        std::string className = object_getClassName(target);
        auto it = Caches::ClassPrototypes.find(className);
        if (it != Caches::ClassPrototypes.end()) {
            Local<Value> prototype = it->second->Get(isolate);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                assert(false);
            }
        } else {
            auto it = Caches::Prototypes.find(meta);
            if (it != Caches::Prototypes.end()) {
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
        Local<Value> metadataProp = tns::GetPrivateValue(isolate, receiver, tns::ToV8String(isolate, "metadata"));
        if (metadataProp.IsEmpty() || !metadataProp->IsExternal()) {
            ObjCDataWrapper* wrapper = new ObjCDataWrapper(class_getName(klass), klass);
            Local<External> extendedData = External::New(isolate, wrapper);
            tns::SetPrivateValue(isolate, receiver, tns::ToV8String(isolate, "metadata"), extendedData);
        }
    }

    Local<External> ext = External::New(isolate, wrapper);
    receiver->SetInternalField(0, ext);

    return receiver;
}

const Meta* ArgConverter::FindMeta(Class klass) {
    std::string origClassName = class_getName(klass);
    auto it = Caches::Metadata.find(origClassName);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    std::string className = origClassName;

    while (true) {
        const Meta* result = GetMeta(className);
        if (result != nullptr) {
            Caches::Metadata.insert(std::make_pair(origClassName, result));
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
    auto it = Caches::Metadata.find(name);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const Meta* result = globalTable->findMeta(name.c_str());

    if (result == nullptr) {
        return nullptr;
    }

    return result;
}

Local<Object> ArgConverter::CreateEmptyObject(Local<Context> context) {
    return ArgConverter::CreateEmptyInstance(context, poEmptyObjCtorFunc_);
}

Local<Object> ArgConverter::CreateEmptyStruct(Local<Context> context) {
    return ArgConverter::CreateEmptyInstance(context, poEmptyStructCtorFunc_);
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
    instanceTemplate->SetInternalFieldCount(1);

    NamedPropertyHandlerConfiguration config(propertyGetter, propertySetter);
    instanceTemplate->SetHandler(config);

    Local<v8::Function> emptyInstanceCtorFunc;
    if (!emptyInstanceCtorFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&emptyInstanceCtorFunc)) {
        assert(false);
    }
    return emptyInstanceCtorFunc;
}

void ArgConverter::FindMethodOverloads(std::string className, std::string methodName, MemberType type, std::vector<const MethodMeta*>& overloads) {
    const Meta* meta = ArgConverter::GetMeta(className);
    if (meta == nullptr || meta->type() != MetaType::Interface) {
        return;
    }

    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    MembersCollection members = interfaceMeta->members(methodName.c_str(), methodName.length(), type);
    for (auto it = members.begin(); it != members.end(); it++) {
        const MethodMeta* methodMeta = static_cast<const MethodMeta*>(*it);
        overloads.push_back(methodMeta);
    }

    if (interfaceMeta->baseName() != nullptr) {
        ArgConverter::FindMethodOverloads(interfaceMeta->baseName(), methodName, type, overloads);
    }
}

Persistent<v8::Function>* ArgConverter::poEmptyObjCtorFunc_;
Persistent<v8::Function>* ArgConverter::poEmptyStructCtorFunc_;

}
