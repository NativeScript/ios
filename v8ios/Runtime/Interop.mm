#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include "Interop.h"
#include "Helpers.h"
#include "DataWrapper.h"

using namespace v8;

namespace tns {

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = &copyBlock,
    .dispose = &disposeBlock
};

void Interop::RegisterInteropTypes(Isolate* isolate) {

}

IMP Interop::CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    ffi_cif* cif = new ffi_cif();
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

    ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, initialParamIndex + argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
    assert(status == FFI_OK);

    void* functionPointer;
    ffi_closure* closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &functionPointer));
    status = ffi_prep_closure_loc(closure, cif, callback, userData, functionPointer);
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
    
void Interop::CallFunction(Isolate* isolate, const FunctionMeta* functionMeta, const std::vector<Local<Value>> args) {
    void* functionPointer = Interop::GetFunctionPointer(functionMeta);

    const ffi_type** parameterTypesFFITypes = new const ffi_type*[args.size()]();

    int argsCount = functionMeta->encodings()->count - 1;
    const TypeEncoding* typeEncoding = functionMeta->encodings()->first();
    ffi_type* returnType = Interop::GetArgumentType(typeEncoding);
    for (int i = 0; i < argsCount; i++) {
        typeEncoding = typeEncoding->next();
        parameterTypesFFITypes[i] = Interop::GetArgumentType(typeEncoding);
    }

    ffi_cif* cif = new ffi_cif();
    ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
    assert(status == FFI_OK);

    typeEncoding = functionMeta->encodings()->first();
    void *values[args.size()];
    for (int i = 0; i < args.size(); i++) {
        Local<Value> arg = args[i];

        if (arg->IsNullOrUndefined()) {
            void* nullPtr = nullptr;
            values[i] = &nullPtr;
        } else if (arg->IsNumber() || arg->IsNumberObject()) {
            double value = arg.As<Number>()->Value();
            values[i] = &value;
        } else if (arg->IsString()) {
            NSString* s = [NSString stringWithUTF8String:tns::ToString(isolate, arg).c_str()];
            void* strPtr = (__bridge void*)s;
            values[i] = &strPtr;
        } else if (arg->IsObject()) {
            Local<Object> obj = arg.As<Object>();
            assert(obj->InternalFieldCount() > 0);
            Local<External> ext = obj->GetInternalField(0).As<External>();
            // TODO: Check the data wrapper type
            ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());
            id data = wrapper->Data();
            values[i] = &data;
        } else {
            assert(false);
        }
    }

    void* resultPtr;
    ffi_call(cif, FFI_FN(functionPointer), &resultPtr, values);
}

ffi_type* Interop::GetArgumentType(const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
        case BinaryTypeEncodingType::VoidEncoding: {
            return &ffi_type_void;
        }
        case BinaryTypeEncodingType::IdEncoding:
        case BinaryTypeEncodingType::InterfaceDeclarationReference:
        case BinaryTypeEncodingType::PointerEncoding: {
            return &ffi_type_pointer;
        }
        case BinaryTypeEncodingType::BoolEncoding: {
            return &ffi_type_sint8;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            return &ffi_type_sint32;
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

        const char* symbolName = meta->name();
        CFStringRef cfName = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, symbolName, kCFStringEncodingUTF8, kCFAllocatorNull);
        functionPointer = CFBundleGetFunctionPointerForName(bundle, cfName);
    } else if (moduleMeta->libraries->count == 1 && moduleMeta->isSystem()) {
        NSString* libsPath = [[NSBundle bundleForClass:[NSObject class]] bundlePath];
        NSString* libraryPath = [NSString stringWithFormat:@"%@/lib%s.dylib", libsPath, moduleMeta->libraries->first()->value().getName()];

        if (void* library = dlopen(libraryPath.UTF8String, RTLD_LAZY | RTLD_LOCAL)) {
            const char* symbolName = meta->name();
            functionPointer = dlsym(library, symbolName);
        }
    }

    assert(functionPointer != nullptr);
    return functionPointer;
}

}
