#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Caches.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate) {
    poEmptyObjCtorFunc_ = new Persistent<v8::Function>(isolate, CreateEmptyObjectFunction(isolate));
}

Local<Value> ArgConverter::Invoke(Isolate* isolate, Class klass, Local<Object> receiver, const std::vector<Local<Value>> args, const MethodMeta* meta, bool isMethodCallback) {
    id target = nil;
    bool instanceMethod = !receiver.IsEmpty();
    bool callSuper = false;
    if (instanceMethod) {
        Local<External> ext = receiver->GetInternalField(0).As<External>();
        // TODO: Check the actual type of the DataWrapper
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
        target = wrapper->Data();

        std::string className = object_getClassName(target);
        auto it = Caches::ClassPrototypes.find(className);
        // For extended classes we will call the base method
        callSuper = isMethodCallback && it != Caches::ClassPrototypes.end();
    }

    void* resultPtr = Interop::CallFunction(isolate, meta, target, klass, args, callSuper);

    const TypeEncoding* typeEncoding = meta->encodings()->first();
    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
        typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
        typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding) {
        if (resultPtr == nullptr) {
            return Null(isolate);
        }

        id result = (__bridge id)resultPtr;
        if (result != nil) {
            // TODO: Create the proper DataWrapper type depending on the return value
            ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, result);
            return ConvertArgument(isolate, wrapper);
        }
    }

    if (typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
        const char* result = static_cast<const char*>(resultPtr);
        if (result != nullptr) {
            return tns::ToV8String(isolate, result);
        } else {
            return Null(isolate);
        }
    }

    if (typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
        bool result = (bool)resultPtr;
        return v8::Boolean::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::UShortEncoding) {
        return ToV8Number<unsigned short>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ShortEncoding) {
        return ToV8Number<short>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::UIntEncoding) {
        return ToV8Number<unsigned int>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::IntEncoding) {
        return ToV8Number<int>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
        return ToV8Number<unsigned long>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
        return ToV8Number<long>(isolate, resultPtr);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::FloatEncoding) {
        float result = *static_cast<float*>(resultPtr);
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
        double result = *static_cast<double*>(resultPtr);
        return Number::New(isolate, (double)result);
    }

    if (typeEncoding->type != BinaryTypeEncodingType::VoidEncoding) {
        assert(false);
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

    const Persistent<Object>* poCallback = data->callback_;

    void (^cb)() = ^{
        Isolate* isolate = data->isolate_;

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
                jsWrapper = ArgConverter::ConvertArgument(isolate, wrapper);
            } else if (typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
                bool arg = *static_cast<bool*>(argValues[argIndex]);
                BaseDataWrapper* wrapper = new PrimitiveDataWrapper(nullptr, &arg);
                jsWrapper = ArgConverter::ConvertArgument(isolate, wrapper);
            } else {
                const id arg = *static_cast<const id*>(argValues[argIndex]);
                if (arg != nil) {
                    BaseDataWrapper* wrapper = new ObjCDataWrapper(nullptr, arg);
                    jsWrapper = ArgConverter::ConvertArgument(isolate, wrapper);
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
                thiz = ArgConverter::CreateJsWrapper(isolate, wrapper, Local<Object>()).As<Object>();

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

template<class T>
Local<v8::Number> ArgConverter::ToV8Number(Isolate* isolate, void* ptr) {
    long result = 0;
    if (ptr != nullptr) {
        result = (long)ptr;
    }
    return v8::Number::New(isolate, (T)result);
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

Persistent<v8::Function>* ArgConverter::poEmptyObjCtorFunc_;

}
