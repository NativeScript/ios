#include "FFICall.h"

namespace tns {

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
        case BinaryTypeEncodingType::ClassEncoding:
        case BinaryTypeEncodingType::PointerEncoding:
        case BinaryTypeEncodingType::ProtocolEncoding:
        case BinaryTypeEncodingType::FunctionPointerEncoding:
        case BinaryTypeEncodingType::IncompleteArrayEncoding: {
            return &ffi_type_pointer;
        }
        case BinaryTypeEncodingType::UnicharEncoding: {
            return &ffi_type_ushort;
        }
        case BinaryTypeEncodingType::BoolEncoding:
        case BinaryTypeEncodingType::UCharEncoding:
        case BinaryTypeEncodingType::CharEncoding: {
            return &ffi_type_sint8;
        }
        case BinaryTypeEncodingType::UShortEncoding: {
            return &ffi_type_uint16;
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            return &ffi_type_sint16;
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            return &ffi_type_uint32;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            return &ffi_type_sint32;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
#if defined(__LP64__)
            return &ffi_type_uint64;
#else
            return &ffi_type_uint32;
#endif
        }
        case BinaryTypeEncodingType::LongEncoding: {
#if defined(__LP64__)
            return &ffi_type_sint64;
#else
            return &ffi_type_sint32;
#endif
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            return &ffi_type_uint64;
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            return &ffi_type_sint64;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            return &ffi_type_float;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            return &ffi_type_double;
        }
        case BinaryTypeEncodingType::StructDeclarationReference: {
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const GlobalTable* globalTable = MetaFile::instance()->globalTable();
            // TODO: cache metadata
            const Meta* meta = globalTable->findMeta(structName);
            assert(meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);

            std::vector<StructField> fields;
            return FFICall::GetStructFFIType(structMeta, fields);
        }
        default: {
            break;
        }
    }

    // TODO: implement all the possible encoding types
    assert(false);
}

ffi_type* FFICall::GetStructFFIType(const StructMeta* structMeta, std::vector<StructField>& fields) {
    ffi_type* ffiType = new ffi_type({ .size = 0, .alignment = 0, .type = FFI_TYPE_STRUCT });

    size_t count = structMeta->fieldsCount();
    ffiType->elements = new ffi_type*[count + 1];
    const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

    for (int i = 0; i < count; i++) {
        ffi_type* fieldFFIType = FFICall::GetArgumentType(fieldEncoding);
        ffiType->elements[i] = fieldFFIType;

        size_t offset = ffiType->size;
        unsigned short alignment = fieldFFIType->alignment;

        size_t padding = (alignment - (offset % alignment)) % alignment;

        std::string fieldName = structMeta->fieldNames()[i].valuePtr();
        offset += padding;
        StructField field(offset, fieldFFIType, fieldName, fieldEncoding);

        fields.push_back(field);

        ffiType->size = offset + fieldFFIType->size;
        ffiType->alignment = std::max(ffiType->alignment, fieldFFIType->alignment);

        fieldEncoding = fieldEncoding->next();
    }

    ffiType->elements[count] = nullptr;

    return ffiType;
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
