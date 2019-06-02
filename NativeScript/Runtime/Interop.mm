#include <Foundation/Foundation.h>
#include "Interop.h"
#include "Interop_impl.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "ArgConverter.h"
#include "DictionaryAdapter.h"
#include "ArrayAdapter.h"
#include "Caches.h"

using namespace v8;

namespace tns {

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = &copyBlock,
    .dispose = &disposeBlock
};

void Interop::RegisterInteropTypes(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<Object> interop = Object::New(isolate);
    Local<Object> types = Object::New(isolate);

    RegisterReferenceInteropType(isolate, interop);

    RegisterInteropType(isolate, types, "void", new PrimitiveDataWrapper(sizeof(ffi_type_void.size), BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "bool", new PrimitiveDataWrapper(sizeof(bool), BinaryTypeEncodingType::BoolEncoding));

    bool success = interop->Set(tns::ToV8String(isolate, "types"), types);
    assert(success);

    success = global->Set(tns::ToV8String(isolate, "interop"), interop);
    assert(success);
}

void Interop::RegisterInteropType(Isolate* isolate, Local<Object> types, std::string name, PrimitiveDataWrapper* wrapper) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> obj = ArgConverter::CreateEmptyObject(context);
    Local<External> ext = External::New(isolate, wrapper);
    obj->SetInternalField(0, ext);
    bool success = types->Set(tns::ToV8String(isolate, name), obj);
    assert(success);
}

void Interop::RegisterReferenceInteropType(Isolate* isolate, Local<Object> interop) {
    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        assert(info.Length() == 2);
        assert(info[0]->IsObject());
        assert(info[0].As<Object>()->InternalFieldCount() > 0);

        Local<External> ext = info[0].As<Object>()->GetInternalField(0).As<External>();
        PrimitiveDataWrapper* wrapper = static_cast<PrimitiveDataWrapper*>(ext->Value());

        ext = External::New(isolate, wrapper);
        Local<Object> thiz = info.This();
        thiz->SetInternalField(0, ext);

        ArgConverter::CreateJsWrapper(isolate, wrapper, thiz);
    });
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();

    proto->SetAccessor(tns::ToV8String(isolate, "value"), [](Local<v8::String> property, const PropertyCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<External> ext = info.This()->GetInternalField(0).As<External>();
        PrimitiveDataWrapper* wrapper = static_cast<PrimitiveDataWrapper*>(ext->Value());
        BinaryTypeEncodingType type = wrapper->EncodingType();
        uint8_t* buffer = (uint8_t*)wrapper->Value();

        BaseFFICall call(buffer, 0);
        Local<Value> result = Interop::GetPrimitiveReturnType(isolate, type, &call);
        if (!result.IsEmpty()) {
            info.GetReturnValue().Set(result);
        }
    });

    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    interop->Set(tns::ToV8String(isolate, "Reference"), ctorFunc);
}

IMP Interop::CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    void* functionPointer;
    ffi_closure* closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &functionPointer));
    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParamIndex, initialParamIndex + argsCount);
    ffi_status status = ffi_prep_closure_loc(closure, cif, callback, userData, functionPointer);
    assert(status == FFI_OK);

    return (IMP)functionPointer;
}

CFTypeRef Interop::CreateBlock(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    JSBlock* blockPointer = reinterpret_cast<JSBlock*>(calloc(1, sizeof(JSBlock)));
    void* functionPointer = (void*)CreateMethod(initialParamIndex, argsCount, typeEncoding, callback, userData);

    *blockPointer = {
        .isa = nullptr,
        .flags = JSBlock::BLOCK_HAS_COPY_DISPOSE | JSBlock::BLOCK_NEEDS_FREE | (1 /* ref count */ << 1),
        .reserved = 0,
        .invoke = functionPointer,
        .descriptor = &JSBlock::kJSBlockDescriptor,
    };

    object_setClass((__bridge id)blockPointer, objc_getClass("__NSMallocBlock__"));

    return blockPointer;
}

