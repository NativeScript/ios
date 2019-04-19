#include <Foundation/Foundation.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "ArgConverter.h"

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

    RegisterInteropType(isolate, types, "void", BinaryTypeEncodingType::VoidEncoding);
    RegisterInteropType(isolate, types, "bool", BinaryTypeEncodingType::BoolEncoding);
    RegisterInteropType(isolate, types, "int8", BinaryTypeEncodingType::ShortEncoding);
    RegisterInteropType(isolate, types, "uint8", BinaryTypeEncodingType::UShortEncoding);
    RegisterInteropType(isolate, types, "int16", BinaryTypeEncodingType::IntEncoding);
    RegisterInteropType(isolate, types, "uint16", BinaryTypeEncodingType::UIntEncoding);
    RegisterInteropType(isolate, types, "int32", BinaryTypeEncodingType::LongEncoding);
    RegisterInteropType(isolate, types, "uint32", BinaryTypeEncodingType::ULongEncoding);
    RegisterInteropType(isolate, types, "int64", BinaryTypeEncodingType::LongLongEncoding);
    RegisterInteropType(isolate, types, "uint64", BinaryTypeEncodingType::ULongLongEncoding);
    RegisterInteropType(isolate, types, "float", BinaryTypeEncodingType::FloatEncoding);
    RegisterInteropType(isolate, types, "double", BinaryTypeEncodingType::DoubleEncoding);
    RegisterInteropType(isolate, types, "UTF8CString", BinaryTypeEncodingType::CStringEncoding);
    RegisterInteropType(isolate, types, "unichar", BinaryTypeEncodingType::UnicharEncoding);
    RegisterInteropType(isolate, types, "id", BinaryTypeEncodingType::IdEncoding);
    RegisterInteropType(isolate, types, "protocol", BinaryTypeEncodingType::ProtocolEncoding);
    RegisterInteropType(isolate, types, "class", BinaryTypeEncodingType::ClassEncoding);
    RegisterInteropType(isolate, types, "selector", BinaryTypeEncodingType::SelectorEncoding);

    bool success = interop->Set(tns::ToV8String(isolate, "types"), types);
    assert(success);

    success = global->Set(tns::ToV8String(isolate, "interop"), interop);
    assert(success);
}

void Interop::RegisterInteropType(Isolate* isolate, Local<Object> types, std::string name, BinaryTypeEncodingType encodingType) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> obj = ArgConverter::CreateEmptyObject(context);
    Local<External> ext = External::New(isolate, &encodingType);
    obj->SetInternalField(0, ext);
    bool success = types->Set(tns::ToV8String(isolate, name), obj);
    assert(success);
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

