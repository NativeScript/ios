#include "FFICall.h"
#include "ArgConverter.h"
#include "Helpers.h"
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
        case BinaryTypeEncodingType::ExtVectorEncoding: {
            size_t size = typeEncoding->details.extVector.size;
#if defined(__x86_64__)
            // We need isStructMember because double3 vectors are handled
            // differently in x86_64. When a vector is a struct field
            // it is passed in memory but when not - the ST0 register is
            // used for the third element. In armv8 double3 vector will always
            // be passed in memory (as it's size > 16).
            if (size == 3 && isStructMember) {
#else
            // For armv8 we always need to pass the array size
            // as the vector would fill a whole register in order
            // to calculate the proper flags value.
            if (size == 3) {
#endif
                size = 4;
            }

            const TypeEncoding* innerType = typeEncoding->details.extVector.getInnerType();
            ffi_type* innerFFIType = FFICall::GetArgumentType(innerType, isStructMember);
            ffi_type* type = new ffi_type({ .size = size * innerFFIType->size, .alignment = innerFFIType->alignment, .type = FFI_TYPE_EXT_VECTOR });
            type->elements = new ffi_type*[size + 1];

            if (size > 0) {
                std::fill(type->elements, type->elements + size, innerFFIType);
            }

            type->elements[size] = nullptr;
            return type;
        }
        case BinaryTypeEncodingType::StructDeclarationReference: {
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const Meta* meta = ArgConverter::GetMeta(structName);
            tns::Assert(meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);

            StructInfo structInfo = FFICall::GetStructInfo(structMeta, structName);
            return structInfo.FFIType();
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            if (isStructMember) {
                const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
                ffi_type* innerFFIType = FFICall::GetArgumentType(innerType, isStructMember);
                int32_t size = typeEncoding->details.constantArray.size;
                ffi_type* ffiType = new ffi_type({ .size = size * innerFFIType->size, .alignment = innerFFIType->alignment, .type = FFI_TYPE_STRUCT });
                ffiType->elements = new ffi_type*[size + 1];
                if (size > 0) {
                    std::fill(ffiType->elements, ffiType->elements + size, innerFFIType);
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
    tns::Assert(false);
    return nullptr;
}
    
void FFICall::DisposeFFIType(ffi_type* type, const TypeEncoding* typeEncoding) {
    if (type == nullptr) {
        return;
    }
    
    switch (typeEncoding->type) {
        case BinaryTypeEncodingType::ExtVectorEncoding: {
            // dispose innerFFIType
            if(type->elements[0] != nullptr) {
                DisposeFFIType(type->elements[0], typeEncoding->details.extVector.getInnerType());
            }
            delete[] type->elements;
            delete type;
            break;
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            if(type == &ffi_type_pointer) {
                break;
            }
            if(type->elements[0] != nullptr) {
                DisposeFFIType(type->elements[0], typeEncoding->details.constantArray.getInnerType());
            }
            delete[] type->elements;
            delete type;
            break;
        }
        default:
            break;
    }
    
}

StructInfo FFICall::GetStructInfo(const StructMeta* structMeta, std::string structName) {
    size_t fieldsCount = structMeta->fieldsCount();
    const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();
    const String* fieldNames = structMeta->fieldNames().first();
    if (structName.empty()) {
        structName = structMeta->name();
    }
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
    fields.reserve(fieldsCount);
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

    structInfosCache_.emplace(structName, structInfo);

    return structInfo;
}

ParametrizedCall* ParametrizedCall::Get(const TypeEncoding* typeEncoding, const int initialParameterIndex, const int argsCount) {
    auto it = callsCache_.find(typeEncoding);
    if (it != callsCache_.end()) {
        return it->second;
    }

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

    ffi_cif* cif = new ffi_cif();
    ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, argsCount, returnType, const_cast<ffi_type**>(parameterTypesFFITypes));
    tns::Assert(status == FFI_OK);

    ParametrizedCall* call = new ParametrizedCall(cif);
    callsCache_.emplace(typeEncoding, call);

    return call;
}

robin_hood::unordered_map<const TypeEncoding*, ParametrizedCall*> ParametrizedCall::callsCache_;
robin_hood::unordered_map<std::string, StructInfo> FFICall::structInfosCache_;

}
