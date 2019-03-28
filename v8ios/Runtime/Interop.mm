#include <Foundation/Foundation.h>
#include "Interop.h"

namespace tns {

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = &copyBlock,
    .dispose = &disposeBlock
};

IMP Interop::CreateMethod(const uint8_t initialParamIndex, const uint8_t paramsCount, FFIMethodCallback callback, void* userData) {
    ffi_cif* cif = new ffi_cif();
    const ffi_type** parameterTypesFFITypes = new const ffi_type*[paramsCount + initialParamIndex]();

    for (uint8_t i = 0; i < initialParamIndex; i++) {
        parameterTypesFFITypes[i] = &ffi_type_pointer;
    }

    for (uint8_t i = 0; i < paramsCount; i++) {
        parameterTypesFFITypes[i + initialParamIndex] = &ffi_type_pointer;
    }

    ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, initialParamIndex + paramsCount, &ffi_type_void, const_cast<ffi_type**>(parameterTypesFFITypes));
    assert(status == FFI_OK);

    void* functionPointer;
    ffi_closure* closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &functionPointer));
    status = ffi_prep_closure_loc(closure, cif, callback, userData, functionPointer);
    assert(status == FFI_OK);

    return (IMP)functionPointer;
}

CFTypeRef Interop::CreateBlock(const uint8_t initialParamIndex, const uint8_t paramsCount, FFIMethodCallback callback, void* userData) {
    JSBlock* blockPointer = reinterpret_cast<JSBlock*>(calloc(1, sizeof(JSBlock)));
    void* functionPointer = (void*)CreateMethod(initialParamIndex, paramsCount, callback, userData);

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

}