Local<Value> Interop::CallFunction(Isolate* isolate, const Meta* meta, id target, Class clazz, const std::vector<Local<Value>> args, bool callSuper) {
    void* functionPointer = nullptr;
    SEL selector = nil;
    int initialParameterIndex = 0;
    const TypeEncoding* typeEncoding = nullptr;

    if (meta->type() == MetaType::Function) {
        const FunctionMeta* functionMeta = static_cast<const FunctionMeta*>(meta);
        functionPointer = Interop::GetFunctionPointer(functionMeta);
        typeEncoding = functionMeta->encodings()->first();
    } else if (meta->type() == MetaType::Undefined || meta->type() == MetaType::Union) {
        const MethodMeta* methodMeta = static_cast<const MethodMeta*>(meta);
        initialParameterIndex = 2;
        typeEncoding = methodMeta->encodings()->first();
        selector = methodMeta->selector();
        if (callSuper) {
            functionPointer = (void*)objc_msgSendSuper;
        } else {
            functionPointer = (void*)objc_msgSend;
        }
    } else {
        assert(false);
    }

    int argsCount = initialParameterIndex + (int)args.size();

    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParameterIndex, argsCount);

    FFICall call(typeEncoding, initialParameterIndex, argsCount);

    std::unique_ptr<objc_super> sup = std::unique_ptr<objc_super>(new objc_super());

    if (initialParameterIndex > 1) {
#if defined(__x86_64__)
        if (meta->type() == MetaType::Undefined || meta->type() == MetaType::Union) {
            const unsigned UNIX64_FLAG_RET_IN_MEM = (1 << 10);

            ffi_type* returnType = FFICall::GetArgumentType(typeEncoding);

            if (returnType->type == FFI_TYPE_LONGDOUBLE) {
                functionPointer = (void*)objc_msgSend_fpret;
            } else if (returnType->type == FFI_TYPE_STRUCT && (cif->flags & UNIX64_FLAG_RET_IN_MEM)) {
                if (callSuper) {
                    functionPointer = (void*)objc_msgSend_stret;
                } else {
                    functionPointer = (void*)objc_msgSendSuper_stret;
                }
            }
        }
#endif

        if (target && target != nil) {
            if (callSuper) {
                sup->receiver = target;
                sup->super_class = class_getSuperclass(object_getClass(target));
                call.SetArgument(0, sup.get());
            } else {
                call.SetArgument(0, target);
            }
        } else {
            call.SetArgument(0, clazz);
        }

        call.SetArgument(1, selector);
    }

    Interop::SetFFIParams(isolate, typeEncoding, &call, argsCount, initialParameterIndex, args);

    ffi_call(cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    Local<Value> result = Interop::GetResult(isolate, typeEncoding, cif->rtype, &call);

    return result;
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
            std::string str = tns::ToString(isolate, arg);
            call->SetArgument(i, str.c_str());
        } else if (arg->IsString() && enc->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
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
            } else {
                assert(false);
            }
        } else if (arg->IsFunction() && enc->type == BinaryTypeEncodingType::BlockEncoding) {
            const TypeEncoding* blockTypeEncoding = enc->details.block.signature.first();
            int argsCount = enc->details.block.signature.count - 1;

            Persistent<Object>* poCallback = new Persistent<Object>(isolate, arg.As<Object>());
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding);
            CFTypeRef blockPtr = Interop::CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);
            call->SetArgument(i, blockPtr);
        } else if (arg->IsObject() && enc->type == BinaryTypeEncodingType::StructDeclarationReference) {
            Local<Object> obj = arg.As<Object>();
            assert(obj->InternalFieldCount() > 0);
            Local<External> ext = obj->GetInternalField(0).As<External>();
            RecordDataWrapper* wrapper = static_cast<RecordDataWrapper*>(ext->Value());
            void* buffer = wrapper->Data();
            size_t size = wrapper->FFIType()->size;
            void* argBuffer = call->ArgumentBuffer(i);
            memcpy(argBuffer, buffer, size);
        } else if (arg->IsObject()) {
            Local<Object> obj = arg.As<Object>();
            assert(obj->InternalFieldCount() > 0);
            Local<External> ext = obj->GetInternalField(0).As<External>();
            ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());

            const Meta* meta = wrapper->Metadata();
            if (meta != nullptr && meta->type() == MetaType::JsCode) {
                const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
                std::string jsCode = jsCodeMeta->jsCode();

                Local<Context> context = isolate->GetCurrentContext();
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
                continue;
            }

            id data = wrapper->Data();
            call->SetArgument(i, data);
        } else {
            assert(false);
        }
    }
}

Local<Value> Interop::GetResult(Isolate* isolate, const TypeEncoding* typeEncoding, ffi_type* returnType, BaseFFICall* call) {
    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
        // TODO: Cache the metadata
        const Meta* meta = MetaFile::instance()->globalTable()->findMeta(structName);
        assert(meta != nullptr && meta->type() == MetaType::Struct);
        const StructMeta* structMeta = static_cast<const StructMeta*>(meta);

        void* result = call->ResultBuffer();

        size_t rsize = returnType->size;
        void* dest = std::malloc(rsize);
        memcpy(dest, result, rsize);

        RecordDataWrapper* wrapper = new RecordDataWrapper(structMeta, dest, returnType);
        return ArgConverter::ConvertArgument(isolate, wrapper);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
        typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
        typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding) {

        id result = call->GetResult<id>();

        if (result == nil) {
            return Null(isolate);
        }

        // TODO: Create the proper DataWrapper type depending on the return value
        ObjCDataWrapper* wrapper = new ObjCDataWrapper(nullptr, result);
        return ArgConverter::ConvertArgument(isolate, wrapper);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
        char* result = call->GetResult<char*>();
        if (result == nullptr) {
            return Null(isolate);
        }

        return tns::ToV8String(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
        bool result = call->GetResult<bool>();
        return v8::Boolean::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::UShortEncoding) {
        unsigned short result = call->GetResult<unsigned short>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ShortEncoding) {
        short result = call->GetResult<short>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::UIntEncoding) {
        unsigned int result = call->GetResult<unsigned int>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::IntEncoding) {
        int result = call->GetResult<int>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
        unsigned long result = call->GetResult<unsigned long>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
        long result = call->GetResult<long>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ULongLongEncoding) {
        unsigned long long result = call->GetResult<unsigned long long>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::LongLongEncoding) {
        long long result = call->GetResult<long long>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::FloatEncoding) {
        float result = call->GetResult<float>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
        double result = call->GetResult<double>();
        return Number::New(isolate, result);
    }

    if (typeEncoding->type != BinaryTypeEncodingType::VoidEncoding) {
        assert(false);
    }

    // TODO: Handle all the possible return types https://nshipster.com/type-encodings/

    return Local<Value>();
}

