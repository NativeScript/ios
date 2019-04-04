#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "Helpers.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate, ObjectManager objectManager) {
    isolate_ = isolate;
    objectManager_ = objectManager;
    interop_.RegisterInteropTypes(isolate);

    poEmptyObjCtorFunc_ = new Persistent<v8::Function>(isolate, CreateEmptyObjectFunction(isolate));
}

Local<Value> ArgConverter::Invoke(Isolate* isolate, Class klass, Local<Object> receiver, const std::vector<Local<Value>> args, NSInvocation* invocation, const TypeEncoding* typeEncoding, const std::string returnType) {
    for (int i = 0; i < args.size(); i++) {
        typeEncoding = typeEncoding->next();

        Local<Value> arg = args[i];
        int index = i + 2;

        if (arg->IsNull()) {
            id nullArg = nil;
            [invocation setArgument:&nullArg atIndex:index];
            continue;
        }

        if (arg->IsBoolean() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
            bool value = arg.As<v8::Boolean>()->Value();
            [invocation setArgument:&value atIndex:index];
            continue;
        }

        if (arg->IsObject() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
            Local<External> ext = arg.As<Object>()->GetInternalField(0).As<External>();
            BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
            std::string protocolName = wrapper->Metadata()->name();
            Protocol* protocol = objc_getProtocol(protocolName.c_str());
            [invocation setArgument:&protocol atIndex:index];
            continue;
        }

        if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
            std::string str = tns::ToString(isolate, arg);
            const char* s = str.c_str();
            [invocation setArgument:&s atIndex:index];
            continue;
        }

        if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
            std::string str = tns::ToString(isolate, arg);
            NSString* selector = [NSString stringWithUTF8String:str.c_str()];
            SEL res = NSSelectorFromString(selector);
            [invocation setArgument:&res atIndex:index];
            continue;
        }

        Local<Context> context = isolate->GetCurrentContext();
        if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            std::string str = tns::ToString(isolate, arg);
            NSString* result = [NSString stringWithUTF8String:str.c_str()];
            [invocation setArgument:&result atIndex:index];
            continue;
        }

        if (arg->IsNumber() || arg->IsDate()) {
            double value;
            if (!arg->NumberValue(context).To(&value)) {
                assert(false);
            }

            if (arg->IsNumber() || arg->IsNumberObject()) {
                SetNumericArgument(invocation, index, value, typeEncoding);
                continue;
            } else {
                NSDate* date = [NSDate dateWithTimeIntervalSince1970:value / 1000.0];
                [invocation setArgument:&date atIndex:index];
            }
        }

        if (arg->IsFunction() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
            Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, arg.As<Object>());
            ObjectWeakCallbackState* state = new ObjectWeakCallbackState(poCallback);
            poCallback->SetWeak(state, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

            const TypeEncoding* blockTypeEncoding = typeEncoding->details.block.signature.first();
            int argsCount = typeEncoding->details.block.signature.count - 1;

            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding, this);
            CFTypeRef blockPtr = interop_.CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);
            [invocation setArgument:&blockPtr atIndex:index];
            continue;
        }

        if (arg->IsObject()) {
            Local<Object> obj = arg.As<Object>();
            if (obj->InternalFieldCount() > 0) {
                Local<External> ext = obj->GetInternalField(0).As<External>();
                // TODO: Check the actual type of the DataWrapper
                ObjCDataWrapper* wrapper = reinterpret_cast<ObjCDataWrapper*>(ext->Value());
                const Meta* meta = wrapper->Metadata();
                if (meta != nullptr && meta->type() == MetaType::JsCode) {
                    const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
                    std::string jsCode = jsCodeMeta->jsCode();

                    Local<Script> script;
                    if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
                        assert(false);
                    }
                    assert(!script.IsEmpty());

                    Local<Value> result;
                    if (!script->Run(context).ToLocal(&result) && !result.IsEmpty()) {
                        assert(false);
                    }

                    assert(result->IsNumber());

                    double value = result.As<Number>()->Value();
                    SetNumericArgument(invocation, index, value, typeEncoding);
                    continue;
                }

                id data = wrapper->Data();
                if (data != nullptr) {
                    [invocation setArgument:&data atIndex:index];
                    continue;
                }
            }
        }

        assert(false);
    }


    bool instanceMethod = !receiver.IsEmpty();
    if (instanceMethod) {
        Local<External> ext = receiver->GetInternalField(0).As<External>();
        // TODO: Check the actual type of the DataWrapper
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
        id target = wrapper->Data();

        std::string className = object_getClassName(target);
        auto it = Caches::ClassPrototypes.find(className);
        bool isExtendedClass = it != Caches::ClassPrototypes.end();

        Class originalClass;
        Class targetClass;
        if (isExtendedClass) {
            targetClass = class_getSuperclass([target class]);
            originalClass = object_setClass(target, targetClass);
        }

        [invocation invokeWithTarget:target];

        if (isExtendedClass) {
            object_setClass(target, originalClass);
        }
    } else {
        [invocation setTarget:klass];
        [invocation invoke];
    }

    if (returnType == "@") {
        id result = nil;
        [invocation getReturnValue:&result];
        if (result != nil) {
            // TODO: Create the proper DataWrapper type depending on the return value
            ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, result);
            return ConvertArgument(isolate, wrapper);
        }
    }

    if (returnType == "*" || returnType == "r*") {
        char* result = nullptr;
        [invocation getReturnValue:&result];
        if (result != nullptr) {
            return tns::ToV8String(isolate, result);
        }
    }

    if (returnType == "i") {
        int result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "I") {
        unsigned int result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "s") {
        short result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "S") {
        unsigned short result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "l") {
        long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "L") {
        unsigned long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "q") {
        long long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "Q") {
        unsigned long long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "f") {
        float result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "d") {
        double result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "B") {
        bool result;
        [invocation getReturnValue:&result];
        return v8::Boolean::New(isolate, result);
    }

    // TODO: Handle all the possible return types https://nshipster.com/type-encodings/

    return Local<Value>();
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
    MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);

    Isolate* isolate = data->isolate_;
    const Persistent<Object>* poCallback = data->callback_;

    void (^cb)() = ^{
        HandleScope handle_scope(isolate);
        Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();

        std::vector<Local<Value>> v8Args;
        const TypeEncoding* typeEncoding = data->typeEncoding_;
        for (int i = 0; i < data->paramsCount_; i++) {
            typeEncoding = typeEncoding->next();
            int argIndex = i + data->initialParamIndex_;

            Local<Value> jsWrapper;
            if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
                long arg = *static_cast<long*>(argValues[argIndex]);
                BaseDataWrapper* wrapper = new PrimitiveDataWrapper(nullptr, &arg);
                jsWrapper = data->argConverter_->ConvertArgument(isolate, wrapper);
            } else if (typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
                bool arg = *static_cast<bool*>(argValues[argIndex]);
                BaseDataWrapper* wrapper = new PrimitiveDataWrapper(nullptr, &arg);
                jsWrapper = data->argConverter_->ConvertArgument(isolate, wrapper);
            } else {
                const id arg = *static_cast<const id*>(argValues[argIndex]);
                if (arg != nil) {
                    BaseDataWrapper* wrapper = new ObjCDataWrapper(nullptr, arg);
                    jsWrapper = data->argConverter_->ConvertArgument(isolate, wrapper);
                } else {
                    jsWrapper = Null(data->isolate_);
                }
            }

            v8Args.push_back(jsWrapper);
        }

        Local<Context> context = isolate->GetCurrentContext();
        Local<Object> thiz = context->Global();
        if (data->initialParamIndex_ > 0) {
            id self_ = *static_cast<const id*>(argValues[0]);
            auto it = Caches::Instances.find(self_);
            if (it != Caches::Instances.end()) {
                thiz = it->second->Get(data->isolate_);
            } else  {
                ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, self_);
                thiz = data->argConverter_->CreateJsWrapper(isolate, wrapper, Local<Object>()).As<Object>();

                std::string className = object_getClassName(self_);
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
                if (data->typeEncoding_->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
                    Local<External> ext = result.As<Object>()->GetInternalField(0).As<External>();
                    ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
                    id data = wrapper->Data();
                    *(ffi_arg *)retValue = (unsigned long)data;
                    return;
                }
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
void ArgConverter::SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
    case BinaryTypeEncodingType::ShortEncoding: {
        short arg = (short)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::UShortEncoding: {
        ushort arg = (ushort)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::IntEncoding: {
        int arg = (int)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::UIntEncoding: {
        uint arg = (uint)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::LongEncoding: {
        long arg = (long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::ULongEncoding: {
        unsigned long arg = (unsigned long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::LongLongEncoding: {
        long long arg = (long long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::ULongLongEncoding: {
        unsigned long long arg = (unsigned long long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::FloatEncoding: {
        float arg = (float)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::DoubleEncoding: {
        [invocation setArgument:&value atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::IdEncoding: {
        [invocation setArgument:&value atIndex:index];
        break;
    }
    default: {
        assert(false);
        break;
    }
    }
}

Local<Value> ArgConverter::CreateJsWrapper(Isolate* isolate, BaseDataWrapper* wrapper, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (wrapper == nullptr) {
        return Null(isolate);
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
    const BaseClassMeta* meta = FindInterfaceMeta(klass);
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

    Local<External> ext = External::New(isolate, wrapper);
    receiver->SetInternalField(0, ext);

    return receiver;
}

const BaseClassMeta* ArgConverter::FindInterfaceMeta(Class klass) {
    std::string origClassName = class_getName(klass);
    auto it = Caches::Metadata.find(origClassName);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    std::string className = origClassName;

    while (true) {
        const BaseClassMeta* result = GetInterfaceMeta(className);
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

const BaseClassMeta* ArgConverter::GetInterfaceMeta(std::string name) {
    auto it = Caches::Metadata.find(name);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const Meta* result = globalTable->findMeta(name.c_str());

    if (result == nullptr) {
        return nullptr;
    }

    if (result->type() == MetaType::Interface) {
        return static_cast<const InterfaceMeta*>(result);
    } else if (result->type() == MetaType::ProtocolType) {
        return static_cast<const ProtocolMeta*>(result);
    }

    assert(false);
}

Local<Object> ArgConverter::CreateEmptyObject(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> emptyObjCtorFunc = Local<v8::Function>::New(isolate, *poEmptyObjCtorFunc_);
    Local<Value> value;
    if (!emptyObjCtorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        assert(false);
    }
    Local<Object> result = value.As<Object>();
    return result;
}

Local<v8::Function> ArgConverter::CreateEmptyObjectFunction(Isolate* isolate) {
    Local<FunctionTemplate> emptyObjCtorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    emptyObjCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<v8::Function> emptyObjCtorFunc;
    if (!emptyObjCtorFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&emptyObjCtorFunc)) {
        assert(false);
    }
    return emptyObjCtorFunc;
}

}
