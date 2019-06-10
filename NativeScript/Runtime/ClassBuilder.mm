#include <Foundation/Foundation.h>
#include "ClassBuilder.h"
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Caches.h"
#include "Interop.h"

using namespace v8;

namespace tns {

Local<v8::Function> ClassBuilder::GetExtendFunction(Local<Context> context, const InterfaceMeta* interfaceMeta) {
    Isolate* isolate = context->GetIsolate();
    CacheItem* item = new CacheItem(interfaceMeta, nullptr, this);
    Local<External> ext = External::New(isolate, item);

    Local<v8::Function> extendFunc;

    if (!v8::Function::New(context, ExtendCallback, ext).ToLocal(&extendFunc)) {
        assert(false);
    }

    return extendFunc;
}

void ClassBuilder::ExtendCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() > 0 && info[0]->IsObject() && info.This()->IsFunction());

    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

    Local<Object> implementationObject = info[0].As<Object>();
    Local<v8::Function> baseFunc = info.This().As<v8::Function>();
    std::string baseClassName = tns::ToString(isolate, baseFunc->GetName());

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const InterfaceMeta* interfaceMeta = globalTable->findInterfaceMeta(baseClassName.c_str());
    assert(interfaceMeta != nullptr);

    Local<Object> nativeSignature;
    std::string staticClassName;
    if (info.Length() > 1 && info[1]->IsObject()) {
        nativeSignature = info[1].As<Object>();
        Local<Value> explicitClassName;
        assert(nativeSignature->Get(context, tns::ToV8String(isolate, "name")).ToLocal(&explicitClassName));
        if (!explicitClassName.IsEmpty() && !explicitClassName->IsNullOrUndefined()) {
            staticClassName = tns::ToString(isolate, explicitClassName);
        }
    }

    Class extendedClass = item->self_->GetExtendedClass(baseClassName, staticClassName);
    if (!nativeSignature.IsEmpty()) {
        Local<Value> exposedProtocols = nativeSignature->Get(tns::ToV8String(isolate, "protocols"));
        if (!exposedProtocols.IsEmpty() && exposedProtocols->IsArray()) {
            item->self_->ExposeDynamicProtocols(isolate, extendedClass, implementationObject, exposedProtocols.As<v8::Array>());
        }

        item->self_->ExposeDynamicMembers(isolate, extendedClass, implementationObject, nativeSignature);
    }

    Persistent<v8::Function>* poBaseCtorFunc = Caches::CtorFuncs.find(item->meta_->name())->second;
    Local<v8::Function> baseCtorFunc = poBaseCtorFunc->Get(isolate);

    CacheItem* cacheItem = new CacheItem(nullptr, extendedClass, item->self_);
    Local<External> ext = External::New(isolate, cacheItem);
    Local<FunctionTemplate> extendedClassCtorFuncTemplate = FunctionTemplate::New(isolate, ExtendedClassConstructorCallback, ext);
    extendedClassCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    Local<v8::Function> extendClassCtorFunc;
    if (!extendedClassCtorFuncTemplate->GetFunction(context).ToLocal(&extendClassCtorFunc)) {
        assert(false);
    }

    bool success;
    if (!implementationObject->SetPrototype(context, baseCtorFunc->Get(tns::ToV8String(isolate, "prototype"))).To(&success) || !success) {
        assert(false);
    }
    if (!implementationObject->SetAccessor(context, tns::ToV8String(isolate, "super"), SuperAccessorGetterCallback, nullptr, ext).To(&success) || !success) {
        assert(false);
    }

    extendClassCtorFunc->SetName(tns::ToV8String(isolate, class_getName(extendedClass)));
    Local<Object> extendFuncPrototype = extendClassCtorFunc->Get(tns::ToV8String(isolate, "prototype")).As<Object>();
    if (!extendFuncPrototype->SetPrototype(context, implementationObject).To(&success) || !success) {
        assert(false);
    }

    if (!extendClassCtorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
        assert(false);
    }

    std::string extendedClassName = class_getName(extendedClass);
    ObjCDataWrapper* wrapper = new ObjCDataWrapper(extendedClassName, extendedClass);
    Local<External> extendedData = External::New(isolate, wrapper);
    tns::SetPrivateValue(isolate, extendClassCtorFunc, tns::ToV8String(isolate, "metadata"), extendedData);

    Caches::CtorFuncs.emplace(std::make_pair(extendedClassName, new Persistent<v8::Function>(isolate, extendClassCtorFunc)));
    Caches::ClassPrototypes.emplace(std::make_pair(extendedClassName, new Persistent<Object>(isolate, extendFuncPrototype)));

    info.GetReturnValue().Set(extendClassCtorFunc);
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

    id obj = [[item->data_ alloc] init];

    const char* className = class_getName(item->data_);
    ObjCDataWrapper* wrapper = new ObjCDataWrapper(className, obj);
    Local<External> ext = External::New(isolate, wrapper);

    Local<Object> thiz = info.This();
    thiz->SetInternalField(0, ext);

    Persistent<Object>* poThiz = new Persistent<Object>(isolate, thiz);
    Caches::Instances.insert(std::make_pair(obj, poThiz));

    ObjectManager::Register(isolate, thiz);
}