void Interop::SetFFIParams(Isolate* isolate, const TypeEncoding* typeEncoding, FFICall* call, const int argsCount, const int initialParameterIndex, const std::vector<Local<Value>> args) {
    const TypeEncoding* enc = typeEncoding;
    for (int i = initialParameterIndex; i < argsCount; i++) {
        enc = enc->next();
        Local<Value> arg = args[i - initialParameterIndex];

        if (arg->IsNullOrUndefined()) {
            call->SetArgument(i, nullptr);
        } else if (arg->IsBoolean() && enc->type == BinaryTypeEncodingType::BoolEncoding) {
            bool value = arg.As<v8::Boolean>()->Value();
            call->SetArgument(i, value);
        } else if (arg->IsString() && enc->type == BinaryTypeEncodingType::SelectorEncoding) {
            std::string str = tns::ToString(isolate, arg);
            NSString* selStr = [NSString stringWithUTF8String:str.c_str()];
            SEL selector = NSSelectorFromString(selStr);
            call->SetArgument(i, selector);
        } else if (arg->IsString() && enc->type == BinaryTypeEncodingType::CStringEncoding) {
            v8::String::Utf8Value utf8Value(isolate, arg);
            const char* strCopy = strdup(*utf8Value);
            call->SetArgument(i, strCopy);
        } else if (arg->IsString() && enc->type == BinaryTypeEncodingType::UnicharEncoding) {
            v8::String::Utf8Value utf8Value(isolate, arg);
            const char* strCopy = strdup(*utf8Value);
            if (strlen(strCopy) > 1) {
                assert(false);
            }
            unichar c = (strlen(strCopy) == 0) ? 0 : strCopy[0];
            call->SetArgument(i, c);
        } else if (arg->IsString() && (enc->type == BinaryTypeEncodingType::InterfaceDeclarationReference || enc->type == BinaryTypeEncodingType::IdEncoding)) {
            std::string str = tns::ToString(isolate, arg);
            NSString* result = [NSString stringWithUTF8String:str.c_str()];
            call->SetArgument(i, result);
        } else if (arg->IsNumber() || arg->IsNumberObject()) {
            double value = arg.As<Number>()->Value();

            if (enc->type == BinaryTypeEncodingType::UShortEncoding) {
                call->SetArgument(i, (unsigned short)value);
            } else if (enc->type == BinaryTypeEncodingType::ShortEncoding) {
                call->SetArgument(i, (short)value);
            } else if (enc->type == BinaryTypeEncodingType::UIntEncoding) {
                call->SetArgument(i, (unsigned int)value);
            } else if (enc->type == BinaryTypeEncodingType::IntEncoding) {
                call->SetArgument(i, (int)value);
            } else if (enc->type == BinaryTypeEncodingType::ULongEncoding) {
                call->SetArgument(i, (unsigned long)value);
            } else if (enc->type == BinaryTypeEncodingType::LongEncoding) {
                call->SetArgument(i, (long)value);
            } else if (enc->type == BinaryTypeEncodingType::ULongLongEncoding) {
                call->SetArgument(i, (unsigned long long)value);
            } else if (enc->type == BinaryTypeEncodingType::LongLongEncoding) {
                call->SetArgument(i, (long long)value);
            } else if (enc->type == BinaryTypeEncodingType::FloatEncoding) {
                call->SetArgument(i, (float)value);
            } else if (enc->type == BinaryTypeEncodingType::DoubleEncoding) {
                call->SetArgument(i, value);
            } else if (enc->type == BinaryTypeEncodingType::UCharEncoding) {
                call->SetArgument(i, (unsigned char)value);
            } else if (enc->type == BinaryTypeEncodingType::CharEncoding) {
                call->SetArgument(i, (char)value);
            } else {
                assert(false);
            }
        } else if (enc->type == BinaryTypeEncodingType::PointerEncoding) {
            Local<External> ext = arg.As<Object>()->GetInternalField(0).As<External>();
            PrimitiveDataWrapper* wrapper = static_cast<PrimitiveDataWrapper*>(ext->Value());
            call->SetArgument(i, wrapper->Value());
        } else if (arg->IsFunction() && enc->type == BinaryTypeEncodingType::BlockEncoding) {
            const TypeEncoding* blockTypeEncoding = enc->details.block.signature.first();
            int argsCount = enc->details.block.signature.count - 1;

            Persistent<Object>* poCallback = new Persistent<Object>(isolate, arg.As<Object>());
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding);
            CFTypeRef blockPtr = Interop::CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);
            call->SetArgument(i, blockPtr);
        } else if (arg->IsObject() && enc->type == BinaryTypeEncodingType::StructDeclarationReference) {
            Local<Object> obj = arg.As<Object>();
            void* argBuffer = call->ArgumentBuffer(i);
            if (obj->InternalFieldCount() > 0) {
                Local<External> ext = obj->GetInternalField(0).As<External>();
                StructDataWrapper* wrapper = static_cast<StructDataWrapper*>(ext->Value());
                void* buffer = wrapper->Data();
                size_t size = wrapper->FFIType()->size;
                memcpy(argBuffer, buffer, size);
            } else {
                // Create the structure using the struct initializer syntax
                ptrdiff_t position = 0;
                const char* structName = enc->details.declarationReference.name.valuePtr();
                const Meta* meta = ArgConverter::GetMeta(structName);
                if (meta != nullptr && meta->type() == MetaType::Struct) {
                    const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
                    Interop::InitializeStruct(isolate, argBuffer, structMeta, obj, position);
                } else {
                    assert(false);
                }
            }
        } else if (arg->IsArray()) {
            Local<v8::Array> array = arg.As<v8::Array>();
            ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:array isolate:isolate];
            call->SetArgument(i, adapter);
        } else if (arg->IsObject() && enc->type == BinaryTypeEncodingType::ProtocolEncoding) {
            Local<Object> obj = arg.As<Object>();
            assert(obj->InternalFieldCount() > 0);
            Local<External> ext = obj->GetInternalField(0).As<External>();
            BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
            Protocol* proto = objc_getProtocol(wrapper->Name().c_str());
            call->SetArgument(i, proto);
        } else if (arg->IsObject() && enc->type == BinaryTypeEncodingType::ClassEncoding) {
            Local<Object> obj = arg.As<Object>();
            Local<Value> metadataProp = tns::GetPrivateValue(isolate, obj, tns::ToV8String(isolate, "metadata"));
            assert(!metadataProp.IsEmpty() && metadataProp->IsExternal());
            Local<External> extData = metadataProp.As<External>();
            ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(extData->Value());
            Class clazz = wrapper->Data();
            call->SetArgument(i, clazz);
        } else if (arg->IsObject()) {
            Local<Object> obj = arg.As<Object>();

            if (obj->InternalFieldCount() < 1) {
                DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:obj isolate:isolate];
                call->SetArgument(i, adapter);
            } else {
                Local<External> ext = obj->GetInternalField(0).As<External>();
                BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
                if (wrapper->Type() == WrapperType::Enum) {
                    EnumDataWrapper* enumWrapper = static_cast<EnumDataWrapper*>(wrapper);
                    Local<Context> context = isolate->GetCurrentContext();
                    std::string jsCode = enumWrapper->JSCode();
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
                    call->SetArgument(i, value);
                } else {
                    ObjCDataWrapper* objCDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                    id data = objCDataWrapper->Data();
                    call->SetArgument(i, data);
                }
            }
        } else {
            assert(false);
        }
    }
}

