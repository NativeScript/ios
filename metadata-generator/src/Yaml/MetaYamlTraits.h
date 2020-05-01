#pragma once

#include "Meta/MetaEntities.h"
#include "Meta/Utils.h"

namespace llvm {
namespace yaml {
    bool operator==(Meta::Version& x, const Meta::Version& y)
    {
        return x.Major == y.Major && x.Minor == y.Minor && x.SubMinor == y.SubMinor;
    }

    Meta::MetaFlags operator|(Meta::MetaFlags& value1, Meta::MetaFlags value2)
    {
        return (Meta::MetaFlags)((uint32_t)value1 | (uint32_t)value2);
    }
}
}

#include <llvm/Support/YAMLTraits.h>

LLVM_YAML_IS_SEQUENCE_VECTOR(clang::Module::LinkLibrary)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::RecordField)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::Meta*)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::ProtocolMeta*)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::MethodMeta*)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::PropertyMeta*)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::Type*)
LLVM_YAML_IS_SEQUENCE_VECTOR(Meta::EnumField)

namespace llvm {
namespace yaml {

    // Version
    template <>
    struct ScalarTraits<Meta::Version> {
        static void output(const Meta::Version& value, void* context, raw_ostream& out)
        {
            if (value.Major >= 0) {
                out << value.Major;
                if (value.Minor >= 0) {
                    out << "." << value.Minor;
                    if (value.SubMinor >= 0) {
                        out << "." << value.SubMinor;
                    }
                }
            }
        }

        static StringRef input(StringRef stringValue, void* context, Meta::Version& value)
        {
            value = UNKNOWN_VERSION;
            if (stringValue.size() == 0) {
                return StringRef();
            }
            std::string version = stringValue.str();

            unsigned long firstDotIndex = version.find(".");
            value.Major = (firstDotIndex != std::string::npos) ? std::stoi(version.substr(0, firstDotIndex)) : std::stoi(version);
            if (firstDotIndex != std::string::npos) {
                unsigned long secondDotIndex = version.find(".", firstDotIndex + 1);
                value.Minor = std::stoi(version.substr(firstDotIndex + 1, (secondDotIndex != std::string::npos) ? secondDotIndex - firstDotIndex - 1 : std::string::npos));
                if (secondDotIndex != std::string::npos) {
                    value.SubMinor = std::stoi(version.substr(secondDotIndex + 1, std::string::npos));
                }
            }

            // TODO: We can validate the version and return non-empty string if the yaml format of the version is invalid
            return StringRef();
        }
        // Determine if this scalar needs quotes.
        static QuotingType mustQuote(StringRef)
        {
            return QuotingType::None;
        }
    };

    // MetaFlags
    template <>
    struct ScalarBitSetTraits<Meta::MetaFlags> {

        static void bitset(IO& io, Meta::MetaFlags& value)
        {
            io.bitSetCase(value, "IsIosAppExtensionAvailable", Meta::MetaFlags::IsIosAppExtensionAvailable);
            io.bitSetCase(value, "MemberIsOptional", Meta::MetaFlags::MemberIsOptional);
            //io.bitSetCase(value, "HasName",  Meta::MetaFlags::HasName);

            io.bitSetCase(value, "FunctionIsVariadic", Meta::MetaFlags::FunctionIsVariadic);
            io.bitSetCase(value, "FunctionOwnsReturnedCocoaObject", Meta::MetaFlags::FunctionOwnsReturnedCocoaObject);
            io.bitSetCase(value, "FunctionReturnsUnmanaged", Meta::MetaFlags::FunctionReturnsUnmanaged);

            io.bitSetCase(value, "MethodIsVariadic", Meta::MetaFlags::MethodIsVariadic);
            io.bitSetCase(value, "MethodIsNullTerminatedVariadic", Meta::MetaFlags::MethodIsNullTerminatedVariadic);
            io.bitSetCase(value, "MethodOwnsReturnedCocoaObject", Meta::MetaFlags::MethodOwnsReturnedCocoaObject);
            io.bitSetCase(value, "MethodHasErrorOutParameter", Meta::MetaFlags::MethodHasErrorOutParameter);
            io.bitSetCase(value, "MethodIsInitializer", Meta::MetaFlags::MethodIsInitializer);
        }
    };

