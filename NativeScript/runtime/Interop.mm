#include <Foundation/Foundation.h>
#include <objc/message.h>
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "ArgConverter.h"
#include "DictionaryAdapter.h"
#include "SymbolLoader.h"
#include "ArrayAdapter.h"
#include "NSDataAdapter.h"
#include "Caches.h"
#include "Reference.h"
#include "Pointer.h"

using namespace v8;

namespace tns {

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = &copyBlock,
    .dispose = &disposeBlock
};

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

    blockPointer->userData = userData;

    object_setClass((__bridge id)blockPointer, objc_getClass("__NSMallocBlock__"));

    return blockPointer;
}

Local<Value> Interop::CallFunction(Isolate* isolate, const FunctionMeta* meta, const std::vector<Local<Value>> args) {
    void* functionPointer = SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
    if (!functionPointer) {
        NSLog(@"Unable to load \"%s\" function", meta->name());
        assert(false);
    }

    const TypeEncoding* typeEncoding = meta->encodings()->first();
    return Interop::CallFunction(isolate, functionPointer, typeEncoding, args);
}

Local<Value> Interop::CallFunction(Isolate* isolate, void* functionPointer, const TypeEncoding* typeEncoding, const std::vector<Local<Value>> args) {
    return Interop::CallFunctionInternal(isolate, true, functionPointer, typeEncoding, args, nil, nil, nil, false, MetaType::Undefined);
}

Local<Value> Interop::CallFunction(Isolate* isolate, const MethodMeta* meta, id target, Class clazz, const std::vector<Local<Value>> args, bool callSuper) {
    SEL selector = nil;
    void* functionPointer = nullptr;
    const TypeEncoding* typeEncoding = nullptr;
    bool isPrimitiveFunction = false;
    MetaType metaType = MetaType::Undefined;

    metaType = meta->type();
    selector = meta->selector();
    typeEncoding = meta->encodings()->first();
    if (callSuper) {
        functionPointer = (void*)objc_msgSendSuper;
    } else {
        functionPointer = (void*)objc_msgSend;
    }

    return Interop::CallFunctionInternal(isolate, isPrimitiveFunction, functionPointer, typeEncoding, args, target, clazz, selector, callSuper, metaType);
}

id Interop::CallInitializer(Isolate* isolate, const MethodMeta* methodMeta, id target, Class clazz, const std::vector<Local<Value>> args) {
    const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
    SEL selector = methodMeta->selector();
    void* functionPointer = (void*)objc_msgSend;

    int initialParameterIndex = 2;
    int argsCount = initialParameterIndex + (int)args.size();

    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParameterIndex, argsCount);
    FFICall call(cif);

    Interop::SetValue(call.ArgumentBuffer(0), target);
    Interop::SetValue(call.ArgumentBuffer(1), selector);
    Interop::SetFFIParams(isolate, typeEncoding, &call, argsCount, initialParameterIndex, args);

    ffi_call(cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    id result = call.GetResult<id>();

    return result;
}

void Interop::SetFFIParams(Isolate* isolate, const TypeEncoding* typeEncoding, FFICall* call, const int argsCount, const int initialParameterIndex, const std::vector<Local<Value>> args) {
    const TypeEncoding* enc = typeEncoding;
    for (int i = initialParameterIndex; i < argsCount; i++) {
        enc = enc->next();
        Local<Value> arg = args[i - initialParameterIndex];
        void* argBuffer = call->ArgumentBuffer(i);
        Interop::WriteValue(isolate, enc, argBuffer, arg);
    }
}

