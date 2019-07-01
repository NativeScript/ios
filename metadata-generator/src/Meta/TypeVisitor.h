#pragma once

namespace Meta {

class ClassType;
class IdType;
class ConstantArrayType;
class IncompleteArrayType;
class InterfaceType;
class BridgedInterfaceType;
class PointerType;
class BlockType;
class FunctionPointerType;
class StructType;
class UnionType;
class AnonymousStructType;
class AnonymousUnionType;
class EnumType;
class TypeArgumentType;
class ExtVectorType;

/*
     * \class TypeVisitor<T>
     * \brief Applies the Visitor pattern for \c Meta::Type objects.
     *
     * Returns a value of type \c T_RESULT
     */
template <typename T_RESULT>
class TypeVisitor {
public:
    virtual T_RESULT visitVoid() = 0;

    virtual T_RESULT visitBool() = 0;

    virtual T_RESULT visitShort() = 0;

    virtual T_RESULT visitUShort() = 0;

    virtual T_RESULT visitInt() = 0;

    virtual T_RESULT visitUInt() = 0;

    virtual T_RESULT visitLong() = 0;

    virtual T_RESULT visitUlong() = 0;

    virtual T_RESULT visitLongLong() = 0;

    virtual T_RESULT visitULongLong() = 0;

    virtual T_RESULT visitSignedChar() = 0;

    virtual T_RESULT visitUnsignedChar() = 0;

    virtual T_RESULT visitUnichar() = 0;

    virtual T_RESULT visitCString() = 0;

    virtual T_RESULT visitFloat() = 0;

    virtual T_RESULT visitDouble() = 0;

    virtual T_RESULT visitVaList() = 0;

    virtual T_RESULT visitSelector() = 0;

    virtual T_RESULT visitInstancetype() = 0;

    virtual T_RESULT visitClass(const ClassType& typeDetails) = 0;

    virtual T_RESULT visitProtocol() = 0;

    virtual T_RESULT visitId(const IdType& typeDetails) = 0;

    virtual T_RESULT visitConstantArray(const ConstantArrayType& typeDetails) = 0;
    
    virtual T_RESULT visitExtVector(const ExtVectorType& typeDetails) = 0;

    virtual T_RESULT visitIncompleteArray(const IncompleteArrayType& typeDetails) = 0;

    virtual T_RESULT visitInterface(const InterfaceType& typeDetails) = 0;

    virtual T_RESULT visitBridgedInterface(const BridgedInterfaceType& typeDetails) = 0;

    virtual T_RESULT visitPointer(const PointerType& typeDetails) = 0;

    virtual T_RESULT visitBlock(const BlockType& typeDetails) = 0;

    virtual T_RESULT visitFunctionPointer(const FunctionPointerType& typeDetails) = 0;

    virtual T_RESULT visitStruct(const StructType& typeDetails) = 0;

    virtual T_RESULT visitUnion(const UnionType& typeDetails) = 0;

    virtual T_RESULT visitAnonymousStruct(const AnonymousStructType& typeDetails) = 0;

    virtual T_RESULT visitAnonymousUnion(const AnonymousUnionType& typeDetails) = 0;

    virtual T_RESULT visitEnum(const EnumType& typeDetails) = 0;

    virtual T_RESULT visitTypeArgument(const ::Meta::TypeArgumentType& type) = 0;
};
}