void ClassBuilder::RegisterBaseTypeScriptExtendsFunction(Isolate* isolate) {
    if (poOriginalExtendsFunc_ != nullptr) {
        return;
    }

    std::string extendsFuncScript =
        "(function() { "
        "    function __extends(d, b) { "
        "         for (var p in b) {"
        "             if (b.hasOwnProperty(p)) {"
        "                 d[p] = b[p];"
        "             }"
        "         }"
        "         function __() { this.constructor = d; }"
        "         d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());"
        "    } "
        "    return __extends;"
        "})()";

    Local<Context> context = isolate->GetCurrentContext();
    Local<Script> script;
    assert(Script::Compile(context, tns::ToV8String(isolate, extendsFuncScript.c_str())).ToLocal(&script));

    Local<Value> extendsFunc;
    assert(script->Run(context).ToLocal(&extendsFunc) && extendsFunc->IsFunction());

    poOriginalExtendsFunc_ = new Persistent<v8::Function>(isolate, extendsFunc.As<v8::Function>());
}

void ClassBuilder::RegisterNativeTypeScriptExtendsFunction(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<v8::Function> extendsFunc = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 2);
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        ClassBuilder* builder = static_cast<ClassBuilder*>(info.Data().As<External>()->Value());

        Local<Value> metadataProp = tns::GetPrivateValue(isolate, info[1].As<Object>(), tns::ToV8String(isolate, "metadata"));
        if (metadataProp.IsEmpty() || !metadataProp->IsExternal()) {
            // We are not extending a native object -> call the base __extends function
            Local<v8::Function> originalExtendsFunc = poOriginalExtendsFunc_->Get(isolate);
            Local<Value> args[] = { info[0], info[1] };
            originalExtendsFunc->Call(context, context->Global(), info.Length(), args).ToLocalChecked();
            return;
        }

        Local<External> superExt = metadataProp.As<External>();
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(superExt->Value());
        Class baseClass = wrapper->Data();
        std::string baseClassName = class_getName(baseClass);

        Local<v8::Function> extendedClassCtorFunc = info[0].As<v8::Function>();
        std::string extendedClassName = tns::ToString(isolate, extendedClassCtorFunc->GetName());

        Class extendedClass = builder->GetExtendedClass(baseClassName, extendedClassName);

        tns::SetPrivateValue(isolate, extendedClassCtorFunc, tns::ToV8String(isolate, "metadata"), External::New(isolate, new ObjCDataWrapper(extendedClassName, nil)));

        const Meta* baseMeta = ArgConverter::FindMeta(baseClass);
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(baseMeta);
        Persistent<v8::Function>* poBaseCtorFunc = Caches::CtorFuncs.find(interfaceMeta->name())->second;

        Local<v8::Function> baseCtorFunc = poBaseCtorFunc->Get(isolate);
        assert(extendedClassCtorFunc->SetPrototype(context, baseCtorFunc).ToChecked());

        Local<v8::String> prototypeProp = tns::ToV8String(isolate, "prototype");
        Local<Object> extendedClassCtorFuncPrototype = extendedClassCtorFunc->Get(prototypeProp).As<Object>();
        extendedClassCtorFuncPrototype->SetPrototype(context, baseCtorFunc->Get(prototypeProp).As<Object>()).ToChecked();
        Caches::ClassPrototypes.emplace(std::make_pair(extendedClassName, new Persistent<Object>(isolate, extendedClassCtorFuncPrototype)));

        Persistent<v8::Function>* poExtendedClassCtorFunc = new Persistent<v8::Function>(isolate, extendedClassCtorFunc);

        Caches::CtorFuncs.emplace(std::make_pair(extendedClassName, poExtendedClassCtorFunc));

        IMP newInitialize = imp_implementationWithBlock(^(id self) {
            Local<v8::Function> extendedClassCtorFunc = poExtendedClassCtorFunc->Get(isolate);

            Local<Value> exposedMethods = extendedClassCtorFunc->Get(tns::ToV8String(isolate, "ObjCExposedMethods"));
            Local<Value> implementationObject = extendedClassCtorFunc->Get(tns::ToV8String(isolate, "prototype"));
            if (implementationObject.IsEmpty() || exposedMethods.IsEmpty()) {
                return;
            }

            Local<Value> exposedProtocols = extendedClassCtorFunc->Get(tns::ToV8String(isolate, "ObjCProtocols"));
            if (!exposedProtocols.IsEmpty() && exposedProtocols->IsArray()) {
                builder->ExposeDynamicProtocols(isolate, extendedClass, implementationObject.As<Object>(), exposedProtocols.As<v8::Array>());
            }

            builder->ExposeDynamicMethods(isolate, extendedClass, exposedMethods.As<Object>(), implementationObject.As<Object>());

            poExtendedClassCtorFunc->Reset();
        });
        class_addMethod(object_getClass(extendedClass), @selector(initialize), newInitialize, "v@:");

        info.GetReturnValue().Set(v8::Undefined(isolate));
    }, External::New(isolate, this)).ToLocalChecked();

    global->Set(tns::ToV8String(isolate, "__extends"), extendsFunc);
}