void Interop::WriteValue(Isolate* isolate, const TypeEncoding* typeEncoding, void* dest, Local<Value> arg) {
    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding, true);
        size_t size = ffiType->size;
        memset(dest, 0, size);
    } else if (tns::IsBool(arg) && typeEncoding->type == BinaryTypeEncodingType::IdEncoding) {
        bool value = tns::ToBool(arg);
        NSObject* o = @(value);
        Interop::SetValue(dest, o);
    } else if (tns::IsBool(arg)) {
        bool value = tns::ToBool(arg);
        Interop::SetValue(dest, value);
    } else if (tns::IsString(arg) && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        std::string str = tns::ToString(isolate, arg);
        NSString* selStr = [NSString stringWithUTF8String:str.c_str()];
        SEL selector = NSSelectorFromString(selStr);
        Interop::SetValue(dest, selector);
    } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
        v8::String::Utf8Value utf8Value(isolate, arg);
        const char* strCopy = strdup(*utf8Value);
        Interop::SetValue(dest, strCopy);
    } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::UnicharEncoding) {
        v8::String::Utf8Value utf8Value(isolate, arg);
        const char* strCopy = strdup(*utf8Value);
        if (strlen(strCopy) > 1) {
            tns::ThrowError(isolate, "Only one character string can be converted to unichar.");
            return;
        }
        unichar c = (strlen(strCopy) == 0) ? 0 : strCopy[0];
        Interop::SetValue(dest, c);
    } else if (tns::IsString(arg) && (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference || typeEncoding->type == BinaryTypeEncodingType::IdEncoding)) {
        std::string str = tns::ToString(isolate, arg);
        NSString* result = [NSString stringWithUTF8String:str.c_str()];
        Interop::SetValue(dest, result);
    } else if (tns::IsNumber(arg)) {
        double value = tns::ToNumber(arg);

        if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference || typeEncoding->type == BinaryTypeEncodingType::IdEncoding) {
            // NSNumber
            NSNumber* num = [NSNumber numberWithDouble:value];
            Interop::SetValue(dest, num);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UShortEncoding) {
            Interop::SetNumericValue<unsigned short>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ShortEncoding) {
            Interop::SetNumericValue<short>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UIntEncoding) {
            Interop::SetNumericValue<unsigned int>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::IntEncoding) {
            Interop::SetNumericValue<int>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
            Interop::SetNumericValue<unsigned long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
            Interop::SetNumericValue<long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ULongLongEncoding) {
            Interop::SetNumericValue<unsigned long long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::LongLongEncoding) {
            Interop::SetNumericValue<long long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::FloatEncoding) {
            Interop::SetNumericValue<float>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
            Interop::SetNumericValue<double>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UCharEncoding) {
            Interop::SetNumericValue<unsigned char>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::CharEncoding) {
            Interop::SetNumericValue<char>(dest, value);
        } else {
            assert(false);
        }
    } else if (typeEncoding->type == BinaryTypeEncodingType::PointerEncoding) {
        const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg.As<Object>());
        if (innerType->type == BinaryTypeEncodingType::VoidEncoding) {
            assert(wrapper != nullptr);

            if (wrapper->Type() == WrapperType::Pointer) {
                PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
                void* data = pointerWrapper->Data();
                Interop::SetValue(dest, data);
            } else {
                // TODO:
                assert(false);
            }
        } else {
            assert(wrapper != nullptr);

            void* data = nullptr;

            if (wrapper->Type() == WrapperType::Pointer) {
                PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
                data = pointerWrapper->Data();
            } else if (wrapper->Type() == WrapperType::Reference) {
                ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
                Local<Value> value = referenceWrapper->Value() != nullptr ? referenceWrapper->Value()->Get(isolate) : Local<Value>();
                ffi_type* ffiType = FFICall::GetArgumentType(innerType);
                data = calloc(ffiType->size, 1);
                referenceWrapper->SetData(data);
                referenceWrapper->SetEncoding(innerType);
                // Initialize the ref/out parameter value before passing it to the function call
                if (!value.IsEmpty()) {
                    Interop::WriteValue(isolate, innerType, data, value);
                }
            } else {
                assert(false);
            }

            Interop::SetValue(dest, data);
        }
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::FunctionPointerEncoding) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg.As<Object>());
        assert(wrapper != nullptr && wrapper->Type() == WrapperType::FunctionReference);
        FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
        const TypeEncoding* functionTypeEncoding = typeEncoding->details.functionPointer.signature.first();
        int argsCount = typeEncoding->details.functionPointer.signature.count - 1;

        Local<Value> callbackValue = funcWrapper->Function()->Get(isolate);
        assert(callbackValue->IsFunction());
        Local<v8::Function> callback = callbackValue.As<v8::Function>();
        Persistent<Value>* poCallback = new Persistent<Value>(isolate, callback);
        MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 0, argsCount, functionTypeEncoding);

        void* functionPointer = (void*)Interop::CreateMethod(0, argsCount, functionTypeEncoding, ArgConverter::MethodCallback, userData);

        funcWrapper->SetData(functionPointer);

        Interop::SetValue(dest, functionPointer);
    } else if (arg->IsFunction() && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        const TypeEncoding* blockTypeEncoding = typeEncoding->details.block.signature.first();
        int argsCount = typeEncoding->details.block.signature.count - 1;

        Persistent<Value>* poCallback = new Persistent<Value>(isolate, arg);
        MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding);
        CFTypeRef blockPtr = Interop::CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);

        BlockWrapper* wrapper = new BlockWrapper((void*)blockPtr, blockTypeEncoding);
        tns::SetValue(isolate, arg.As<Object>(), wrapper);

        Interop::SetValue(dest, blockPtr);
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        if (wrapper != nullptr) {
            if (wrapper->Type() == WrapperType::Struct) {
                StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
                void* buffer = structWrapper->Data();
                size_t size = structWrapper->StructInfo().FFIType()->size;
                memcpy(dest, buffer, size);
            } else if (wrapper->Type() == WrapperType::Reference) {
                void* data = Reference::GetWrappedPointer(isolate, arg, typeEncoding);
                assert(data != nullptr);
                ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding);
                size_t size = ffiType->size;
                memcpy(dest, data, size);
            } else {
                assert(false);
            }
        } else {
            // Create the structure using the struct initializer syntax
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const Meta* meta = ArgConverter::GetMeta(structName);
            assert(meta != nullptr && meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            StructInfo structInfo = FFICall::GetStructInfo(structMeta);
            Interop::InitializeStruct(isolate, dest, structInfo.Fields(), obj);
        }
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::AnonymousStructEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        if (wrapper != nullptr && wrapper->Type() == WrapperType::Struct) {
            size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
            StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);

            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            size_t size = structInfo.FFIType()->size;
            memcpy(dest, data, size);
        } else {
            // Anonymous structs can only be initialized with plain javascript objects
            assert(wrapper == nullptr);
            size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
            StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
            Interop::InitializeStruct(isolate, dest, structInfo.Fields(), obj);
        }
    } else if (arg->IsFunction() && typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
        assert(wrapper != nullptr && wrapper->Type() == WrapperType::ObjCProtocol);
        ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrapper);
        Protocol* proto = protoWrapper->Proto();
        Interop::SetValue(dest, proto);
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::ClassEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
        assert(wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass);
        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
        Class clazz = classWrapper->Klass();
        Interop::SetValue(dest, clazz);
    } else if (arg->IsDate()) {
        Local<Date> date = arg.As<Date>();
        double time = date->ValueOf();
        NSDate* nsDate = [NSDate dateWithTimeIntervalSince1970:(time / 1000)];
        Interop::SetValue(dest, nsDate);
    } else if (typeEncoding->type == BinaryTypeEncodingType::IncompleteArrayEncoding) {
        void* data = nullptr;
        if (arg->IsArrayBuffer()) {
            v8::ArrayBuffer::Contents contents = arg.As<ArrayBuffer>()->GetContents();
            data = contents.Data();
        } else if (arg->IsArrayBufferView()) {
            v8::ArrayBuffer::Contents contents = arg.As<ArrayBufferView>()->Buffer()->GetContents();
            data = contents.Data();
        } else {
            data = Reference::GetWrappedPointer(isolate, arg, typeEncoding);
        }
        Interop::SetValue(dest, data);
    } else if (typeEncoding->type == BinaryTypeEncodingType::ConstantArrayEncoding) {
        if (arg->IsArray()) {
            Local<v8::Array> array = arg.As<v8::Array>();
            Local<Context> context = isolate->GetCurrentContext();
            const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
            ffi_type* ffiType = FFICall::GetArgumentType(innerType);
            uint32_t length = array->Length();
            for (uint32_t i = 0; i < length; i++) {
                Local<Value> element;
                bool success = array->Get(context, i).ToLocal(&element);
                assert(success);
                void* ptr = (uint8_t*)dest + i * ffiType->size;
                Interop::WriteValue(isolate, innerType, ptr, element);
            }
        } else {
            void* data = Reference::GetWrappedPointer(isolate, arg, typeEncoding);
            Interop::SetValue(dest, data);
        }
    } else if (arg->IsObject()) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);

        if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            const char* name = typeEncoding->details.declarationReference.name.valuePtr();
            Class klass = objc_getClass(name);
            if (!klass) {
                assert(false);
            }

            if (klass == [NSArray class]) {
                if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
                    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                    id target = objcWrapper->Data();
                    if ([target isKindOfClass:[NSArray class]]) {
                        Interop::SetValue(dest, target);
                        return;
                    }
                }
                Local<v8::Array> array = Interop::ToArray(isolate, obj);
                ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:array isolate:isolate];
                Caches::Get(isolate)->Instances.emplace(std::make_pair(adapter, new Persistent<Value>(isolate, obj)));
                Interop::SetValue(dest, adapter);
                return;
            } else if ((klass == [NSData class] || klass == [NSMutableData class]) && (arg->IsArrayBuffer() || arg->IsArrayBufferView())) {
                Local<ArrayBuffer> buffer = arg.As<ArrayBuffer>();
                NSDataAdapter* adapter = [[NSDataAdapter alloc] initWithJSObject:buffer isolate:isolate];
                Caches::Get(isolate)->Instances.emplace(std::make_pair(adapter, new Persistent<Value>(isolate, obj)));
                Interop::SetValue(dest, adapter);
                return;
            } else if (klass == [NSDictionary class]) {
                if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
                    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                    id target = objcWrapper->Data();
                    if ([target isKindOfClass:[NSDictionary class]]) {
                        Interop::SetValue(dest, target);
                        return;
                    }
                }
                DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:obj isolate:isolate];
                Caches::Get(isolate)->Instances.emplace(std::make_pair(adapter, new Persistent<Value>(isolate, obj)));
                Interop::SetValue(dest, adapter);
                return;
            }
        }

        assert(wrapper != nullptr);

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
            SetValue(dest, value);
        } else if (wrapper->Type() == WrapperType::Pointer) {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            void* data = pointerWrapper->Data();
            Interop::SetValue(dest, data);
        } else if (wrapper->Type() == WrapperType::ObjCObject) {
            ObjCDataWrapper* objCDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            id data = objCDataWrapper->Data();
            Interop::SetValue(dest, data);
        } else {
            assert(false);
        }
    } else {
        assert(false);
    }
}

