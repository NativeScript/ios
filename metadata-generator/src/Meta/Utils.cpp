#include "Utils.h"
#include "TypeEntities.h"

namespace Meta {
bool areRecordFieldListsEqual(const std::vector<RecordField>& vector1, const std::vector<RecordField>& vector2)
{
    if (vector1.size() != vector2.size()) {
        return false;
    }

    for (std::vector<RecordField>::size_type i = 0; i < vector1.size(); i++) {
        if ((vector1[i].name != vector2[i].name) || !Utils::areTypesEqual(*vector1[i].encoding, *vector2[i].encoding)) {
            return false;
        }
    }
    return true;
}

// TODO: This logic should be moved in types (and meta entities) entites
bool Utils::areTypesEqual(const Type& type1, const Type& type2)
{
    if (type1.getType() != type2.getType())
        return false;

    switch (type1.getType()) {
    case TypeType::TypeClass: {
        const ClassType& classType1 = type1.as<ClassType>();
        const ClassType& classType2 = type2.as<ClassType>();
        return classType1.protocols == classType2.protocols;
    }
    case TypeType::TypeId: {
        const IdType& idType1 = type1.as<IdType>();
        const IdType& idType2 = type2.as<IdType>();
        return idType1.protocols == idType2.protocols;
    };
    case TypeType::TypeConstantArray: {
        const ConstantArrayType& arrayType1 = type1.as<ConstantArrayType>();
        const ConstantArrayType& arrayType2 = type2.as<ConstantArrayType>();
        return arrayType1.size == arrayType2.size && areTypesEqual(*arrayType1.innerType, *arrayType2.innerType);
    };
    case TypeType::TypeExtVector: {
        const ExtVectorType& arrayType1 = type1.as<ExtVectorType>();
        const ExtVectorType& arrayType2 = type2.as<ExtVectorType>();
        return arrayType1.size == arrayType2.size && areTypesEqual(*arrayType1.innerType, *arrayType2.innerType);
    };
    case TypeType::TypeIncompleteArray: {
        const IncompleteArrayType& arrayType1 = type1.as<IncompleteArrayType>();
        const IncompleteArrayType& arrayType2 = type2.as<IncompleteArrayType>();
        return areTypesEqual(*arrayType1.innerType, *arrayType2.innerType);
    };
    case TypeType::TypePointer: {
        const PointerType& pointerType1 = type1.as<PointerType>();
        const PointerType& pointerType2 = type2.as<PointerType>();
        return areTypesEqual(*pointerType1.innerType, *pointerType2.innerType);
    };
    case TypeType::TypeBlock: {
        const BlockType& blockType1 = type1.as<BlockType>();
        const BlockType& blockType2 = type2.as<BlockType>();
        return Utils::areTypesEqual(blockType1.signature, blockType2.signature);
    };
    case TypeType::TypeFunctionPointer: {
        const FunctionPointerType& functionType1 = type1.as<FunctionPointerType>();
        const FunctionPointerType& functionType2 = type2.as<FunctionPointerType>();
        return Utils::areTypesEqual(functionType1.signature, functionType2.signature);
    };
    case TypeType::TypeInterface: {
        const InterfaceType& interfaceType1 = type1.as<InterfaceType>();
        const InterfaceType& interfaceType2 = type2.as<InterfaceType>();
        return interfaceType1.interface == interfaceType2.interface && interfaceType1.protocols == interfaceType2.protocols;
    };
    case TypeType::TypeBridgedInterface: {
        const BridgedInterfaceType& interfaceType1 = type1.as<BridgedInterfaceType>();
        const BridgedInterfaceType& interfaceType2 = type2.as<BridgedInterfaceType>();
        return interfaceType1.name == interfaceType2.name;
    };
    case TypeType::TypeStruct: {
        const StructType& structType1 = type1.as<StructType>();
        const StructType& structType2 = type2.as<StructType>();
        return structType1.structMeta == structType2.structMeta;
    };
    case TypeType::TypeUnion: {
        const UnionType& unionType1 = type1.as<UnionType>();
        const UnionType& unionType2 = type2.as<UnionType>();
        return unionType1.unionMeta == unionType2.unionMeta;
    };
    case TypeType::TypeAnonymousStruct: {
        const AnonymousStructType& structType1 = type1.as<AnonymousStructType>();
        const AnonymousStructType& structType2 = type2.as<AnonymousStructType>();
        return areRecordFieldListsEqual(structType1.fields, structType2.fields);
    };
    case TypeType::TypeAnonymousUnion: {
        const AnonymousUnionType& unionType1 = type1.as<AnonymousUnionType>();
        const AnonymousUnionType& unionType2 = type2.as<AnonymousUnionType>();
        return areRecordFieldListsEqual(unionType1.fields, unionType2.fields);
    };
    case TypeType::TypeTypeArgument: {
        const TypeArgumentType& argType1 = type1.as<TypeArgumentType>();
        const TypeArgumentType& argType2 = type2.as<TypeArgumentType>();
        return areTypesEqual(*argType1.underlyingType, *argType2.underlyingType);
    };
    default: {
        return true;
    }
    }
}

bool Utils::areTypesEqual(const std::vector<Type*>& vector1, const std::vector<Type*>& vector2)
{
    if (vector1.size() != vector2.size()) {
        return false;
    }

    for (std::vector<Type*>::size_type i = 0; i < vector1.size(); i++) {
        if (!Utils::areTypesEqual(*vector1[i], *vector2[i])) {
            return false;
        }
    }
    return true;
}

static bool isalpha(const std::vector<std::string>& strings, size_t index)
{
    for (auto& str : strings) {
        if (!std::isalpha(str[index])) {
            return false;
        }
    }
    return true;
}

static std::string createValidPrefix(const std::vector<std::string>& fieldNames, const std::string& prefix)
{
    if (!prefix.empty()) {
        for (const std::string& field : fieldNames) {
            if (std::isdigit(field[prefix.size()])) {
                int newPrefixLength = prefix.size();
                while (newPrefixLength > 0 && !std::isupper(field[newPrefixLength])) {
                    newPrefixLength--;
                }

                std::string newPrefix = prefix.substr(0, newPrefixLength);
                return createValidPrefix(fieldNames, newPrefix);
            }
        }

        bool allMembersStartWithUnderscore = true;
        for (const std::string& field : fieldNames) {
            if (field[prefix.size()] != '_') {
                allMembersStartWithUnderscore = false;
                break;
            }
        }
        if (allMembersStartWithUnderscore) {
            return createValidPrefix(fieldNames, prefix + '_');
        }
    }

    return prefix;
}

std::string Utils::calculateEnumFieldsPrefix(const std::string& enumName, const std::vector<std::string>& fields)
{
    for (size_t prefixLength = 0; prefixLength < enumName.size(); prefixLength++) {
        char c = enumName[prefixLength];
        for (size_t i = 0; i < fields.size(); i++) {
            if (prefixLength >= fields[i].size() || fields[i][prefixLength] != c) {
                while (prefixLength > 0 && (!std::isupper(fields[i][prefixLength]) || !isalpha(fields, prefixLength))) {
                    prefixLength--;
                }
                return createValidPrefix(fields, fields[i].substr(0, prefixLength));
            }
        }
    }

    return createValidPrefix(fields, enumName);
}

void Utils::getAllLinkLibraries(clang::Module* module, std::vector<clang::Module::LinkLibrary>& result)
{
    for (clang::Module::LinkLibrary lib : module->LinkLibraries)
        result.push_back(lib);
    for (clang::Module::submodule_const_iterator it = module->submodule_begin();
         it != module->submodule_end(); ++it)
        getAllLinkLibraries(*it, result);
}
}