    // MetaType
    template <>
    struct ScalarEnumerationTraits<Meta::MetaType> {
        static void enumeration(IO& io, Meta::MetaType& value)
        {
            io.enumCase(value, "Undefined", Meta::MetaType::Undefined);
            io.enumCase(value, "Struct", Meta::MetaType::Struct);
            io.enumCase(value, "Union", Meta::MetaType::Union);
            io.enumCase(value, "Function", Meta::MetaType::Function);
            io.enumCase(value, "Enum", Meta::MetaType::Enum);
            io.enumCase(value, "EnumConstant", Meta::MetaType::EnumConstant);
            io.enumCase(value, "Var", Meta::MetaType::Var);
            io.enumCase(value, "Interface", Meta::MetaType::Interface);
            io.enumCase(value, "Protocol", Meta::MetaType::Protocol);
            io.enumCase(value, "Category", Meta::MetaType::Category);
            io.enumCase(value, "Method", Meta::MetaType::Method);
            io.enumCase(value, "Property", Meta::MetaType::Property);
        }
    };

    // TypeType
    template <>
    struct ScalarEnumerationTraits<Meta::TypeType> {
        static void enumeration(IO& io, Meta::TypeType& value)
        {
            io.enumCase(value, "Void", Meta::TypeType::TypeVoid);
            io.enumCase(value, "Bool", Meta::TypeType::TypeBool);
            io.enumCase(value, "Short", Meta::TypeType::TypeShort);
            io.enumCase(value, "Ushort", Meta::TypeType::TypeUShort);
            io.enumCase(value, "Int", Meta::TypeType::TypeInt);
            io.enumCase(value, "UInt", Meta::TypeType::TypeUInt);
            io.enumCase(value, "Long", Meta::TypeType::TypeLong);
            io.enumCase(value, "ULong", Meta::TypeType::TypeULong);
            io.enumCase(value, "LongLong", Meta::TypeType::TypeLongLong);
            io.enumCase(value, "ULongLong", Meta::TypeType::TypeULongLong);
            io.enumCase(value, "Char", Meta::TypeType::TypeSignedChar);
            io.enumCase(value, "UChar", Meta::TypeType::TypeUnsignedChar);
            io.enumCase(value, "Unichar", Meta::TypeType::TypeUnichar);
            io.enumCase(value, "CString", Meta::TypeType::TypeCString);
            io.enumCase(value, "Float", Meta::TypeType::TypeFloat);
            io.enumCase(value, "Double", Meta::TypeType::TypeDouble);
            io.enumCase(value, "Selector", Meta::TypeType::TypeSelector);
            io.enumCase(value, "Class", Meta::TypeType::TypeClass);
            io.enumCase(value, "Instancetype", Meta::TypeType::TypeInstancetype);
            io.enumCase(value, "Id", Meta::TypeType::TypeId);
            io.enumCase(value, "ConstantArray", Meta::TypeType::TypeConstantArray);
            io.enumCase(value, "IncompleteArray", Meta::TypeType::TypeIncompleteArray);
            io.enumCase(value, "Interface", Meta::TypeType::TypeInterface);
            io.enumCase(value, "BridgedInterface", Meta::TypeType::TypeBridgedInterface);
            io.enumCase(value, "Pointer", Meta::TypeType::TypePointer);
            io.enumCase(value, "FunctionPointer", Meta::TypeType::TypeFunctionPointer);
            io.enumCase(value, "Block", Meta::TypeType::TypeBlock);
            io.enumCase(value, "Struct", Meta::TypeType::TypeStruct);
            io.enumCase(value, "Union", Meta::TypeType::TypeUnion);
            io.enumCase(value, "AnonymousStruct", Meta::TypeType::TypeAnonymousStruct);
            io.enumCase(value, "AnonymousUnion", Meta::TypeType::TypeAnonymousUnion);
            io.enumCase(value, "Enum", Meta::TypeType::TypeEnum);
            io.enumCase(value, "VaList", Meta::TypeType::TypeVaList);
            io.enumCase(value, "Protocol", Meta::TypeType::TypeProtocol);
            io.enumCase(value, "TypeArgument", Meta::TypeType::TypeTypeArgument);
        }
    };

