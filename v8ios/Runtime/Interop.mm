#include <Foundation/Foundation.h>
#include "Interop.h"

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

    ffi_type* returnType = GetArgumentType(typeEncoding);

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

    object_setClass((__bridge_transfer id)blockPointer, objc_getClass("__NSGlobalBlock__"));

    return blockPointer;
}

ffi_type* Interop::GetArgumentType(const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
        case BinaryTypeEncodingType::VoidEncoding: {
            return &ffi_type_void;
        }
        case BinaryTypeEncodingType::InterfaceDeclarationReference: {
            return &ffi_type_pointer;
        }
        default: {
            break;
        }
    }

    // TODO: implement all the possible encoding types
    assert(false);
}

}