id Interop::ToObject(v8::Isolate* isolate, v8::Local<v8::Value> arg) {
    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        return nil;
    } else if (tns::IsString(arg)) {
        std::string value = tns::ToString(isolate, arg);
        NSString* result = [NSString stringWithUTF8String:value.c_str()];
        return result;
    } else if (tns::IsNumber(arg)) {
        double value = tns::ToNumber(arg);
        return @(value);
    } else if (tns::IsBool(arg)) {
        bool value = tns::ToBool(arg);
        return @(value);
    } else if (arg->IsArray()) {
        ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:arg.As<v8::Array>() isolate:isolate];
        return adapter;
    } else if (arg->IsObject()) {
        if (BaseDataWrapper* wrapper = tns::GetValue(isolate, arg)) {
            switch (wrapper->Type()) {
                case WrapperType::ObjCObject: {
                    ObjCDataWrapper* wr = static_cast<ObjCDataWrapper*>(wrapper);
                    return wr->Data();
                    break;
                }
                case WrapperType::ObjCClass: {
                    ObjCClassWrapper* wr = static_cast<ObjCClassWrapper*>(wrapper);
                    return wr->Klass();
                    break;
                }
                case WrapperType::ObjCProtocol: {
                    ObjCProtocolWrapper* wr = static_cast<ObjCProtocolWrapper*>(wrapper);
                    return wr->Proto();
                    break;
                }
                default:
                    // TODO: Unsupported object type
                    assert(false);
                    break;
            }
        } else {
            DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:arg.As<Object>() isolate:isolate];
            return adapter;
        }
    }

    // TODO: Handle other possible types
    assert(false);
}