    // clang::Module::LinkLibrary
    template <>
    struct MappingTraits<clang::Module::LinkLibrary> {

        static void mapping(IO& io, clang::Module::LinkLibrary& lib)
        {
            io.mapRequired("Library", lib.Library);
            io.mapRequired("IsFramework", lib.IsFramework);
        }
    };

    // clang::Module *
    template <>
    struct MappingTraits<clang::Module*> {

        static void mapping(IO& io, clang::Module*& module)
        {
            std::string fullModuleName = module->getFullModuleName();
            bool isPartOfFramework = module->isPartOfFramework();
            bool isSystem = module->IsSystem;
            std::vector<clang::Module::LinkLibrary> libs;

            Meta::Utils::getAllLinkLibraries(module, libs);

            io.mapRequired("FullName", fullModuleName);
            io.mapRequired("IsPartOfFramework", isPartOfFramework);
            io.mapRequired("IsSystemModule", isSystem);
            io.mapRequired("Libraries", libs);
        }
    };

    // std::pair<clang::Module *, std::vector<Meta::Meta *>>
    template <>
    struct MappingTraits<std::pair<clang::Module*, std::vector<Meta::Meta*> > > {

        static void mapping(IO& io, std::pair<clang::Module*, std::vector<Meta::Meta*> >& module)
        {
            io.mapRequired("Module", module.first);
            io.mapRequired("Items", module.second);
        }
    };

    // Type *
    template <>
    struct MappingTraits<Meta::Type*> {

