#include <Foundation/Foundation.h>
#include <numeric>
#include <sstream>
#include "ClassBuilder.h"
#include "FastEnumerationAdapter.h"
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

    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, baseFunc);
    if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::ObjCClass) {
        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(baseWrapper);
        if (classWrapper->ExtendedClass()) {
            tns::ThrowError(isolate, "Cannot extend an already extended class");
            return;
        }
    }

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
    } else {
        item->self_->ExposeDynamicMethods(isolate, extendedClass, Local<Value>(), Local<Value>(), implementationObject);
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
    Local<Value> baseProto = baseCtorFunc->Get(tns::ToV8String(isolate, "prototype"));
    if (!implementationObject->SetPrototype(context, baseProto).To(&success) || !success) {
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
    ObjCClassWrapper* wrapper = new ObjCClassWrapper(extendedClass, true);
    tns::SetValue(isolate, extendClassCtorFunc, wrapper);

    Caches::CtorFuncs.emplace(std::make_pair(extendedClassName, new Persistent<v8::Function>(isolate, extendClassCtorFunc)));
    Caches::ClassPrototypes.emplace(std::make_pair(extendedClassName, new Persistent<Object>(isolate, extendFuncPrototype)));

    info.GetReturnValue().Set(extendClassCtorFunc);
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());
    Class klass = item->data_;

    ArgConverter::ConstructObject(isolate, info, klass);
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

        BaseDataWrapper* wrapper = tns::GetValue(isolate, info[1].As<Object>());
        if (!wrapper) {
            // We are not extending a native object -> call the base __extends function
            Local<v8::Function> originalExtendsFunc = poOriginalExtendsFunc_->Get(isolate);
            Local<Value> args[] = { info[0], info[1] };
            originalExtendsFunc->Call(context, context->Global(), info.Length(), args).ToLocalChecked();
            return;
        }

        ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
        Class baseClass = dataWrapper->Data();
        std::string baseClassName = class_getName(baseClass);

        Local<v8::Function> extendedClassCtorFunc = info[0].As<v8::Function>();
        std::string extendedClassName = tns::ToString(isolate, extendedClassCtorFunc->GetName());

        __block Class extendedClass = builder->GetExtendedClass(baseClassName, extendedClassName);

        tns::SetValue(isolate, extendedClassCtorFunc, new ObjCClassWrapper(extendedClass, true));

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
            builder->ExposeDynamicMethods(isolate, extendedClass, exposedMethods, exposedProtocols, implementationObject.As<Object>());
        });
        class_addMethod(object_getClass(extendedClass), @selector(initialize), newInitialize, "v@:");

        info.GetReturnValue().Set(v8::Undefined(isolate));
    }, External::New(isolate, this)).ToLocalChecked();

    global->Set(tns::ToV8String(isolate, "__extends"), extendsFunc);
}

