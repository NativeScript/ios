#include "FFICall.h"

namespace tns {

FFICall::FFICall(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount) {
    this->stackSize_ = 0;

    this->argsArrayOffset_ = this->stackSize_;
    this->stackSize_ += malloc_good_size(sizeof(void* [argsCount]));

    this->returnOffset_ = this->stackSize_;

    ffi_type* returnType = FFICall::GetArgumentType(typeEncoding);
    this->stackSize_ += malloc_good_size(std::max(sizeof(*returnType), sizeof(ffi_arg)));

    for (size_t i = 0; i < initialParameterIndex; i++) {
        this->argValueOffsets_.push_back(this->stackSize_);
        this->stackSize_ += malloc_good_size(std::max(sizeof(ffi_type_pointer), sizeof(ffi_arg)));
    }

    const TypeEncoding* enc = typeEncoding;
    for (size_t i = initialParameterIndex; i < argsCount; i++) {
        this->argValueOffsets_.push_back(this->stackSize_);
        enc = enc->next();
        ffi_type* argType = FFICall::GetArgumentType(enc);
        this->stackSize_ += malloc_good_size(std::max(sizeof(*argType), sizeof(ffi_arg)));
    }

    this->buffer_ = reinterpret_cast<uint8_t*>(malloc(this->stackSize_));

    this->argsArray_ = reinterpret_cast<void**>(this->buffer_ + this->argsArrayOffset_);
    for (size_t i = 0; i < argsCount; i++) {
        this->argsArray_[i] = this->buffer_ + this->argValueOffsets_[i];
    }
}

ffi_type* FFICall::GetArgumentType(const TypeEncoding* typeEncoding) {
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

ffi_cif* FFICall::GetCif(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount) {
    ffi_cif* cif = nullptr;
    auto it = cifCache_.find(typeEncoding);
    if (it != cifCache_.end()) {
        cif = it->second;
    } else {
        const ffi_type** parameterTypesFFITypes = new const ffi_type*[argsCount]();
        ffi_type* returnType = FFICall::GetArgumentType(typeEncoding);

        for (int i = 0; i < initialParameterIndex; i++) {
            parameterTypesFFITypes[i] = &ffi_type_pointer;
        }

        const TypeEncoding* enc = typeEncoding;
        for (int i = initialParameterIndex; i < argsCount; i++) {
            enc = enc->next();
            parameterTypesFFITypes[i] = FFICall::GetArgumentType(enc);
        }

        cif = new ffi_cif();
        ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
        assert(status == FFI_OK);

        cifCache_.insert(std::make_pair(typeEncoding, cif));
    }

    return cif;
}

std::map<const TypeEncoding*, ffi_cif*> FFICall::cifCache_;

}