void ClassBuilder::ExposeDynamicMembers(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
      Local<Value> exposedMethods = nativeSignature->Get(tns::ToV8String(isolate, "exposedMethods"));
      this->ExposeDynamicMethods(isolate, extendedClass, exposedMethods, implementationObject);
}

void ClassBuilder::ExposeDynamicMethods(Isolate* isolate, Class extendedClass, Local<Value> exposedMethods, Local<Object> implementationObject) {
    Local<Context> context = isolate->GetCurrentContext();

    if (!exposedMethods.IsEmpty() && exposedMethods->IsObject()) {
        Local<v8::Array> methodNames;
        if (!exposedMethods.As<Object>()->GetOwnPropertyNames(context).ToLocal(&methodNames)) {
            assert(false);
        }

        for (int i = 0; i < methodNames->Length(); i++) {
            Local<Value> methodName = methodNames->Get(i);
            Local<Value> methodSignature = exposedMethods.As<Object>()->Get(methodName);
            assert(methodSignature->IsObject());
            Local<Value> method = implementationObject->Get(methodName);
            if (method.IsEmpty() || !method->IsFunction()) {
                assert(false);
            }

            BinaryTypeEncodingType returnType = BinaryTypeEncodingType::VoidEncoding;

            Local<Value> returnsVal = methodSignature.As<Object>()->Get(tns::ToV8String(isolate, "returns"));
            if (!returnsVal.IsEmpty() && returnsVal->IsObject()) {
                Local<Object> returnsObj = returnsVal.As<Object>();
                if (returnsObj->InternalFieldCount() > 0) {
                    Local<External> ext = returnsObj->GetInternalField(0).As<External>();
                    PrimitiveDataWrapper* pdw = static_cast<PrimitiveDataWrapper*>(ext->Value());
                    returnType = pdw->EncodingType();
                } else {
                    Local<Value> val = tns::GetPrivateValue(isolate, returnsObj, tns::ToV8String(isolate, "metadata"));
                    if (!val.IsEmpty() && val->IsExternal()) {
                        returnType = BinaryTypeEncodingType::PointerEncoding;
                    }
                }
            }

            // TODO: Prepare the TypeEncoding* from the v8 arguments and return type.
            std::string typeInfo = "v@:@";
            int argsCount = 1;
            std::string methodNameStr = tns::ToString(isolate, methodName);
            SEL selector = NSSelectorFromString([NSString stringWithUTF8String:(methodNameStr).c_str()]);

            TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(calloc(2, sizeof(TypeEncoding)));
            typeEncoding->type = returnType;
            TypeEncoding* next = reinterpret_cast<TypeEncoding*>(reinterpret_cast<char*>(typeEncoding) + sizeof(BinaryTypeEncodingType));
            next->type = BinaryTypeEncodingType::InterfaceDeclarationReference;

            Persistent<Value>* poCallback = new Persistent<Value>(isolate, method);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
            IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str());
        }
    }

    const Meta* m = ArgConverter::FindMeta(extendedClass);
    if (m == nullptr) {
        return;
    }

    const BaseClassMeta* extendedClassMeta = static_cast<const BaseClassMeta*>(m);

    Local<v8::Array> propertyNames;
    assert(implementationObject->GetOwnPropertyNames(context).ToLocal(&propertyNames));
    for (uint32_t i = 0; i < propertyNames->Length(); i++) {
        Local<Value> key = propertyNames->Get(i);
        std::string methodName = tns::ToString(isolate, key);

        const BaseClassMeta* meta = extendedClassMeta;
        while (meta != nullptr) {
            const MethodMeta* methodMeta = nullptr;

            for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
                const MethodMeta* mm = (*it).valuePtr();
                if (strcmp(mm->jsName(), methodName.c_str()) == 0) {
                    methodMeta = mm;
                    break;
                }
            }

            if (methodMeta == nullptr) {
                for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
                    const char* protocolName = (*protoIt).valuePtr();
                    const Meta* m = ArgConverter::GetMeta(protocolName);
                    if (!m) {
                        continue;
                    }
                    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
                    for (auto it = protocolMeta->instanceMethods->begin(); it != protocolMeta->instanceMethods->end(); it++) {
                        const MethodMeta* mm = (*it).valuePtr();
                        if (strcmp(mm->jsName(), methodName.c_str()) == 0) {
                            methodMeta = mm;
                            break;
                        }
                    }
                }
            }

            if (methodMeta == nullptr) {
                unsigned count;
                auto pl = class_copyProtocolList(extendedClass, &count);

                for (unsigned i = 0; i < count; i++) {
                    const char* protocolName = protocol_getName(pl[i]);
                    const Meta* meta = ArgConverter::GetMeta(protocolName);
                    if (meta == nullptr || meta->type() != MetaType::ProtocolType) {
                        continue;
                    }

                    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(meta);
                    for (auto it = protocolMeta->instanceMethods->begin(); it != protocolMeta->instanceMethods->end(); it++) {
                        const MethodMeta* mm = (*it).valuePtr();
                        if (strcmp(mm->jsName(), methodName.c_str()) == 0) {
                            methodMeta = mm;
                            break;
                        }
                    }
                }

                free(pl);
            }

            if (methodMeta != nullptr) {
                Local<Value> method = implementationObject->Get(key);
                if (!method.IsEmpty() && method->IsFunction()) {
                    Persistent<Value>* poCallback = new Persistent<Value>(isolate, method);
                    const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
                    uint8_t argsCount = methodMeta->encodings()->count - 1;
                    MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
                    SEL selector = methodMeta->selector();
                    IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
                    class_addMethod(extendedClass, selector, methodBody, "v@:@");
                }
            }

            if (meta->type() == MetaType::Interface) {
                const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
                meta = interfaceMeta->baseMeta();
            } else {
                break;
            }
        }
    }
}

