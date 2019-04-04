#include <Foundation/Foundation.h>
#include "ClassBuilder.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;

namespace tns {

void ClassBuilder::Init(ArgConverter argConverter, ObjectManager objectManager) {
    argConverter_ = argConverter;
    objectManager_ = objectManager;
}

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
        item->self_->ExposeDynamicMembers(isolate, extendedClass, implementationObject, nativeSignature);
        item->self_->ExposeDynamicProtocols(isolate, extendedClass, implementationObject, nativeSignature);
    }
    objc_registerClassPair(extendedClass);

    Persistent<v8::Function>* poBaseCtorFunc = Caches::CtorFuncs.find(item->meta_)->second;
    Local<v8::Function> baseCtorFunc = Local<v8::Function>::New(isolate, *poBaseCtorFunc);

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

    info.GetReturnValue().Set(extendClassCtorFunc);
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

    id obj = [[item->data_ alloc] init];

    ObjCDataWrapper* wrapper = new ObjCDataWrapper(item->meta_, obj);
    Local<External> ext = External::New(isolate, wrapper);

    Local<Object> thiz = info.This();
    thiz->SetInternalField(0, ext);

    item->self_->objectManager_.Register(isolate, thiz);
}

void ClassBuilder::ExposeDynamicMembers(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> exposedMethods = nativeSignature->Get(tns::ToV8String(isolate, "exposedMethods"));
    const BaseClassMeta* extendedClassMeta = argConverter_.FindInterfaceMeta(extendedClass);
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

            // TODO: Prepare the TypeEncoding* from the v8 arguments and return type.
            std::string typeInfo = "v@:@";
            int argsCount = 1;
            std::string methodNameStr = tns::ToString(isolate, methodName);
            SEL selector = NSSelectorFromString([NSString stringWithUTF8String:(methodNameStr).c_str()]);

            TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(calloc(2, sizeof(TypeEncoding)));
            typeEncoding->type = BinaryTypeEncodingType::VoidEncoding;
            TypeEncoding* next = reinterpret_cast<TypeEncoding*>(reinterpret_cast<char*>(typeEncoding) + sizeof(BinaryTypeEncodingType));
            next->type = BinaryTypeEncodingType::InterfaceDeclarationReference;

            Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, method.As<Object>());
            Persistent<Object>* prototype = new Persistent<Object>(isolate, implementationObject);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, prototype, 2, argsCount, typeEncoding, &argConverter_);
            IMP methodBody = interop_.CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str());
        }
    }

    Local<v8::Array> propertyNames;
    assert(implementationObject->GetOwnPropertyNames(context).ToLocal(&propertyNames));
    for (uint32_t i = 0; i < propertyNames->Length(); i++) {
        Local<Value> key = propertyNames->Get(i);
        Local<Value> method = implementationObject->Get(key);
        if (method.IsEmpty() || !method->IsFunction()) {
            continue;
        }

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
                    const char* proto = (*protoIt).valuePtr();
                    const BaseClassMeta* m = argConverter_.GetInterfaceMeta(proto);
                    for (auto it = m->instanceMethods->begin(); it != m->instanceMethods->end(); it++) {
                        const MethodMeta* mm = (*it).valuePtr();
                        if (strcmp(mm->jsName(), methodName.c_str()) == 0) {
                            methodMeta = mm;
                            break;
                        }
                    }
                }
            }

            if (methodMeta != nullptr) {
                Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, method.As<Object>());
                const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
                uint8_t argsCount = methodMeta->encodings()->count - 1;
                Persistent<Object>* prototype = new Persistent<Object>(isolate, implementationObject);
                MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, prototype, 2, argsCount, typeEncoding, &argConverter_);
                SEL selector = methodMeta->selector();
                IMP methodBody = interop_.CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
                class_addMethod(extendedClass, selector, methodBody, "v@:@");
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

void ClassBuilder::ExposeDynamicProtocols(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Local<Value> exposedProtocols = nativeSignature->Get(tns::ToV8String(isolate, "protocols"));
    if (exposedProtocols.IsEmpty() || !exposedProtocols->IsArray()) {
        return;
    }

    Local<v8::Array> protocols = exposedProtocols.As<v8::Array>();
    if (protocols->Length() < 1) {
        return;
    }

    for (uint32_t i = 0; i < protocols->Length(); i++) {
        Local<Value> element = protocols->Get(i);
        assert(!element.IsEmpty() && element->IsObject());

        Local<Object> protoObj = element.As<Object>();
        assert(protoObj->InternalFieldCount() > 0);

        Local<External> ext = protoObj->GetInternalField(0).As<External>();
        BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
        const char* protocolName = wrapper->Metadata()->name();
        Protocol* proto = objc_getProtocol(protocolName);
        assert(proto != nullptr);

        if (class_conformsToProtocol(extendedClass, proto)) {
            continue;
        }

        class_addProtocol(extendedClass, proto);

        const GlobalTable* globalTable = MetaFile::instance()->globalTable();
        const ProtocolMeta* protoMeta = globalTable->findProtocol(protocolName);

        Local<v8::Array> propertyNames;
        Local<Context> context = isolate->GetCurrentContext();
        assert(implementationObject->GetPropertyNames(context).ToLocal(&propertyNames));

        for (uint32_t j = 0; j < propertyNames->Length(); j++) {
            Local<Value> descriptor;
            Local<Name> propName = propertyNames->Get(j).As<Name>();
            assert(implementationObject->GetOwnPropertyDescriptor(context, propName).ToLocal(&descriptor));
            if (descriptor.IsEmpty()) {
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

                    IMP impGetter = interop_.CreateMethod(2, 0, typeEncoding, getterCallback , userData);

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
                        ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, paramValue);
                        Local<Value> argWrapper = context->classBuilder_->argConverter_.CreateJsWrapper(context->isolate_, wrapper, Local<Object>());
                        Local<Value> params[1] = { argWrapper };
                        assert(setterFunc->Call(context->isolate_->GetCurrentContext(), context->implementationObject_->Get(context->isolate_), 1, params).ToLocal(&res));
                    };

                    IMP impSetter = interop_.CreateMethod(2, 1, typeEncoding, setterCallback, userData);

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

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());
    Local<Object> superValue = item->self_->argConverter_.CreateEmptyObject(context);

    superValue->SetPrototype(context, thiz->GetPrototype().As<Object>()->GetPrototype().As<Object>()->GetPrototype()).ToChecked();
    superValue->SetInternalField(0, thiz->GetInternalField(0));

    info.GetReturnValue().Set(superValue);
}

Class ClassBuilder::GetExtendedClass(std::string baseClassName, std::string staticClassName) {
    Class baseClass = objc_getClass(baseClassName.c_str());
    std::string name = !staticClassName.empty() ? staticClassName : baseClassName + "_" + std::to_string(++ClassBuilder::classNameCounter_);
    Class clazz = objc_getClass(name.c_str());

    if (clazz != nil) {
        return GetExtendedClass(baseClassName, staticClassName);
    }

    clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);
    return clazz;
}

unsigned long long ClassBuilder::classNameCounter_ = 0;

}