void Interop::InitializeStruct(Isolate* isolate, void* destBuffer, const StructMeta* structMeta, v8::Local<v8::Value> inititalizer, ptrdiff_t& position) {
    const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

    for (auto it = structMeta->fieldNames().begin(); it != structMeta->fieldNames().end(); it++) {
        const char* fieldName = (*it).valuePtr();
        Local<Value> value;
        if (!inititalizer.IsEmpty() && !inititalizer->IsNullOrUndefined() && inititalizer->IsObject()) {
            value = inititalizer.As<Object>()->Get(tns::ToV8String(isolate, fieldName));
        }

        if (fieldEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
            const Meta* meta = ArgConverter::GetMeta(fieldEncoding->details.declarationReference.name.valuePtr());
            if (meta != nullptr && meta->type() == MetaType::Struct) {
                Interop::InitializeStruct(isolate, destBuffer, static_cast<const StructMeta*>(meta), value, position);
            } else {
                assert(false);
            }
        } else if (fieldEncoding->type == BinaryTypeEncodingType::UShortEncoding) {
            position += Interop::SetStructValue<ushort>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::ShortEncoding) {
            position += Interop::SetStructValue<short>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::UIntEncoding) {
            position += Interop::SetStructValue<uint>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::IntEncoding) {
            position += Interop::SetStructValue<int>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
            position += Interop::SetStructValue<unsigned long>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::LongEncoding) {
            position += Interop::SetStructValue<long>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::ULongLongEncoding) {
            position += Interop::SetStructValue<unsigned long long>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::LongLongEncoding) {
            position += Interop::SetStructValue<long long>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::FloatEncoding) {
            position += Interop::SetStructValue<float>(value, destBuffer, position);
        } else if (fieldEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
            position += Interop::SetStructValue<double>(value, destBuffer, position);
        } else {
            // TODO: Unsupported struct field encoding
            assert(false);
        }

        fieldEncoding = fieldEncoding->next();
    }
}