void Interop::SetStructPropertyValue(RecordDataWrapper* wrapper, RecordField field, Local<Value> value) {
    if (value.IsEmpty()) {
        return;
    }

    void* sourceBuffer = nullptr;

    const TypeEncoding* fieldEncoding = field.Encoding();
    switch (fieldEncoding->type) {
        case BinaryTypeEncodingType::StructDeclarationReference: {
            Local<Object> obj = value.As<Object>();
            Local<External> ext = obj->GetInternalField(0).As<External>();
            RecordDataWrapper* targetStruct = static_cast<RecordDataWrapper*>(ext->Value());
            sourceBuffer = targetStruct->Data();
            break;
        }
        case BinaryTypeEncodingType::UShortEncoding: {
            unsigned short val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            short val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            unsigned int val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            int val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            unsigned long val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            unsigned long long val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            long long val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            float val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            double val = value.As<Number>()->Value();
            sourceBuffer = &val;
            break;
        }
        default: {
            // TODO: Handle all possible cases
            assert(false);
        }
    }

    void* destBuffer = (uint8_t*)wrapper->Data() + field.Offset();

    size_t fieldSize = field.Size();
    memcpy(destBuffer, sourceBuffer, fieldSize);
}

void* Interop::GetFunctionPointer(const FunctionMeta* meta) {
    // TODO: cache

    void* functionPointer = nullptr;

    const ModuleMeta* moduleMeta = meta->topLevelModule();
    const char* symbolName = meta->name();

    if (moduleMeta->isFramework()) {
        NSString* frameworkPathStr = [NSString stringWithFormat:@"%s.framework", moduleMeta->getName()];
        NSURL* baseUrl = nil;
        if (moduleMeta->isSystem()) {
#if TARGET_IPHONE_SIMULATOR
            NSBundle* foundation = [NSBundle bundleForClass:[NSString class]];
            NSString* foundationPath = [foundation bundlePath];
            NSString* basePathStr = [foundationPath substringToIndex:[foundationPath rangeOfString:@"Foundation.framework"].location];
            baseUrl = [NSURL fileURLWithPath:basePathStr isDirectory:YES];
#else
            baseUrl = [NSURL fileURLWithPath:@"/System/Library/Frameworks" isDirectory:YES];
#endif
        } else {
            baseUrl = [[NSBundle mainBundle] privateFrameworksURL];
        }

        NSURL* bundleUrl = [NSURL URLWithString:frameworkPathStr relativeToURL:baseUrl];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (CFURLRef)bundleUrl);
        assert(bundle != nullptr);

        CFErrorRef error = nullptr;
        bool loaded = CFBundleLoadExecutableAndReturnError(bundle, &error);
        assert(loaded);

        CFStringRef cfName = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, symbolName, kCFStringEncodingUTF8, kCFAllocatorNull);
        functionPointer = CFBundleGetFunctionPointerForName(bundle, cfName);
    } else if (moduleMeta->libraries->count == 1 && moduleMeta->isSystem()) {
        NSString* libsPath = [[NSBundle bundleForClass:[NSObject class]] bundlePath];
        NSString* libraryPath = [NSString stringWithFormat:@"%@/lib%s.dylib", libsPath, moduleMeta->libraries->first()->value().getName()];

        if (void* library = dlopen(libraryPath.UTF8String, RTLD_LAZY | RTLD_LOCAL)) {
            functionPointer = dlsym(library, symbolName);
        }
    }

    assert(functionPointer != nullptr);
    return functionPointer;
}

}