void ClassBuilder::ExposeDynamicMembers(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Local<Value> exposedMethods = nativeSignature->Get(tns::ToV8String(isolate, "exposedMethods"));
    Local<Value> exposedProtocols = nativeSignature->Get(tns::ToV8String(isolate, "protocols"));
    this->ExposeDynamicMethods(isolate, extendedClass, exposedMethods, exposedProtocols, implementationObject);
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding) {
    BinaryTypeEncodingType type = typeEncoding->type;
    switch (type) {
        case BinaryTypeEncodingType::VoidEncoding: {
            return "v";
        }
        case BinaryTypeEncodingType::BoolEncoding: {
            return "B";
        }
        case BinaryTypeEncodingType::UnicharEncoding:
        case BinaryTypeEncodingType::UShortEncoding: {
            return "S";
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            return "s";
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            return "I";
        }
        case BinaryTypeEncodingType::IntEncoding: {
            return "i";
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            return "L";
        }
        case BinaryTypeEncodingType::LongEncoding: {
            return "l";
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            return "Q";
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            return "q";
        }
        case BinaryTypeEncodingType::UCharEncoding: {
            return "C";
        }
        case BinaryTypeEncodingType::CharEncoding: {
            return "c";
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            return "f";
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            return "d";
        }
        case BinaryTypeEncodingType::CStringEncoding: {
            return "*";
        }
        case BinaryTypeEncodingType::ClassEncoding: {
            return "#";
        }
        case BinaryTypeEncodingType::SelectorEncoding: {
            return ":";
        }
        case BinaryTypeEncodingType::BlockEncoding: {
            return "@?";
        }
        case BinaryTypeEncodingType::StructDeclarationReference: {
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const Meta* meta = ArgConverter::GetMeta(structName);
            assert(meta != nullptr && meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

            std::stringstream ss;
            ss << "{" << structName << "=";
            for (int i = 0; i < structMeta->fieldsCount(); i++) {
                ss << GetTypeEncoding(fieldEncoding);
                fieldEncoding = fieldEncoding->next();
            }
            ss << "}";
            return ss.str();
        }
        case BinaryTypeEncodingType::PointerEncoding: {
            return "^";
        }
        case BinaryTypeEncodingType::ProtocolEncoding:
        case BinaryTypeEncodingType::InterfaceDeclarationReference:
        case BinaryTypeEncodingType::InstanceTypeEncoding:
        case BinaryTypeEncodingType::IdEncoding: {
            return "@";
        }

        default:
            // TODO: Handle the other possible types
            assert(false);
    }
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding, int argsCount) {
    std::stringstream compilerEncoding;
    compilerEncoding << GetTypeEncoding(typeEncoding);
    compilerEncoding << "@:"; // id self, SEL _cmd

    for (int i = 0; i < argsCount; i++) {
        typeEncoding = typeEncoding->next();
        compilerEncoding << GetTypeEncoding(typeEncoding);
    }

    return compilerEncoding.str();
}

BinaryTypeEncodingType ClassBuilder::GetTypeEncodingType(Isolate* isolate, Local<Value> value) {
    if (BaseDataWrapper* wrapper = tns::GetValue(isolate, value)) {
        if (wrapper->Type() == WrapperType::ObjCClass) {
            return BinaryTypeEncodingType::IdEncoding;
        } else if (wrapper->Type() == WrapperType::ObjCProtocol) {
            return BinaryTypeEncodingType::IdEncoding;
        } else if (wrapper->Type() == WrapperType::Primitive) {
            PrimitiveDataWrapper* pdw = static_cast<PrimitiveDataWrapper*>(wrapper);
            return pdw->EncodingType();
        } else if (wrapper->Type() == WrapperType::ObjCObject) {
            return BinaryTypeEncodingType::IdEncoding;
        }
    }

    //  TODO: Unknown encoding type
    assert(false);
}

void ClassBuilder::ExposeDynamicMethods(Isolate* isolate, Class extendedClass, Local<Value> exposedMethods, Local<Value> exposedProtocols, Local<Object> implementationObject) {
    Local<Context> context = isolate->GetCurrentContext();

    std::vector<Protocol*> protocols;
    if (!exposedProtocols.IsEmpty() && exposedProtocols->IsArray()) {
        Local<v8::Array> protocolsArray = exposedProtocols.As<v8::Array>();
        for (uint32_t i = 0; i < protocolsArray->Length(); i++) {
            Local<Value> element = protocolsArray->Get(i);
            assert(!element.IsEmpty() && element->IsFunction());

            Local<v8::Function> protoObj = element.As<v8::Function>();
            BaseDataWrapper* wrapper = tns::GetValue(isolate, protoObj);
            assert(wrapper && wrapper->Type() == WrapperType::ObjCProtocol);
            ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrapper);
            Protocol* proto = protoWrapper->Proto();
            assert(proto != nullptr);

            if (class_conformsToProtocol(extendedClass, proto)) {
                continue;
            }

            protocols.push_back(proto);
            class_addProtocol(extendedClass, proto);
        }
    }

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
                NSLog(@"No implementation found for exposed method \"%s\"", tns::ToString(isolate, methodName).c_str());
                continue;
            }

            Local<Value> returnsVal = methodSignature.As<Object>()->Get(tns::ToV8String(isolate, "returns"));
            Local<Value> paramsVal = methodSignature.As<Object>()->Get(tns::ToV8String(isolate, "params"));
            if (returnsVal.IsEmpty() || !returnsVal->IsObject()) {
                // Incorrect exposedMethods definition: missing returns property
                assert(false);
            }

            int argsCount = 0;
            if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
                argsCount = paramsVal.As<v8::Array>()->Length();
            }

            BinaryTypeEncodingType returnType = GetTypeEncodingType(isolate, returnsVal);

            std::string methodNameStr = tns::ToString(isolate, methodName);
            SEL selector = sel_registerName(methodNameStr.c_str());

            TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(calloc(argsCount + 1, sizeof(TypeEncoding)));
            typeEncoding->type = returnType;

            if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
                Local<v8::Array> params = paramsVal.As<v8::Array>();
                TypeEncoding* next = typeEncoding;
                for (int i = 0; i < params->Length(); i++) {
                    next = reinterpret_cast<TypeEncoding*>(reinterpret_cast<char*>(next) + sizeof(next->type));
                    Local<Value> param = params->Get(i);
                    next->type = GetTypeEncodingType(isolate, param);
                }
            }

            Persistent<Value>* poCallback = new Persistent<Value>(isolate, method);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
            IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
            assert(class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str()));
        }
    }

    const Meta* m = ArgConverter::FindMeta(extendedClass);
    if (m == nullptr) {
        return;
    }

    const BaseClassMeta* extendedClassMeta = static_cast<const BaseClassMeta*>(m);

    Local<v8::Array> propertyNames;

    Local<Value> symbolIterator = implementationObject->Get(Symbol::GetIterator(isolate));
    if (!symbolIterator.IsEmpty() && symbolIterator->IsFunction()) {
        Local<v8::Function> symbolIteratorFunc = symbolIterator.As<v8::Function>();

        class_addProtocol(extendedClass, @protocol(NSFastEnumeration));
        class_addProtocol(object_getClass(extendedClass), @protocol(NSFastEnumeration));

        Persistent<v8::Function>* poIteratorFunc = new Persistent<v8::Function>(isolate, symbolIteratorFunc);
        IMP imp = imp_implementationWithBlock(^NSUInteger(id self, NSFastEnumerationState* state, __unsafe_unretained id buffer[], NSUInteger length) {
            return tns::FastEnumerationAdapter(isolate, self, state, buffer, length, poIteratorFunc);
        });

        struct objc_method_description fastEnumerationMethodDescription = protocol_getMethodDescription(@protocol(NSFastEnumeration), @selector(countByEnumeratingWithState:objects:count:), YES, YES);
        assert(class_addMethod(extendedClass, @selector(countByEnumeratingWithState:objects:count:), imp, fastEnumerationMethodDescription.types));
    }

    assert(implementationObject->GetOwnPropertyNames(context).ToLocal(&propertyNames));
    for (uint32_t i = 0; i < propertyNames->Length(); i++) {
        Local<Value> key = propertyNames->Get(i);
        if (!key->IsName()) {
            continue;
        }

        std::string methodName = tns::ToString(isolate, key);

        Local<Value> propertyDescriptor;
        assert(implementationObject->GetOwnPropertyDescriptor(context, key.As<Name>()).ToLocal(&propertyDescriptor));
        if (propertyDescriptor.IsEmpty() || propertyDescriptor->IsNullOrUndefined()) {
            continue;
        }

        Local<Value> getter = propertyDescriptor.As<Object>()->Get(tns::ToV8String(isolate, "get"));
        Local<Value> setter = propertyDescriptor.As<Object>()->Get(tns::ToV8String(isolate, "set"));
        if ((!getter.IsEmpty() || !setter.IsEmpty()) && (getter->IsFunction() || setter->IsFunction())) {
            std::vector<const PropertyMeta*> propertyMetas;
            VisitProperties(methodName, extendedClassMeta, propertyMetas, protocols);
            ExposeProperties(isolate, extendedClass, propertyMetas, implementationObject, getter, setter);
            continue;
        }

        Local<Value> method = propertyDescriptor.As<Object>()->Get(tns::ToV8String(isolate, "value"));
        if (method.IsEmpty() || !method->IsFunction()) {
            continue;
        }

        std::vector<const MethodMeta*> methodMetas;
        VisitMethods(isolate, extendedClass, methodName, extendedClassMeta, methodMetas, protocols);

        for (int j = 0; j < methodMetas.size(); j++) {
            const MethodMeta* methodMeta = methodMetas[j];
            Persistent<Value>* poCallback = new Persistent<Value>(isolate, method);
            const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
            uint8_t argsCount = methodMeta->encodings()->count - 1;
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
            SEL selector = methodMeta->selector();
            IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
            assert(class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str()));
        }
    }
}

