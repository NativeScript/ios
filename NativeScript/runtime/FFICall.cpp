#include "FFICall.h"
#include "ArgConverter.h"
#include <sstream>

namespace tns {

ffi_type* FFICall::GetArgumentType(const TypeEncoding* typeEncoding, bool isStructMember) {
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
            const Meta* meta = ArgConverter::GetMeta(structName);
            assert(meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);

            StructInfo structInfo = FFICall::GetStructInfo(structMeta);
            return structInfo.FFIType();
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            if (isStructMember) {
                const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
                ffi_type* innerFFIType = FFICall::GetArgumentType(innerType);
                int32_t size = typeEncoding->details.constantArray.size;
                ffi_type* ffiType = new ffi_type({ .size = size * innerFFIType->size, .alignment = innerFFIType->alignment, .type = FFI_TYPE_STRUCT });
                ffiType->elements = new ffi_type*[size + 1];
                for (int32_t i = 0; i < size; i++) {
                    ffiType->elements[i] = innerFFIType;
                }
                ffiType->elements[size] = nullptr;
                return ffiType;
            }

            return &ffi_type_pointer;
        }
        case BinaryTypeEncodingType::AnonymousStructEncoding: {
            size_t count = typeEncoding->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
            StructInfo structInfo = FFICall::GetStructInfo(count, fieldEncoding, fieldNames);
            return structInfo.FFIType();
        }
        default: {
            break;
        }
    }

    // TODO: implement all the possible encoding types
    assert(false);
}

StructInfo FFICall::GetStructInfo(const StructMeta* structMeta) {
    size_t fieldsCount = structMeta->fieldsCount();
    const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();
    const String* fieldNames = structMeta->fieldNames().first();
    std::string structName = structMeta->name();
    StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames, structName);
    return structInfo;
}

StructInfo FFICall::GetStructInfo(size_t fieldsCount, const TypeEncoding* fieldEncoding, const String* fieldNames, std::string structName) {
    if (structName.empty()) {
        const TypeEncoding* temp = fieldEncoding;
        std::stringstream ss;
        for (int i = 0; i < fieldsCount; i++) {
            std::string fieldName = fieldNames[i].valuePtr();
            ss << fieldName << "_" << temp->type;
            temp = temp->next();
        }
        structName = ss.str();
    }

    auto it = structInfosCache_.find(structName);
    if (it != structInfosCache_.end()) {
        return it->second;
    }

    std::vector<StructField> fields;
    ffi_type* ffiType = new ffi_type({ .size = 0, .alignment = 0, .type = FFI_TYPE_STRUCT });

    ffiType->elements = new ffi_type*[fieldsCount + 1];

#if defined(__x86_64__)
    bool hasNestedStruct = false;
#endif

    for (int i = 0; i < fieldsCount; i++) {
        ffi_type* fieldFFIType = FFICall::GetArgumentType(fieldEncoding, true);
#if defined(__x86_64__)
        hasNestedStruct = hasNestedStruct || (fieldFFIType->type == FFI_TYPE_STRUCT);
#endif
        ffiType->elements[i] = fieldFFIType;

        size_t offset = ffiType->size;
        unsigned short alignment = fieldFFIType->alignment;

        size_t padding = (alignment - (offset % alignment)) % alignment;

        std::string fieldName = fieldNames[i].valuePtr();
        offset += padding;
        StructField field(offset, fieldFFIType, fieldName, fieldEncoding);

        fields.push_back(field);

        ffiType->size = offset + fieldFFIType->size;
        ffiType->alignment = std::max(ffiType->alignment, fieldFFIType->alignment);

        fieldEncoding = fieldEncoding->next();
    }

    ffiType->elements[fieldsCount] = nullptr;

#if defined(__x86_64__)
    /*
     If on 64-bit architecture, flatten the nested structures, because libffi can't handle them.
     */
    if (hasNestedStruct) {
        std::vector<ffi_type*> flattenedFfiTypes;
        std::vector<ffi_type*> stack; // simulate recursion with stack (no need of other function)
        stack.push_back(ffiType);
        while (!stack.empty()) {
            ffi_type* currentType = stack.back();
            stack.pop_back();
            if (currentType->type != FFI_TYPE_STRUCT) {
                flattenedFfiTypes.push_back(currentType);
            } else {
                ffi_type** nullPtr = currentType->elements; // the end of elements array
                while (*nullPtr != nullptr) {
                    nullPtr++;
                }

                // add fields' ffi types in reverse order in the stack, so they will be popped in correct order
                for (ffi_type** field = nullPtr - 1; field >= currentType->elements; field--) {
                    stack.push_back(*field);
                }
            }
        }

        delete[] ffiType->elements;
        ffiType->elements = new ffi_type*[flattenedFfiTypes.size() + 1];
        memcpy(ffiType->elements, flattenedFfiTypes.data(), flattenedFfiTypes.size() * sizeof(ffi_type*));
        ffiType->elements[flattenedFfiTypes.size()] = nullptr;
    }
#endif

    StructInfo structInfo(structName, ffiType, fields);

    structInfosCache_.insert(std::make_pair(structName, structInfo));

    return structInfo;
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

std::unordered_map<const TypeEncoding*, ffi_cif*> FFICall::cifCache_;
std::unordered_map<std::string, StructInfo> FFICall::structInfosCache_;

}