        static void mapping(IO& io, Meta::Type*& type)
        {
            Meta::TypeType typeType = type->getType();
            io.mapRequired("Type", typeType);

            switch (typeType) {
            case Meta::TypeType::TypeId: {
                Meta::IdType& concreteType = type->as<Meta::IdType>();
                std::vector<std::string> protocols;
                for (Meta::ProtocolMeta* protocol : concreteType.protocols) {
                    protocols.push_back(protocol->jsName);
                }
                io.mapRequired("WithProtocols", protocols);
                break;
            }
            case Meta::TypeType::TypeConstantArray: {
                Meta::ConstantArrayType& concreteType = type->as<Meta::ConstantArrayType>();
                io.mapRequired("ArrayType", concreteType.innerType);
                io.mapRequired("Size", concreteType.size);
                break;
            }
            case Meta::TypeType::TypeIncompleteArray: {
                Meta::IncompleteArrayType& concreteType = type->as<Meta::IncompleteArrayType>();
                io.mapRequired("ArrayType", concreteType.innerType);
                break;
            }
            case Meta::TypeType::TypeInterface: {
                Meta::InterfaceType& concreteType = type->as<Meta::InterfaceType>();
                io.mapRequired("Name", concreteType.interface->name);
                if (concreteType.typeArguments.size() > 0) {
                    std::vector<Meta::Type*> typeArguments;
                    for (Meta::Type* type : concreteType.typeArguments) {
                        typeArguments.push_back(type);
                    }
                    io.mapRequired("TypeParameters", typeArguments);
                }
                std::vector<std::string> protocols;
                for (Meta::ProtocolMeta* protocol : concreteType.protocols) {
                    protocols.push_back(protocol->jsName);
                }
                io.mapRequired("WithProtocols", protocols);
                break;
            }
            case Meta::TypeType::TypeBridgedInterface: {
                Meta::BridgedInterfaceType& concreteType = type->as<Meta::BridgedInterfaceType>();
                io.mapRequired("Name", concreteType.name);
                std::string bridgedTo = concreteType.isId() ? "id" : (concreteType.bridgedInterface == nullptr ? "[None]" : concreteType.bridgedInterface->jsName);
                io.mapRequired("BridgedTo", bridgedTo);
                break;
            }
            case Meta::TypeType::TypePointer: {
                Meta::PointerType& concreteType = type->as<Meta::PointerType>();
                io.mapRequired("PointerType", concreteType.innerType);
                break;
            }
            case Meta::TypeType::TypeFunctionPointer: {
                Meta::FunctionPointerType& concreteType = type->as<Meta::FunctionPointerType>();
                io.mapRequired("Signature", concreteType.signature);
                break;
            }
            case Meta::TypeType::TypeBlock: {
                Meta::BlockType& concreteType = type->as<Meta::BlockType>();
                io.mapRequired("Signature", concreteType.signature);
                break;
            }
            case Meta::TypeType::TypeStruct: {
                Meta::StructType& concreteType = type->as<Meta::StructType>();
                std::string fullModuleName = concreteType.structMeta->module->getFullModuleName();
                io.mapRequired("Module", fullModuleName);
                io.mapRequired("Name", concreteType.structMeta->name);
                break;
            }
            case Meta::TypeType::TypeUnion: {
                Meta::UnionType& concreteType = type->as<Meta::UnionType>();
                std::string fullModuleName = concreteType.unionMeta->module->getFullModuleName();
                io.mapRequired("Module", fullModuleName);
                io.mapRequired("Name", concreteType.unionMeta->name);
                break;
            }
            case Meta::TypeType::TypeAnonymousStruct: {
                Meta::AnonymousStructType& concreteType = type->as<Meta::AnonymousStructType>();
                io.mapRequired("Fields", concreteType.fields);
                break;
            }
            case Meta::TypeType::TypeAnonymousUnion: {
                Meta::AnonymousUnionType& concreteType = type->as<Meta::AnonymousUnionType>();
                io.mapRequired("Fields", concreteType.fields);
                break;
            }
            case Meta::TypeType::TypeEnum: {
                Meta::EnumType& concreteType = type->as<Meta::EnumType>();
                io.mapRequired("Name", concreteType.enumMeta->jsName);
                break;
            }
            case Meta::TypeType::TypeTypeArgument: {
                Meta::TypeArgumentType& concreteType = type->as<Meta::TypeArgumentType>();
                io.mapRequired("Name", concreteType.name);
                io.mapRequired("UnderlyingType", concreteType.underlyingType);
                std::vector<std::string> protocols;
                for (Meta::ProtocolMeta* protocol : concreteType.protocols) {
                    protocols.push_back(protocol->jsName);
                }
                if (protocols.size() > 0) {
                    io.mapRequired("WithProtocols", protocols);
                }
                break;
            }
            default: {
            }
            }
        }
    };

    static void mapBaseMeta(IO& io, Meta::Meta* meta)
    {
        io.mapRequired("Name", meta->name);
        io.mapRequired("JsName", meta->jsName);
        if (!meta->demangledName.empty()) {
            io.mapRequired("DemangledName", meta->demangledName);
        }
        io.mapRequired("Filename", meta->fileName);
        io.mapRequired("Module", meta->module);
        io.mapOptional("IntroducedIn", meta->introducedIn, UNKNOWN_VERSION);
        io.mapRequired("Flags", meta->flags);
        io.mapRequired("Type", meta->type);
    }

    // MethodMeta *
    template <>
    struct MappingTraits<Meta::MethodMeta*> {

        static void mapping(IO& io, Meta::MethodMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("Signature", meta->signature);
        }
    };

    // PropertyMeta *
    template <>
    struct MappingTraits<Meta::PropertyMeta*> {