Local<Value> Interop::StructToValue(Isolate* isolate, void* result, StructInfo structInfo, bool copyStructs) {
    StructWrapper* wrapper = nullptr;
    if (copyStructs) {
        ffi_type* ffiType = structInfo.FFIType();
        void* dest = malloc(ffiType->size);
        memcpy(dest, result, ffiType->size);

        wrapper = new StructWrapper(structInfo, dest);
    } else {
        wrapper = new StructWrapper(structInfo, result);
    }

    Caches* cache = Caches::Get(isolate);
    std::pair<void*, std::string> key = std::make_pair(wrapper->Data(), structInfo.Name());
    auto it = cache->StructInstances.find(key);
    if (it != cache->StructInstances.end()) {
        return it->second->Get(isolate);
    }

    Local<Value> res = ArgConverter::ConvertArgument(isolate, wrapper);
    Persistent<Value>* poResult = new Persistent<Value>(isolate, res);
    if (copyStructs) {
        cache->StructInstances.insert(std::make_pair(key, poResult));
    }
    return res;
}

void Interop::InitializeStruct(Isolate* isolate, void* destBuffer, std::vector<StructField> fields, Local<Value> inititalizer) {
    ptrdiff_t position = 0;
    Interop::InitializeStruct(isolate, destBuffer, fields, inititalizer, position);
}