void ClassBuilder::VisitProperties(std::string propertyName, const BaseClassMeta* meta, std::vector<const PropertyMeta*>& propertyMetas, std::vector<Protocol*> exposedProtocols) {
    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
        const PropertyMeta* propertyMeta = (*it).valuePtr();
        if (propertyMeta->jsName() == propertyName) {
            objc_property_t property = nullptr;
            if (meta->type() == MetaType::ProtocolType) {
                Protocol* proto = objc_getProtocol(meta->name());
                assert(proto != nullptr);
                property = protocol_getProperty(proto, propertyName.c_str(), true, true);
            } else if (meta->type() == MetaType::Interface) {
                Class klass = objc_getClass(meta->name());
                assert(klass != nullptr);
                property = class_getProperty(klass, propertyName.c_str());
            }

            if (std::find(propertyMetas.begin(), propertyMetas.end(), propertyMeta) == propertyMetas.end()) {
                propertyMetas.push_back(propertyMeta);
            }
        }
    }

    for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
        const char* protocolName = (*protoIt).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName);
        if (!m) {
            continue;
        }
        const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
        VisitProperties(propertyName, protocolMeta, propertyMetas, exposedProtocols);
    }

    for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
        Protocol* proto = *it;
        const char* protocolName = protocol_getName(proto);
        const Meta* meta = ArgConverter::GetMeta(protocolName);
        if (meta != nullptr && meta->type() == MetaType::ProtocolType) {
            const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(meta);
            VisitProperties(propertyName, protocolMeta, propertyMetas, std::vector<Protocol*>());
        }
    }

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
        if (baseMeta != nullptr) {
            VisitProperties(propertyName, baseMeta, propertyMetas, exposedProtocols);
        }
    }
}

