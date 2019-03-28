#include <Foundation/Foundation.h>
#include "ClassBuilder.h"
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
    std::string name = tns::ToString(isolate, baseFunc->GetName());

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const InterfaceMeta* interfaceMeta = globalTable->findInterfaceMeta(name.c_str());
    assert(interfaceMeta != nullptr);

    Class extendedClass = item->self_->GetExtendedClass(name.c_str());
    if (info.Length() > 1 && info[1]->IsObject()) {
        item->self_->ExposeDynamicMembers(isolate, extendedClass, implementationObject, info[1].As<Object>());
    }

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

    DataWrapper* wrapper = new DataWrapper(obj);
    Local<External> ext = External::New(isolate, wrapper);

    Local<Object> thiz = info.This();
    thiz->SetInternalField(0, ext);

    item->self_->objectManager_.Register(isolate, thiz);
}

void ClassBuilder::ExposeDynamicMembers(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Local<Value> exposedMethods = nativeSignature->Get(tns::ToV8String(isolate, "exposedMethods"));
    if (!exposedMethods.IsEmpty() && exposedMethods->IsObject()) {
        Local<Context> context = isolate->GetCurrentContext();
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

            SEL selector;
            uint32_t argsCount;
            std::string typeInfo = GetMethodTypeInfo(isolate, exposedMethods.As<Object>()->Get(methodName).As<Object>(), tns::ToString(isolate, methodName), selector, argsCount);
            Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, method.As<Object>());
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, &argConverter_);
            IMP methodBody = interop_.CreateMethod(2, argsCount, ArgConverter::MethodCallback, userData);
            class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str());
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

Class ClassBuilder::GetExtendedClass(std::string baseClassName) {
    Class baseClass = objc_getClass(baseClassName.c_str());
    std::string name = baseClassName + "_" + std::to_string(++ClassBuilder::classNameCounter_);
    Class clazz = objc_getClass(name.c_str());

    if (clazz != nil) {
        return GetExtendedClass(baseClassName);
    }

    clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);
    return clazz;
}

std::string ClassBuilder::GetMethodTypeInfo(Isolate* isolate, Local<Object> methodSignature, std::string methodName, SEL& selector, uint32_t& argCount) {
    std::string result = std::string(@encode(void)) + std::string(@encode(id)) + std::string(@encode(SEL));
    argCount = 0;

    Local<Value> params = methodSignature->Get(tns::ToV8String(isolate, "params"));
    if (params.IsEmpty() || !params->IsArray() || params.As<v8::Array>()->Length() < 1) {
        selector = NSSelectorFromString([NSString stringWithUTF8String:methodName.c_str()]);
        return result;
    }

    std::string selectorStr = methodName;
    Local<v8::Array> paramsArray = params.As<v8::Array>();
    for (int i = 0; i < paramsArray->Length(); i++) {
        Local<Value> param = paramsArray->Get(i);
        if (param->IsFunction()) {
            Local<Value> val = tns::GetPrivateValue(isolate, param.As<v8::Function>(), tns::ToV8String(isolate, "metadata"));
            if (!val.IsEmpty()) {
                if (i == 0) {
                    selectorStr += ":";
                } else {
                    selectorStr += ":and";
                }
                result += std::string(@encode(id));
            }
            continue;
        }

        // TODO: handle the interop.types primitives (https://docs.nativescript.org/core-concepts/ios-runtime/how-to/ObjC-Subclassing)
        assert(false);
    }

    selector = NSSelectorFromString([NSString stringWithUTF8String:selectorStr.c_str()]);
    argCount = paramsArray->Length();

    return result;
}

unsigned long long ClassBuilder::classNameCounter_ = 0;

}