template <typename T>
size_t Interop::SetStructValue(Local<Value> value, void* destBuffer, ptrdiff_t position) {
    double result = !value.IsEmpty() && !value->IsNullOrUndefined() && value->IsNumber()
        ? value.As<Number>()->Value() : 0;
    *static_cast<T*>((void*)((uint8_t*)destBuffer + position)) = result;
    return sizeof(T);
}

Local<Value> Interop::GetResult(Isolate* isolate, const TypeEncoding* typeEncoding, ffi_type* returnType, BaseFFICall* call, bool marshalToPrimitive, ffi_type* structFieldFFIType) {
    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
        // TODO: Cache the metadata
        const Meta* meta = MetaFile::instance()->globalTable()->findMeta(structName);
        assert(meta != nullptr && meta->type() == MetaType::Struct);
        const StructMeta* structMeta = static_cast<const StructMeta*>(meta);

        void* result = call->ResultBuffer();

        ffi_type* ffiType = (structFieldFFIType != nullptr) ? structFieldFFIType : returnType;

        void* dest = malloc(ffiType->size);
        memcpy(dest, result, ffiType->size);

        StructDataWrapper* wrapper = new StructDataWrapper(structMeta, dest, ffiType);
        return ArgConverter::ConvertArgument(isolate, wrapper);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        SEL result = call->GetResult<SEL>();
        if (result == nil) {
            return Null(isolate);
        }

        NSString* selStr = NSStringFromSelector(result);
        return tns::ToV8String(isolate, [selStr UTF8String]);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
        id result = call->GetResult<id>();
        if (result == nil) {
            return Null(isolate);
        }

        const char* protocolName = protocol_getName(result);
        auto it = Caches::ProtocolInstances.find(protocolName);
        if (it != Caches::ProtocolInstances.end()) {
            return it->second->Get(isolate);
        }

        Local<Object> proto = ArgConverter::CreateEmptyObject(isolate->GetCurrentContext());
        BaseDataWrapper* wrapper = new BaseDataWrapper(protocolName);
        Local<External> ext = External::New(isolate, wrapper);
        proto->SetInternalField(0, ext);

        Caches::ProtocolInstances.insert(std::make_pair(protocolName, new Persistent<Object>(isolate, proto)));
        return proto;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ClassEncoding) {
        Class result = call->GetResult<Class>();
        if (result == nullptr) {
            return Null(isolate);
        }

        const char* className = class_getName(result);
        auto it = Caches::CtorFuncs.find(className);
        if (it != Caches::CtorFuncs.end()) {
            return it->second->Get(isolate);
        }

        assert(false);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
        typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
        typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding) {

        id result = call->GetResult<id>();

        if (result == nil) {
            return Null(isolate);
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSString class]]) {
            // Convert NSString instances to javascript strings for all instance method calls
            const char* str = [result UTF8String];
            return tns::ToV8String(isolate, str);
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSNumber class]]) {
            // Convert NSNumber instances to javascript numbers for all instance method calls
            double value = [result doubleValue];
            return Number::New(isolate, value);
        }

        std::string className = object_getClassName(result);
        ObjCDataWrapper* wrapper = new ObjCDataWrapper(className, result);
        return ArgConverter::ConvertArgument(isolate, wrapper);
    }

    return Interop::GetPrimitiveReturnType(isolate, typeEncoding->type, call);
}