void ClassBuilder::VisitMethods(Isolate* isolate, Class extendedClass, std::string methodName, const BaseClassMeta* meta, std::vector<const MethodMeta*>& methodMetas, std::vector<Protocol*> exposedProtocols) {
    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        if (methodMeta->jsName() == methodName) {
            if (std::find(methodMetas.begin(), methodMetas.end(), methodMeta) == methodMetas.end()) {
                methodMetas.push_back(methodMeta);
            }
        }
    }

    for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
        const char* protocolName = (*protoIt).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName);
        if (!m) {
            continue;
        }
        const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
        VisitMethods(isolate, extendedClass, methodName, protocolMeta, methodMetas, exposedProtocols);
    }

    for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
        Protocol* proto = *it;
        const char* protocolName = protocol_getName(proto);
        const Meta* meta = ArgConverter::GetMeta(protocolName);
        if (meta != nullptr && meta->type() == MetaType::ProtocolType) {
            const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(meta);
            VisitMethods(isolate, extendedClass, methodName, protocolMeta, methodMetas, std::vector<Protocol*>());
        }
    }

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
        if (baseMeta != nullptr) {
            VisitMethods(isolate, extendedClass, methodName, interfaceMeta->baseMeta(), methodMetas, exposedProtocols);
        }
    }
}