        static void mapping(IO& io, Meta::PropertyMeta*& meta)
        {
            mapBaseMeta(io, meta);

            if (meta->getter)
                io.mapRequired("Getter", meta->getter);
            if (meta->setter)
                io.mapRequired("Setter", meta->setter);
        }
    };

    // BaseClassMeta *
    template <>
    struct MappingTraits<Meta::BaseClassMeta*> {

        static void mapping(IO& io, Meta::BaseClassMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("InstanceMethods", meta->instanceMethods);
            io.mapRequired("StaticMethods", meta->staticMethods);
            io.mapRequired("InstanceProperties", meta->instanceProperties);
            io.mapRequired("StaticProperties", meta->staticProperties);
            std::vector<std::string> protocols;
            for (Meta::ProtocolMeta* protocol : meta->protocols) {
                protocols.push_back(protocol->jsName);
            }
            io.mapRequired("Protocols", protocols);
        }
    };

    // FunctionMeta *
    template <>
    struct MappingTraits<Meta::FunctionMeta*> {

        static void mapping(IO& io, Meta::FunctionMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("Signature", meta->signature);
        }
    };

    // RecordField
    template <>
    struct MappingTraits<Meta::RecordField> {

        static void mapping(IO& io, Meta::RecordField& field)
        {
            io.mapRequired("Name", field.name);
            io.mapRequired("Signature", field.encoding);
        }
    };

    // RecordMeta *
    template <>
    struct MappingTraits<Meta::RecordMeta*> {

        static void mapping(IO& io, Meta::RecordMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("Fields", meta->fields);
        }
    };

    // StructMeta *
    template <>
    struct MappingTraits<Meta::StructMeta*> {

        static void mapping(IO& io, Meta::StructMeta*& meta)
        {
            Meta::RecordMeta* recordMeta = &meta->as<Meta::RecordMeta>();
            MappingTraits<Meta::RecordMeta*>::mapping(io, recordMeta);
        }
    };

    // UnionMeta *
    template <>
    struct MappingTraits<Meta::UnionMeta*> {

        static void mapping(IO& io, Meta::UnionMeta*& meta)
        {
            Meta::RecordMeta* recordMeta = &meta->as<Meta::RecordMeta>();
            MappingTraits<Meta::RecordMeta*>::mapping(io, recordMeta);
        }
    };

    // VarMeta *
    template <>
    struct MappingTraits<Meta::VarMeta*> {

        static void mapping(IO& io, Meta::VarMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("Signature", meta->signature);
            if (meta->hasValue) {
                io.mapRequired("Value", meta->value);
            }
        }
    };

    // EnumField
    template <>
    struct MappingTraits<Meta::EnumField> {

        static void mapping(IO& io, Meta::EnumField& field)
        {
            io.mapRequired(field.name.c_str(), field.value);
        }
    };

    // EnumMeta *
    template <>
    struct MappingTraits<Meta::EnumMeta*> {

        static void mapping(IO& io, Meta::EnumMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("FullNameFields", meta->fullNameFields);
            io.mapRequired("SwiftNameFields", meta->swiftNameFields);
        }
    };

    // EnumConstantMeta *
    template <>
    struct MappingTraits<Meta::EnumConstantMeta*> {

        static void mapping(IO& io, Meta::EnumConstantMeta*& meta)
        {
            mapBaseMeta(io, meta);
            io.mapRequired("Value", meta->value);
        }
    };

    // InterfaceMeta *
    template <>
    struct MappingTraits<Meta::InterfaceMeta*> {

        static void mapping(IO& io, Meta::InterfaceMeta*& meta)
        {
            Meta::BaseClassMeta* baseClassMeta = &meta->as<Meta::BaseClassMeta>();
            MappingTraits<Meta::BaseClassMeta*>::mapping(io, baseClassMeta);
            if (meta->base != nullptr) {
                io.mapRequired("Base", meta->base->jsName);
            }
        }
    };

    // ProtocolMeta *
    template <>
    struct MappingTraits<Meta::ProtocolMeta*> {