void Interop::InitializeStruct(Isolate* isolate, void* destBuffer, std::vector<StructField> fields, Local<Value> inititalizer, ptrdiff_t& position) {
    Local<Context> context = isolate->GetCurrentContext();
    for (auto it = fields.begin(); it != fields.end(); it++) {
        StructField field = *it;

        Local<Value> value;
        if (!inititalizer.IsEmpty() && !inititalizer->IsNullOrUndefined() && inititalizer->IsObject()) {
            bool success = inititalizer.As<Object>()->Get(context, tns::ToV8String(isolate, field.Name())).ToLocal(&value);
            assert(success);
        }

        BinaryTypeEncodingType type = field.Encoding()->type;

        if (type == BinaryTypeEncodingType::StructDeclarationReference) {
            const Meta* meta = ArgConverter::GetMeta(field.Encoding()->details.declarationReference.name.valuePtr());
            assert(meta != nullptr && meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            StructInfo nestedStructInfo = FFICall::GetStructInfo(structMeta);
            Interop::InitializeStruct(isolate, destBuffer, nestedStructInfo.Fields(), value, position);
            position += nestedStructInfo.FFIType()->size;
        } else if (type == BinaryTypeEncodingType::AnonymousStructEncoding) {
            size_t fieldsCount = field.Encoding()->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = field.Encoding()->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = field.Encoding()->details.anonymousRecord.getFieldNames();
            StructInfo nestedStructInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
            ptrdiff_t offset = position + field.Offset();
            uint8_t* dst = (uint8_t*)destBuffer + offset;
            Interop::InitializeStruct(isolate, dst, nestedStructInfo.Fields(), value, position);
            position += nestedStructInfo.FFIType()->size;
        } else if (type == BinaryTypeEncodingType::ConstantArrayEncoding) {
            const TypeEncoding* innerType = field.Encoding()->details.constantArray.getInnerType();
            ffi_type* ffiType = FFICall::GetArgumentType(innerType);
            uint32_t length = field.Encoding()->details.constantArray.size;
            ptrdiff_t offset = position + field.Offset();

            if (value.IsEmpty()) {
                position += length;
            } else if (value->IsArray()) {
                Local<v8::Array> array = value.As<v8::Array>();
                uint32_t min = std::min(length, array->Length());
                for (uint32_t index = 0; index < min; index++) {
                    Local<Value> element;
                    bool success = array->Get(context, index).ToLocal(&element);
                    assert(success);
                    uint8_t* dst = (uint8_t*)destBuffer + offset;
                    Interop::WriteValue(isolate, innerType, dst, element);
                    offset += ffiType->size;
                }
            } else {
                void* data = Reference::GetWrappedPointer(isolate, value, field.Encoding());
                assert(data != nullptr);
                uint8_t* dst = (uint8_t*)destBuffer + offset;
                memcpy(dst, data, length * ffiType->size);
            }
        } else if (type == BinaryTypeEncodingType::FunctionPointerEncoding) {
            Interop::WriteValue(isolate, field.Encoding(), destBuffer, value);
        } else if (type == BinaryTypeEncodingType::PointerEncoding) {
            const TypeEncoding* innerType = field.Encoding()->details.pointer.getInnerType();
            Interop::WriteValue(isolate, innerType, destBuffer, value);
        } else {
            ptrdiff_t offset = position + field.Offset();

            if (type == BinaryTypeEncodingType::UCharEncoding) {
                Interop::SetStructValue<unsigned char>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::UShortEncoding) {
                Interop::SetStructValue<ushort>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ShortEncoding) {
                Interop::SetStructValue<short>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::UIntEncoding) {
                Interop::SetStructValue<uint>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::IntEncoding) {
                Interop::SetStructValue<int>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ULongEncoding) {
                Interop::SetStructValue<unsigned long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::LongEncoding) {
                Interop::SetStructValue<long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ULongLongEncoding) {
                Interop::SetStructValue<unsigned long long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::LongLongEncoding) {
                Interop::SetStructValue<long long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::FloatEncoding) {
                Interop::SetStructValue<float>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::DoubleEncoding) {
                Interop::SetStructValue<double>(value, destBuffer, offset);
            } else {
                // TODO: Unsupported struct field encoding
                assert(false);
            }
        }
    }
}

template <typename T>
void Interop::SetStructValue(Local<Value> value, void* destBuffer, ptrdiff_t position) {
    double result = !value.IsEmpty() && !value->IsNullOrUndefined() && value->IsNumber()
        ? value.As<Number>()->Value() : 0;
    *static_cast<T*>((void*)((uint8_t*)destBuffer + position)) = result;
}

Local<Value> Interop::GetResult(Isolate* isolate, const TypeEncoding* typeEncoding, BaseCall* call, bool marshalToPrimitive, bool copyStructs) {
    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
        const Meta* meta = ArgConverter::GetMeta(structName);
        assert(meta != nullptr && meta->type() == MetaType::Struct);

        void* result = call->ResultBuffer();

        const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
        StructInfo structInfo = FFICall::GetStructInfo(structMeta);
        Local<Value> value = Interop::StructToValue(isolate, result, structInfo, copyStructs);
        return value;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::AnonymousStructEncoding) {
        size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
        const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
        const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
        StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
        void* result = call->ResultBuffer();
        Local<Value> value = Interop::StructToValue(isolate, result, structInfo, copyStructs);
        return value;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ConstantArrayEncoding) {
        const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
        ffi_type* innerFFIType = FFICall::GetArgumentType(innerType);
        int length = typeEncoding->details.constantArray.size;
        Local<v8::Array> array = v8::Array::New(isolate, length);
        Local<Context> context = isolate->GetCurrentContext();

        for (int i = 0; i < length; i++) {
            size_t offset = i * innerFFIType->size;
            BaseCall bc((uint8_t*)call->ResultBuffer(), offset);
            Local<Value> element = Interop::GetResult(isolate, innerType, &bc, false);
            bool success = array->Set(context, i, element).FromMaybe(false);
            assert(success);
        }
        return array;
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

        Protocol* protocol = static_cast<Protocol*>(result);
        const ProtocolMeta* protocolMeta = ArgConverter::FindProtocolMeta(protocol);
        if (protocolMeta == nullptr) {
            // Unable to find protocol metadata
            assert(false);
        }

        auto cache = Caches::Get(isolate);
        cache->MetaInitializer(protocolMeta);

        auto it = cache->ProtocolCtorFuncs.find(protocolMeta->name());
        if (it != cache->ProtocolCtorFuncs.end()) {
            return it->second->Get(isolate);
        }

        assert(false);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ClassEncoding) {
        Class result = call->GetResult<Class>();
        if (result == nil) {
            return Null(isolate);
        }

        Caches* cache = Caches::Get(isolate);
        while (true) {
            const char* name = class_getName(result);
            auto it = cache->CtorFuncs.find(name);
            if (it != cache->CtorFuncs.end()) {
                return it->second->Get(isolate);
            }

            result = class_getSuperclass(result);
            if (!result) {
                break;
            }
        }

        assert(false);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        JSBlock* block = call->GetResult<JSBlock*>();

        if (block == nullptr) {
            return Null(isolate);
        }

        if (block->descriptor == &JSBlock::kJSBlockDescriptor) {
            MethodCallbackWrapper* wrapper = static_cast<MethodCallbackWrapper*>(block->userData);
            Local<v8::Function> callback = wrapper->callback_->Get(isolate).As<v8::Function>();
            return callback;
        }

        Local<Context> context = isolate->GetCurrentContext();
        BlockWrapper* blockWrapper = new BlockWrapper(block, typeEncoding);
        Local<External> ext = External::New(isolate, blockWrapper);
        Local<v8::Function> callback;

        CFRetain(block);

        bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
            Local<External> ext = info.Data().As<External>();
            BlockWrapper* wrapper = static_cast<BlockWrapper*>(ext->Value());

            JSBlock* block = static_cast<JSBlock*>(wrapper->Block());

            const TypeEncoding* typeEncoding = wrapper->Encodings();
            int argsCount = typeEncoding->details.block.signature.count;
            const TypeEncoding* enc = typeEncoding->details.block.signature.first();

            ffi_cif* cif = FFICall::GetCif(enc, 1, argsCount);
            FFICall call(cif);

            std::vector<Local<Value>> args = tns::ArgsToVector(info);
            Isolate* isolate = info.GetIsolate();
            Interop::SetValue(call.ArgumentBuffer(0), block);
            Interop::SetFFIParams(isolate, enc, &call, argsCount, 1, args);

            ffi_call(cif, FFI_FN(block->invoke), call.ResultBuffer(), call.ArgsArray());

            Local<Value> result = Interop::GetResult(isolate, enc, &call, true, true);

            info.GetReturnValue().Set(result);
        }, ext).ToLocal(&callback);
        assert(success);

        tns::SetValue(isolate, callback, blockWrapper);

        return callback;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::FunctionPointerEncoding) {
        uint8_t* functionPointer = call->GetResult<uint8_t*>();
        if (functionPointer == nullptr) {
            return Null(isolate);
        }

        const TypeEncoding* parametersEncoding = typeEncoding->details.functionPointer.signature.first();
        size_t parametersCount = typeEncoding->details.functionPointer.signature.count;
        AnonymousFunctionWrapper* wrapper = new AnonymousFunctionWrapper(functionPointer, parametersEncoding, parametersCount);
        Local<External> ext = External::New(isolate, wrapper);

        Local<Context> context = isolate->GetCurrentContext();
        Local<v8::Function> func;
        bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
            Isolate* isolate = info.GetIsolate();
            AnonymousFunctionWrapper* wrapper = static_cast<AnonymousFunctionWrapper*>(info.Data().As<External>()->Value());
            assert(wrapper != nullptr);

            const std::vector<Local<Value>> args = tns::ArgsToVector(info);
            void* functionPointer = wrapper->Data();
            const TypeEncoding* typeEncoding = wrapper->ParametersEncoding();

            Local<Value> result = Interop::CallFunction(isolate, functionPointer, typeEncoding, args);

            info.GetReturnValue().Set(result);
        }, ext).ToLocal(&func);
        assert(success);

        tns::SetValue(isolate, func, wrapper);
        ObjectManager::Register(isolate, func);

        return func;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::PointerEncoding) {
        uint8_t* result = call->GetResult<uint8_t*>();
        if (result == nullptr) {
            return Null(isolate);
        }

        const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();

        if (innerType->type == BinaryTypeEncodingType::VoidEncoding) {
            Local<Value> instance = Pointer::NewInstance(isolate, result);
            return instance;
        }

        BaseCall c(result);
        Local<Value> value = Interop::GetResult(isolate, innerType, &c, true);

        Local<v8::Function> interopReferenceCtorFunc = Reference::GetInteropReferenceCtorFunc(isolate);
        Local<Value> args[1] = { value };
        Local<Context> context = isolate->GetCurrentContext();
        Local<Object> instance;
        bool success = interopReferenceCtorFunc->NewInstance(context, 1, args).ToLocal(&instance);
        ObjectManager::Register(isolate, instance);
        assert(success);

        return instance;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
        typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
        typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding) {

        id result = call->GetResult<id>();

        if (result == nil) {
            return Null(isolate);
        }

        if (marshalToPrimitive && result == [NSNull null]) {
            return Null(isolate);
        }

        if ([result isKindOfClass:[@YES class]]) {
            return v8::Boolean::New(isolate, [result boolValue]);
        }

        if ([result isKindOfClass:[NSDate class]]) {
            Local<Context> context = isolate->GetCurrentContext();
            double time = [result timeIntervalSince1970] * 1000.0;
            Local<Value> date;
            if (Date::New(context, time).ToLocal(&date)) {
                return date;
            }

            // TODO: invalid date
            assert(false);
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSString class]]) {
            if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
                const char* returnClassName = typeEncoding->details.declarationReference.name.valuePtr();
                Class returnClass = objc_getClass(returnClassName);
                if (returnClass != nil && returnClass == [NSMutableString class]) {
                    marshalToPrimitive = false;
                }
            }

            if (marshalToPrimitive) {
                // Convert NSString instances to javascript strings for all instance method calls
                const char* str = [result UTF8String];
                return tns::ToV8String(isolate, str);
            }
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSNumber class]] && ![result isKindOfClass:[NSDecimalNumber class]]) {
            // Convert NSNumber instances to javascript numbers for all instance method calls
            double value = [result doubleValue];
            return Number::New(isolate, value);
        }

        auto cache = Caches::Get(isolate);
        auto it = cache->Instances.find(result);
        if (it != cache->Instances.end()) {
            return it->second->Get(isolate);
        }

        ObjCDataWrapper* wrapper = new ObjCDataWrapper(result);
        Local<Value> jsResult = ArgConverter::ConvertArgument(isolate, wrapper);

        return jsResult;
    }

    return Interop::GetPrimitiveReturnType(isolate, typeEncoding->type, call);
}

