#pragma once

#include "TypeVisitor.h"
#include "Utils/Noncopyable.h"
#include <string>
#include <vector>

namespace Meta {
class ProtocolMeta;
class InterfaceMeta;
class StructMeta;
class UnionMeta;
class EnumMeta;

enum TypeType {
    TypeVoid,
    TypeBool,
    TypeShort,
    TypeUShort,
    TypeInt,
    TypeUInt,
    TypeLong,
    TypeULong,
    TypeLongLong,
    TypeULongLong,
    TypeSignedChar,
    TypeUnsignedChar,
    TypeUnichar,
    TypeCString,
    TypeFloat,
    TypeDouble,
    TypeVaList,
    TypeSelector,
    TypeInstancetype,
    TypeProtocol,
    TypeClass,
    TypeId,
    TypeConstantArray,
    TypeIncompleteArray,
    TypePointer,
    TypeBlock,
    TypeFunctionPointer,
    TypeInterface,
    TypeBridgedInterface,
    TypeStruct,
    TypeUnion,
    TypeAnonymousStruct,
    TypeAnonymousUnion,
    TypeEnum,
    TypeTypeArgument,
    TypeExtVector
};

class Type {
    MAKE_NONCOPYABLE(Type);

public:
    Type(TypeType type)
        : type(type)
    {
    }

    TypeType getType() const
    {
        return type;
    }

    template <class T>
    const T& as() const
    {
        return *static_cast<const T*>(this);
    }

    template <class T>
    T& as()
    {
        return *static_cast<T*>(this);
    }

    bool is(TypeType type) const
    {
        return this->type == type;
    }

    template <class T>
    T visit(TypeVisitor<T>& visitor) const
    {
        switch (this->type) {
        case TypeVoid:
            return visitor.visitVoid();
        case TypeBool:
            return visitor.visitBool();
        case TypeShort:
            return visitor.visitShort();
        case TypeUShort:
            return visitor.visitUShort();
        case TypeInt:
            return visitor.visitInt();
        case TypeUInt:
            return visitor.visitUInt();
        case TypeLong:
            return visitor.visitLong();
        case TypeULong:
            return visitor.visitUlong();
        case TypeLongLong:
            return visitor.visitLongLong();
        case TypeULongLong:
            return visitor.visitULongLong();
        case TypeSignedChar:
            return visitor.visitSignedChar();
        case TypeUnsignedChar:
            return visitor.visitUnsignedChar();
        case TypeUnichar:
            return visitor.visitUnichar();
        case TypeCString:
            return visitor.visitCString();
        case TypeFloat:
            return visitor.visitFloat();
        case TypeDouble:
            return visitor.visitDouble();
        case TypeVaList:
            return visitor.visitVaList();
        case TypeSelector:
            return visitor.visitSelector();
        case TypeInstancetype:
            return visitor.visitInstancetype();
        case TypeProtocol:
            return visitor.visitProtocol();
        case TypeClass:
            return visitor.visitClass(as<ClassType>());
        case TypeId:
            return visitor.visitId(as<IdType>());
        case TypeConstantArray:
            return visitor.visitConstantArray(as<ConstantArrayType>());
        case TypeIncompleteArray:
            return visitor.visitIncompleteArray(as<IncompleteArrayType>());
        case TypePointer:
            return visitor.visitPointer(as<PointerType>());
        case TypeBlock:
            return visitor.visitBlock(as<BlockType>());
        case TypeFunctionPointer:
            return visitor.visitFunctionPointer(as<FunctionPointerType>());
        case TypeInterface:
            return visitor.visitInterface(as<InterfaceType>());
        case TypeBridgedInterface:
            return visitor.visitBridgedInterface(as<BridgedInterfaceType>());
        case TypeStruct:
            return visitor.visitStruct(as<StructType>());
        case TypeUnion:
            return visitor.visitUnion(as<UnionType>());
        case TypeAnonymousStruct:
            return visitor.visitAnonymousStruct(as<AnonymousStructType>());
        case TypeAnonymousUnion:
            return visitor.visitAnonymousUnion(as<AnonymousUnionType>());
        case TypeEnum:
            return visitor.visitEnum(as<EnumType>());
        case TypeTypeArgument:
            return visitor.visitTypeArgument(as<TypeArgumentType>());
        case TypeExtVector:
            return visitor.visitExtVector(as<ExtVectorType>());
                
        }
    }

protected:
    TypeType type;
};

struct RecordField {
    RecordField()
        : RecordField("", nullptr)
    {
    }