void ClassBuilder::ExposeProperties(Isolate* isolate, Class extendedClass, std::vector<const PropertyMeta*> propertyMetas, Local<Object> implementationObject, Local<Value> getter, Local<Value> setter) {
    for (int j = 0; j < propertyMetas.size(); j++) {
        const PropertyMeta* propertyMeta = propertyMetas[j];
        std::string propertyName = propertyMeta->name();

        if (!getter.IsEmpty() && getter->IsFunction() && propertyMeta->hasGetter()) {
            Persistent<v8::Function>* poGetterFunc = new Persistent<v8::Function>(isolate, getter.As<v8::Function>());
            PropertyCallbackContext* userData = new PropertyCallbackContext(this, isolate, poGetterFunc, new Persistent<Object>(isolate, implementationObject), propertyMeta);

            FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                HandleScope handle_scope(context->isolate_);
                Local<v8::Function> getterFunc = context->callback_->Get(context->isolate_);
                Local<Value> res;

                id thiz = *static_cast<const id*>(argValues[0]);
                auto it = Caches::Instances.find(thiz);
                Local<Object> self_ = it != Caches::Instances.end()
                    ? it->second->Get(context->isolate_).As<Object>()
                    : context->implementationObject_->Get(context->isolate_);
                assert(getterFunc->Call(context->isolate_->GetCurrentContext(), self_, 0, nullptr).ToLocal(&res));

                const TypeEncoding* typeEncoding = context->meta_->getter()->encodings()->first();
                ArgConverter::SetValue(context->isolate_, retValue, res, typeEncoding->type);
            };
            const TypeEncoding* typeEncoding = propertyMeta->getter()->encodings()->first();
            IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback , userData);

            class_addMethod(extendedClass, propertyMeta->getter()->selector(), impGetter, "@@:");
        }

        if (!setter.IsEmpty() && setter->IsFunction() && propertyMeta->hasSetter()) {
            Persistent<v8::Function>* poSetterFunc = new Persistent<v8::Function>(isolate, setter.As<v8::Function>());
            PropertyCallbackContext* userData = new PropertyCallbackContext(this, isolate, poSetterFunc, new Persistent<Object>(isolate, implementationObject), propertyMeta);

            FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                HandleScope handle_scope(context->isolate_);
                Local<v8::Function> setterFunc = context->callback_->Get(context->isolate_);
                Local<Value> res;

                id thiz = *static_cast<const id*>(argValues[0]);
                auto it = Caches::Instances.find(thiz);
                Local<Object> self_ = it != Caches::Instances.end()
                    ? it->second->Get(context->isolate_).As<Object>()
                    : context->implementationObject_->Get(context->isolate_);

                uint8_t* argBuffer = (uint8_t*)argValues[2];
                const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
                BaseCall call(argBuffer);
                Local<Value> jsWrapper = Interop::GetResult(context->isolate_, typeEncoding, &call, true);
                Local<Value> params[1] = { jsWrapper };

                assert(setterFunc->Call(context->isolate_->GetCurrentContext(), self_, 1, params).ToLocal(&res));
            };

            const TypeEncoding* typeEncoding = propertyMeta->setter()->encodings()->first();
            IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

            class_addMethod(extendedClass, propertyMeta->setter()->selector(), impSetter, "v@:@");
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
    superValue->SetInternalField(1, tns::ToV8String(isolate, "super"));

    info.GetReturnValue().Set(superValue);
}

Persistent<v8::Function>* ClassBuilder::poOriginalExtendsFunc_ = nullptr;
unsigned long long ClassBuilder::classNameCounter_ = 0;

}