Local<Value> Interop::GetPrimitiveReturnType(Isolate* isolate, BinaryTypeEncodingType type, BaseFFICall* call) {
    if (type == BinaryTypeEncodingType::CStringEncoding) {
        char* result = call->GetResult<char*>();
        if (result == nullptr) {
            return Null(isolate);
        }

        return tns::ToV8String(isolate, result);
    }

    if (type == BinaryTypeEncodingType::BoolEncoding) {
        bool result = call->GetResult<bool>();
        return v8::Boolean::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UShortEncoding) {
        unsigned short result = call->GetResult<unsigned short>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ShortEncoding) {
        short result = call->GetResult<short>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UIntEncoding) {
        unsigned int result = call->GetResult<unsigned int>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::IntEncoding) {
        int result = call->GetResult<int>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ULongEncoding) {
        unsigned long result = call->GetResult<unsigned long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::LongEncoding) {
        long result = call->GetResult<long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ULongLongEncoding) {
        unsigned long long result = call->GetResult<unsigned long long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::LongLongEncoding) {
        long long result = call->GetResult<long long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::FloatEncoding) {
        float result = call->GetResult<float>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::DoubleEncoding) {
        double result = call->GetResult<double>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UnicharEncoding) {
        unichar result = call->GetResult<unichar>();
        char chars[2];

        if (result > 127) {
            chars[0] = (result >> 8) & (1 << 8) - 1;
            chars[1] = result & (1 << 8) - 1;
        } else {
            chars[0] = result;
            chars[1] = 0;
        }

        return tns::ToV8String(isolate, chars);
    }

    if (type == BinaryTypeEncodingType::UCharEncoding) {
        unsigned char result = call->GetResult<unsigned char>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::CharEncoding) {
        char result = call->GetResult<char>();
        return Number::New(isolate, result);
    }

    if (type != BinaryTypeEncodingType::VoidEncoding) {
        assert(false);
    }

    // TODO: Handle all the possible return types https://nshipster.com/type-encodings/

    return Local<Value>();
}

void Interop::SetStructPropertyValue(StructDataWrapper* wrapper, StructField field, Local<Value> value) {
    if (value.IsEmpty()) {
        return;
    }

    uint8_t* data = (uint8_t*)wrapper->Data();
    uint8_t* destBuffer = data + field.Offset();

    const TypeEncoding* fieldEncoding = field.Encoding();
    switch (fieldEncoding->type) {
        case BinaryTypeEncodingType::StructDeclarationReference: {
            Local<Object> obj = value.As<Object>();
            Local<External> ext = obj->GetInternalField(0).As<External>();
            StructDataWrapper* targetStruct = static_cast<StructDataWrapper*>(ext->Value());

            void* sourceBuffer = targetStruct->Data();
            size_t fieldSize = field.FFIType()->size;
            memcpy(destBuffer, sourceBuffer, fieldSize);
            break;
        }
        case BinaryTypeEncodingType::UShortEncoding: {
            unsigned short val = value.As<Number>()->Value();
            *static_cast<unsigned short*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            short val = value.As<Number>()->Value();
            *static_cast<short*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            unsigned int val = value.As<Number>()->Value();
            *static_cast<unsigned int*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            int val = value.As<Number>()->Value();
            *static_cast<int*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            unsigned long val = value.As<Number>()->Value();
            *static_cast<unsigned long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            unsigned long long val = value.As<Number>()->Value();
            *static_cast<unsigned long long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            long long val = value.As<Number>()->Value();
            *static_cast<long long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            float val = value.As<Number>()->Value();
            *static_cast<float*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            double val = value.As<Number>()->Value();
            *static_cast<double*>((void*)destBuffer) = val;
            break;
        }
        default: {
            // TODO: Handle all possible cases
            assert(false);
        }
    }
}

}