    RecordField(std::string name, Type* encoding)
        : name(name)
        , encoding(encoding)
    {
    }

    std::string name;
    Type* encoding;
};

class IdType : public Type {
public:
    IdType(std::vector<ProtocolMeta*> protocols = {})
        : Type(TypeType::TypeId)
        , protocols(protocols)
    {
    }

    std::vector<ProtocolMeta*> protocols;
};

class ClassType : public Type {
public:
    ClassType(std::vector<ProtocolMeta*> protocols = {})
        : Type(TypeType::TypeClass)
        , protocols(protocols)
    {
    }

    std::vector<ProtocolMeta*> protocols;
};

class TypeArgumentType : public Type {
public:
    TypeArgumentType(Type* underlyingType, const std::string& name, std::vector<ProtocolMeta*> protocols = {})
        : Type(TypeType::TypeTypeArgument)
        , underlyingType(underlyingType)
        , name(name)
        , protocols(protocols)
    {
    }

    Type* underlyingType;
    std::string name;
    std::vector<ProtocolMeta*> protocols;
};

class InterfaceType : public Type {
public:
    InterfaceType(InterfaceMeta* interface, std::vector<ProtocolMeta*> protocols, std::vector<Type*> typeArguments)
        : Type(TypeType::TypeInterface)
        , interface(interface)
        , protocols(protocols)
        , typeArguments(typeArguments)
    {
    }

    InterfaceMeta* interface;
    std::vector<ProtocolMeta*> protocols;
    std::vector<Type*> typeArguments;
};

class BridgedInterfaceType : public Type {
public:
    BridgedInterfaceType(std::string name, InterfaceMeta* bridgedInterface)
        : Type(TypeType::TypeBridgedInterface)
        , name(name)
        , bridgedInterface(bridgedInterface)
    {
    }

    bool isId() const
    {
        return name == "id";
    }

    std::string name;
    InterfaceMeta* bridgedInterface;
};

class IncompleteArrayType : public Type {
public:
    IncompleteArrayType(Type* innerType)
        : Type(TypeType::TypeIncompleteArray)
        , innerType(innerType)
    {
    }

    Type* innerType;
};

class ConstantArrayType : public Type {
public:
    ConstantArrayType(Type* innerType, int size)
        : Type(TypeType::TypeConstantArray)
        , innerType(innerType)
        , size(size)
    {
    }

    Type* innerType;
    int size;
};
    
class ExtVectorType : public Type {
public:
    ExtVectorType(Type* innerType, int size)
    : Type(TypeType::TypeExtVector)
    , innerType(innerType)
    , size(size)
    {
    }
    
    Type* innerType;
    int size;
};

class PointerType : public Type {
public:
    PointerType(Type* innerType)
        : Type(TypeType::TypePointer)
        , innerType(innerType)
    {
    }

    Type* innerType;
};

class BlockType : public Type {
public:
    BlockType(std::vector<Type*> signature)
        : Type(TypeType::TypeBlock)
        , signature(signature)
    {
    }

    std::vector<Type*> signature;
};

class FunctionPointerType : public Type {
public:
    FunctionPointerType(std::vector<Type*> signature)
        : Type(TypeType::TypeFunctionPointer)
        , signature(signature)
    {
    }

    std::vector<Type*> signature;
};

class StructType : public Type {
public:
    StructType(StructMeta* structMeta)
        : Type(TypeType::TypeStruct)
        , structMeta(structMeta)
    {
    }

    StructMeta* structMeta;
};

class UnionType : public Type {
public:
    UnionType(UnionMeta* unionMeta)
        : Type(TypeType::TypeUnion)
        , unionMeta(unionMeta)
    {
    }

    UnionMeta* unionMeta;
};

class AnonymousStructType : public Type {
public:
    AnonymousStructType(std::vector<RecordField> fields)
        : Type(TypeType::TypeAnonymousStruct)
        , fields(fields)
    {
    }

    std::vector<RecordField> fields;
};

class AnonymousUnionType : public Type {
public:
    AnonymousUnionType(std::vector<RecordField> fields)
        : Type(TypeType::TypeAnonymousUnion)
        , fields(fields)
    {
    }

    std::vector<RecordField> fields;
};

class EnumType : public Type {
public:
    EnumType(Type* underlyingType, EnumMeta* enumMeta)
        : Type(TypeType::TypeEnum)
        , underlyingType(underlyingType)
        , enumMeta(enumMeta)
    {
    }

    Type* underlyingType;
    EnumMeta* enumMeta;
};
}