void ClassBuilder::ExposeDynamicProtocols(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<v8::Array> protocols) {
    for (uint32_t i = 0; i < protocols->Length(); i++) {
        Local<Value> element = protocols->Get(i);
        assert(!element.IsEmpty() && element->IsFunction());

        Local<v8::Function> protoObj = element.As<v8::Function>();
        Local<Value> metadataProp = tns::GetPrivateValue(isolate, protoObj, tns::ToV8String(isolate, "metadata"));
        assert(!metadataProp.IsEmpty() && metadataProp->IsExternal());

        Local<External> ext = metadataProp.As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        std::string protocolName = wrapper->Name();
        Protocol* proto = objc_getProtocol(protocolName.c_str());
        assert(proto != nullptr);

        if (class_conformsToProtocol(extendedClass, proto)) {
            continue;
        }

        class_addProtocol(extendedClass, proto);

        const GlobalTable* globalTable = MetaFile::instance()->globalTable();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName.c_str());

        Local<v8::Array> propertyNames;
        Local<Context> context = isolate->GetCurrentContext();
        assert(implementationObject->GetPropertyNames(context).ToLocal(&propertyNames));

        for (uint32_t j = 0; j < propertyNames->Length(); j++) {
            Local<Value> descriptor;
            Local<Name> propName = propertyNames->Get(j).As<Name>();
            assert(implementationObject->GetOwnPropertyDescriptor(context, propName).ToLocal(&descriptor));
            if (descriptor.IsEmpty() || descriptor->IsNullOrUndefined()) {
                continue;
            }

            Local<Value> getter = descriptor.As<Object>()->Get(tns::ToV8String(isolate, "get"));
            Local<Value> setter = descriptor.As<Object>()->Get(tns::ToV8String(isolate, "set"));

            bool hasGetter = !getter.IsEmpty() && getter->IsFunction();
            bool hasSetter = !setter.IsEmpty() && setter->IsFunction();
            if (!hasGetter && !hasSetter) {
                continue;
            }

            std::string propertyName = tns::ToString(isolate, propName);

            for (auto propIt = protoMeta->instanceProps->begin(); propIt != protoMeta->instanceProps->end(); propIt++) {
                const PropertyMeta* propMeta = (*propIt).valuePtr();
                if (strcmp(propMeta->jsName(), propertyName.c_str()) != 0) {
                    continue;
                }

                // An instance property that is part of the protocol is defined in the implementation object
                // so we need to define it on the new class
                objc_property_t property = protocol_getProperty(proto, propertyName.c_str(), true, true);
                uint attrsCount;
                objc_property_attribute_t* propertyAttrs = property_copyAttributeList(property, &attrsCount);
                class_addProperty(extendedClass, propertyName.c_str(), propertyAttrs, attrsCount);

                if (hasGetter && propMeta->hasGetter()) {
                    Persistent<v8::Function>* poGetterFunc = new Persistent<v8::Function>(isolate, getter.As<v8::Function>());
                    const TypeEncoding* typeEncoding = propMeta->getter()->encodings()->first();
                    PropertyCallbackContext* userData = new PropertyCallbackContext(this, isolate, poGetterFunc, new Persistent<Object>(isolate, implementationObject));

                    FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                        PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                        HandleScope handle_scope(context->isolate_);
                        Local<v8::Function> getterFunc = context->callback_->Get(context->isolate_);
                        Local<Value> res;
                        assert(getterFunc->Call(context->isolate_->GetCurrentContext(), context->implementationObject_->Get(context->isolate_), 0, nullptr).ToLocal(&res));

                        if (!res->IsNullOrUndefined() && res->IsObject() && res.As<Object>()->InternalFieldCount() > 0) {
                            Local<External> ext = res.As<Object>()->GetInternalField(0).As<External>();
                            // TODO: Check the actual DataWrapper type here
                            ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
                            *(ffi_arg *)retValue = (unsigned long)wrapper->Data();
                        } else {
                            void* nullPtr = nullptr;
                            *(ffi_arg *)retValue = (unsigned long)nullPtr;
                        }
                    };

                    IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback , userData);

                    const char *getterName = property_copyAttributeValue(property, "G");
                    NSString* selectorString;
                    if (getterName == nullptr) {
                        selectorString = [NSString stringWithUTF8String:propertyName.c_str()];
                    } else {
                        selectorString = [NSString stringWithUTF8String:getterName];
                    }

                    class_addMethod(extendedClass, NSSelectorFromString(selectorString), impGetter, "@@:");
                }

                if (hasSetter) {
                    Persistent<v8::Function>* poSetterFunc = new Persistent<v8::Function>(isolate, setter.As<v8::Function>());
                    const TypeEncoding* typeEncoding = propMeta->setter()->encodings()->first();
                    PropertyCallbackContext* userData = new PropertyCallbackContext(this, isolate, poSetterFunc, new Persistent<Object>(isolate, implementationObject));
                    FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                        id paramValue = *static_cast<const id*>(argValues[2]);
                        PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                        HandleScope handle_scope(context->isolate_);
                        Local<v8::Function> setterFunc = context->callback_->Get(context->isolate_);
                        Local<Value> res;

                        // TODO: Check the actual DataWrapper type and pass metadata
                        ObjCDataWrapper* wrapper = new ObjCDataWrapper(std::string(), paramValue);
                        Local<Value> argWrapper = ArgConverter::CreateJsWrapper(context->isolate_, wrapper, Local<Object>());
                        Local<Value> params[1] = { argWrapper };
                        assert(setterFunc->Call(context->isolate_->GetCurrentContext(), context->implementationObject_->Get(context->isolate_), 1, params).ToLocal(&res));
                    };

                    IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

                    const char *setterName = property_copyAttributeValue(property, "S");
                    NSString* selectorString;
                    if (setterName == nullptr) {
                        char firstChar = (char)toupper(propertyName[0]);
                        NSString* capitalLetter = [NSString stringWithFormat:@"%c", firstChar];
                        NSString* reminder = [NSString stringWithUTF8String: propertyName.c_str() + 1];
                        selectorString = [@[@"set", capitalLetter, reminder, @":"] componentsJoinedByString:@""];
                    } else {
                        selectorString = [NSString stringWithUTF8String:setterName];
                    }
                    class_addMethod(extendedClass, NSSelectorFromString(selectorString), impSetter, "v@:@");
                }

                free(propertyAttrs);
            }
        }
    }
}

void ClassBuilder::SuperAccessorGetterCallback(Local<Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> thiz = info.This();

    Local<Object> superValue = ArgConverter::CreateEmptyObject(context);

    superValue->SetPrototype(context, thiz->GetPrototype().As<Object>()->GetPrototype().As<Object>()->GetPrototype()).ToChecked();
    superValue->SetInternalField(0, thiz->GetInternalField(0));

    info.GetReturnValue().Set(superValue);
}

Persistent<v8::Function>* ClassBuilder::poOriginalExtendsFunc_ = nullptr;
unsigned long long ClassBuilder::classNameCounter_ = 0;

}