Local<Value> Interop::GetPrimitiveReturnType(Isolate* isolate, BinaryTypeEncodingType type, BaseCall* call) {
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

void Interop::SetStructPropertyValue(Isolate* isolate, StructWrapper* wrapper, StructField field, Local<Value> value) {
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
            StructWrapper* targetStruct = static_cast<StructWrapper*>(ext->Value());

            void* sourceBuffer = targetStruct->Data();
            size_t fieldSize = field.FFIType()->size;
            memcpy(destBuffer, sourceBuffer, fieldSize);
            break;
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            Interop::WriteValue(isolate, fieldEncoding, destBuffer, value);
            break;
        }
        case BinaryTypeEncodingType::PointerEncoding: {
            BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
            assert(wrapper != nullptr && wrapper->Type() == WrapperType::Struct);
            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            Interop::SetValue(destBuffer, data);
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
        case BinaryTypeEncodingType::LongEncoding: {
            long val = value.As<Number>()->Value();
            *static_cast<long*>((void*)destBuffer) = val;
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

Local<v8::Array> Interop::ToArray(Isolate* isolate, Local<Object> object) {
    if (object->IsArray()) {
        return object.As<v8::Array>();
    }

    Local<v8::Function> sliceFunc;
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* poSliceFunc = cache->SliceFunc;

    if (poSliceFunc != nullptr) {
        sliceFunc = poSliceFunc->Get(isolate);
    } else {
        std::string source = "Array.prototype.slice";
        Local<Context> context = isolate->GetCurrentContext();
        Local<Script> script;
        if (!Script::Compile(context, tns::ToV8String(isolate, source)).ToLocal(&script)) {
            assert(false);
        }
        assert(!script.IsEmpty());

        Local<Value> tempSliceFunc;
        if (!script->Run(context).ToLocal(&tempSliceFunc)) {
            assert(false);
        }

        assert(tempSliceFunc->IsFunction());
        sliceFunc = tempSliceFunc.As<v8::Function>();
        cache->SliceFunc = new Persistent<v8::Function>(isolate, sliceFunc);
    }

    Local<Value> sliceArgs[1] { object };

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result;
    bool success = sliceFunc->Call(context, object, 1, sliceArgs).ToLocal(&result);
    assert(success);

    return result.As<v8::Array>();
}

Local<Value> Interop::CallFunctionInternal(Isolate* isolate, bool isPrimitiveFunction, void* functionPointer, const TypeEncoding* typeEncoding, const std::vector<Local<Value>> args, id target, Class clazz, SEL selector, bool callSuper, MetaType metaType) {
    int initialParameterIndex = isPrimitiveFunction ? 0 : 2;

    int argsCount = initialParameterIndex + (int)args.size();

    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParameterIndex, argsCount);

    FFICall call(cif);

    std::unique_ptr<objc_super> sup = std::unique_ptr<objc_super>(new objc_super());

    bool isInstanceMethod = (target && target != nil);

    if (initialParameterIndex > 1) {
#if defined(__x86_64__)
        if (metaType == MetaType::Undefined || metaType == MetaType::Union) {
            const unsigned UNIX64_FLAG_RET_IN_MEM = (1 << 10);

            ffi_type* returnType = FFICall::GetArgumentType(typeEncoding);

            if (returnType->type == FFI_TYPE_LONGDOUBLE) {
                functionPointer = (void*)objc_msgSend_fpret;
            } else if (returnType->type == FFI_TYPE_STRUCT && (cif->flags & UNIX64_FLAG_RET_IN_MEM)) {
                if (callSuper) {
                    functionPointer = (void*)objc_msgSendSuper_stret;
                } else {
                    functionPointer = (void*)objc_msgSend_stret;
                }
            }
        }
#endif

        if (isInstanceMethod) {
            if (callSuper) {
                sup->receiver = target;
                sup->super_class = class_getSuperclass(object_getClass(target));
                Interop::SetValue(call.ArgumentBuffer(0), sup.get());
            } else {
                Interop::SetValue(call.ArgumentBuffer(0), target);
            }
        } else {
            Interop::SetValue(call.ArgumentBuffer(0), clazz);
        }

        Interop::SetValue(call.ArgumentBuffer(1), selector);
    }

    bool isInstanceReturnType = typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding;
    bool marshalToPrimitive = isPrimitiveFunction || !isInstanceReturnType;

    @autoreleasepool {
        Interop::SetFFIParams(isolate, typeEncoding, &call, argsCount, initialParameterIndex, args);
    }

    ffi_call(cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    @autoreleasepool {
        Local<Value> result = Interop::GetResult(isolate, typeEncoding, &call, marshalToPrimitive, true);

        return result;
    }
}

}