        static void mapping(IO& io, Meta::ProtocolMeta*& meta)
        {
            Meta::BaseClassMeta* baseClassMeta = &meta->as<Meta::BaseClassMeta>();
            MappingTraits<Meta::BaseClassMeta*>::mapping(io, baseClassMeta);
        }
    };

    // CategoryMeta *
    template <>
    struct MappingTraits<Meta::CategoryMeta*> {

        static void mapping(IO& io, Meta::CategoryMeta*& meta)
        {
            Meta::BaseClassMeta* baseClassMeta = &meta->as<Meta::BaseClassMeta>();
            MappingTraits<Meta::BaseClassMeta*>::mapping(io, baseClassMeta);
            io.mapRequired("ExtendedInterface", meta->extendedInterface);
        }
    };

    // Meta *
    // These traits check which is the actual run-time type of the meta and forward to the corresponding traits.
    template <>
    struct MappingTraits<Meta::Meta*> {

        static void mapping(IO& io, Meta::Meta*& meta)
        {
            switch (meta->type) {
            case Meta::MetaType::Function: {
                Meta::FunctionMeta* functionMeta = &meta->as<Meta::FunctionMeta>();
                MappingTraits<Meta::FunctionMeta*>::mapping(io, functionMeta);
                break;
            }
            case Meta::MetaType::Struct: {
                Meta::StructMeta* structMeta = &meta->as<Meta::StructMeta>();
                MappingTraits<Meta::StructMeta*>::mapping(io, structMeta);
                break;
            }
            case Meta::MetaType::Union: {
                Meta::UnionMeta* unionMeta = &meta->as<Meta::UnionMeta>();
                MappingTraits<Meta::UnionMeta*>::mapping(io, unionMeta);
                break;
            }
            case Meta::MetaType::Var: {
                Meta::VarMeta* varMeta = &meta->as<Meta::VarMeta>();
                MappingTraits<Meta::VarMeta*>::mapping(io, varMeta);
                break;
            }
            case Meta::MetaType::Enum: {
                Meta::EnumMeta* enumMeta = &meta->as<Meta::EnumMeta>();
                MappingTraits<Meta::EnumMeta*>::mapping(io, enumMeta);
                break;
            }
            case Meta::MetaType::EnumConstant: {
                Meta::EnumConstantMeta* enumConstantMeta = &meta->as<Meta::EnumConstantMeta>();
                MappingTraits<Meta::EnumConstantMeta*>::mapping(io, enumConstantMeta);
                break;
            }
            case Meta::MetaType::Interface: {
                Meta::InterfaceMeta* interfaceMeta = &meta->as<Meta::InterfaceMeta>();
                MappingTraits<Meta::InterfaceMeta*>::mapping(io, interfaceMeta);
                break;
            }
            case Meta::MetaType::Protocol: {
                Meta::ProtocolMeta* protocolMeta = &meta->as<Meta::ProtocolMeta>();
                MappingTraits<Meta::ProtocolMeta*>::mapping(io, protocolMeta);
                break;
            }
            case Meta::MetaType::Category: {
                Meta::CategoryMeta* categoryMeta = &meta->as<Meta::CategoryMeta>();
                MappingTraits<Meta::CategoryMeta*>::mapping(io, categoryMeta);
                break;
            }
            case Meta::MetaType::Method: {
                Meta::MethodMeta* methodMeta = &meta->as<Meta::MethodMeta>();
                MappingTraits<Meta::MethodMeta*>::mapping(io, methodMeta);
                break;
            }
            case Meta::MetaType::Property: {
                Meta::PropertyMeta* propertyMeta = &meta->as<Meta::PropertyMeta>();
                MappingTraits<Meta::PropertyMeta*>::mapping(io, propertyMeta);
                break;
            }
            case Meta::MetaType::Undefined:
            default: {
                throw std::runtime_error("Unknown type of meta object.");
            }
            }
        }
    };
}
}
