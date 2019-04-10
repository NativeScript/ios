#include <Foundation/Foundation.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "DataWrapper.h"
#include "ArgConverter.h"

using namespace v8;

namespace tns {

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = &copyBlock,
    .dispose = &disposeBlock
};

std::map<const TypeEncoding*, ffi_cif*> Interop::cifCache_;

IMP Interop::CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    ffi_cif* cif = nullptr;

    auto it = cifCache_.find(typeEncoding);
    if (it != cifCache_.end()) {
        cif = it->second;
    } else {
        const ffi_type** parameterTypesFFITypes = new const ffi_type*[argsCount + initialParamIndex]();

        ffi_type* returnType = Interop::GetArgumentType(typeEncoding);

        for (uint8_t i = 0; i < initialParamIndex; i++) {
            parameterTypesFFITypes[i] = &ffi_type_pointer;
        }

        for (uint8_t i = 0; i < argsCount; i++) {
            typeEncoding = typeEncoding->next();
            ffi_type* argType = GetArgumentType(typeEncoding);
            parameterTypesFFITypes[i + initialParamIndex] = argType;
        }

        cif = new ffi_cif();
        ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, initialParamIndex + argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
        assert(status == FFI_OK);

        cifCache_.insert(std::make_pair(typeEncoding, cif));
    }

    void* functionPointer;
    ffi_closure* closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &functionPointer));
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

    object_setClass((__bridge id)blockPointer, objc_getClass("__NSGlobalBlock__"));

    return blockPointer;
}

void* Interop::CallFunction(Isolate* isolate, const Meta* meta, id target, Class clazz, const std::vector<Local<Value>> args, bool callSuper) {
    void* functionPointer = nullptr;
    SEL selector;
    int initialParameterIndex = 0;
    const TypeEncoding* typeEncoding = nullptr;

    if (meta->type() == MetaType::Function) {
        const FunctionMeta* functionMeta = static_cast<const FunctionMeta*>(meta);
        functionPointer = GetFunctionPointer(functionMeta);
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

    int argsCount = (int)args.size();

    ffi_cif* cif = nullptr;
    auto it = cifCache_.find(typeEncoding);
    if (it != cifCache_.end()) {
        cif = it->second;
    } else {
        const ffi_type** parameterTypesFFITypes = new const ffi_type*[initialParameterIndex + argsCount]();
        ffi_type* returnType = Interop::GetArgumentType(typeEncoding);

        for (int i = 0; i < initialParameterIndex; i++) {
            parameterTypesFFITypes[i] = &ffi_type_pointer;
        }

        const TypeEncoding* enc = typeEncoding;
        for (int i = initialParameterIndex; i < initialParameterIndex + argsCount; i++) {
            enc = enc->next();
            parameterTypesFFITypes[i] = Interop::GetArgumentType(enc);
        }

        cif = new ffi_cif();
        ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, initialParameterIndex + argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
        assert(status == FFI_OK);

        cifCache_.insert(std::make_pair(typeEncoding, cif));
    }

    void* values[initialParameterIndex + argsCount];

    std::unique_ptr<objc_super> sup = std::unique_ptr<objc_super>(new objc_super());
    if (initialParameterIndex > 1) {
        if (target && target != nil) {
            if (callSuper) {
                sup->receiver = target;
                sup->super_class = class_getSuperclass(object_getClass(target));
                values[0] = &sup;
            } else {
                values[0] = &target;
            }
        } else {
            values[0] = &clazz;
        }
        values[1] = &selector;
    }

    for (int i = initialParameterIndex; i < initialParameterIndex + argsCount; i++) {
        typeEncoding = typeEncoding->next();
        Local<Value> arg = args[i - initialParameterIndex];

        if (arg->IsNullOrUndefined()) {
            void* nullPtr = nullptr;
            values[i] = &nullPtr;
        } else if (arg->IsBoolean() && typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
            bool value = arg.As<v8::Boolean>()->Value();
            if (!value) {
                void* nullPtr = nullptr;
                values[i] = &nullPtr;
            } else {
                values[i] = &value;
            }
        } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
            Local<External> ext = arg.As<Object>()->GetInternalField(0).As<External>();
            BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
            std::string protocolName = wrapper->Metadata()->name();
            Protocol* protocol = objc_getProtocol(protocolName.c_str());
            values[i] = &protocol;
        } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
            const char* s = tns::ToString(isolate, arg).c_str();
            values[i] = &s;
        } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
            std::string str = tns::ToString(isolate, arg);
            NSString* selStr = [NSString stringWithUTF8String:str.c_str()];
            SEL selector = NSSelectorFromString(selStr);
            values[i] = &selector;
        } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            std::string str = tns::ToString(isolate, arg);
            NSString* result = [NSString stringWithUTF8String:str.c_str()];
            void* value = (__bridge void*)result;
            values[i] = &value;
        } else if (arg->IsNumber() || arg->IsNumberObject()) {
            double value = arg.As<Number>()->Value();
            if (typeEncoding->type == BinaryTypeEncodingType::IntEncoding) {
                int val = (int)value;
                values[i] = &val;
            } else if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
                long val = (long)value;
                values[i] = &val;
            } else if (typeEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
                unsigned long val = (unsigned long)value;
                values[i] = &val;
            } else if (typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
                values[i] = &value;
            } else {
                assert(false);
            }
        } else if (arg->IsFunction() && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
            Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, arg.As<Object>());
            ObjectWeakCallbackState* state = new ObjectWeakCallbackState(poCallback);
            poCallback->SetWeak(state, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

            const TypeEncoding* blockTypeEncoding = typeEncoding->details.block.signature.first();
            int argsCount = typeEncoding->details.block.signature.count - 1;

            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding);
            CFTypeRef blockPtr = CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);
            values[i] = &blockPtr;
        } else if (arg->IsObject()) {
            Local<Object> obj = arg.As<Object>();
            assert(obj->InternalFieldCount() > 0);
            Local<External> ext = obj->GetInternalField(0).As<External>();
            // TODO: Check the data wrapper type
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
                values[i] = &value;
                continue;
            }

            id data = wrapper->Data();
            void* value = (__bridge void*)data;
            values[i] = &value;
        } else {
            assert(false);
        }
    }

    void* resultPtr = nullptr;
    ffi_call(cif, FFI_FN(functionPointer), &resultPtr, values);

    return resultPtr;
}

ffi_type* Interop::GetArgumentType(const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
        case BinaryTypeEncodingType::VoidEncoding: {
            return &ffi_type_void;
        }
        case BinaryTypeEncodingType::IdEncoding:
        case BinaryTypeEncodingType::InterfaceDeclarationReference:
        case BinaryTypeEncodingType::InstanceTypeEncoding:
        case BinaryTypeEncodingType::SelectorEncoding:
        case BinaryTypeEncodingType::BlockEncoding:
        case BinaryTypeEncodingType::CStringEncoding:
        case BinaryTypeEncodingType::PointerEncoding: {
            return &ffi_type_pointer;
        }
        case BinaryTypeEncodingType::BoolEncoding: {
            return &ffi_type_sint8;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            return &ffi_type_sint32;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            return &ffi_type_ulong;
        }
        case BinaryTypeEncodingType::LongEncoding: {
            return &ffi_type_slong;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            return &ffi_type_float;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            return &ffi_type_double;
        }
        default: {
            break;
        }
    }

    // TODO: implement all the possible encoding types
    assert(false);
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
