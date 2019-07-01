#pragma once

#include "Meta/TypeEntities.h"
#include "binaryStructures.h"
#include "binaryWriter.h"
#include <vector>

using namespace std;

namespace binary {
/*
     * \class BinaryTypeEncodingSerializer
     * \brief Applies the Visitor pattern for serializing \c typeEncoding::TypeEncoding objects in binary format.
     */
class BinaryTypeEncodingSerializer : public ::Meta::TypeVisitor<unique_ptr<binary::TypeEncoding> > {
private:
    BinaryWriter _heapWriter;

    unique_ptr<TypeEncoding> serializeRecordEncoding(const binary::BinaryTypeEncodingType encodingType, const std::vector< ::Meta::RecordField>& fields);

public:
    BinaryTypeEncodingSerializer(BinaryWriter& heapWriter)
        : _heapWriter(heapWriter)
    {
    }

    MetaFileOffset visit(std::vector< ::Meta::Type*>& types);

    virtual unique_ptr<TypeEncoding> visitVoid() override;

    virtual unique_ptr<TypeEncoding> visitBool() override;

    virtual unique_ptr<TypeEncoding> visitShort() override;

    virtual unique_ptr<TypeEncoding> visitUShort() override;

    virtual unique_ptr<TypeEncoding> visitInt() override;

    virtual unique_ptr<TypeEncoding> visitUInt() override;

    virtual unique_ptr<TypeEncoding> visitLong() override;

    virtual unique_ptr<TypeEncoding> visitUlong() override;

    virtual unique_ptr<TypeEncoding> visitLongLong() override;

    virtual unique_ptr<TypeEncoding> visitULongLong() override;

    virtual unique_ptr<TypeEncoding> visitSignedChar() override;

    virtual unique_ptr<TypeEncoding> visitUnsignedChar() override;

    virtual unique_ptr<TypeEncoding> visitUnichar() override;

    virtual unique_ptr<TypeEncoding> visitCString() override;

    virtual unique_ptr<TypeEncoding> visitFloat() override;

    virtual unique_ptr<TypeEncoding> visitDouble() override;

    virtual unique_ptr<TypeEncoding> visitVaList() override;

    virtual unique_ptr<TypeEncoding> visitSelector() override;

    virtual unique_ptr<TypeEncoding> visitInstancetype() override;

    virtual unique_ptr<TypeEncoding> visitProtocol() override;

    virtual unique_ptr<TypeEncoding> visitClass(const ::Meta::ClassType& type) override;

    virtual unique_ptr<TypeEncoding> visitId(const ::Meta::IdType& type) override;

    virtual unique_ptr<TypeEncoding> visitConstantArray(const ::Meta::ConstantArrayType& type) override;
    
    virtual unique_ptr<TypeEncoding> visitExtVector(const ::Meta::ExtVectorType& type) override;

    virtual unique_ptr<TypeEncoding> visitIncompleteArray(const ::Meta::IncompleteArrayType& type) override;

    virtual unique_ptr<TypeEncoding> visitInterface(const ::Meta::InterfaceType& type) override;

    virtual unique_ptr<TypeEncoding> visitBridgedInterface(const ::Meta::BridgedInterfaceType& type) override;

    virtual unique_ptr<TypeEncoding> visitPointer(const ::Meta::PointerType& type) override;

    virtual unique_ptr<TypeEncoding> visitBlock(const ::Meta::BlockType& type) override;

    virtual unique_ptr<TypeEncoding> visitFunctionPointer(const ::Meta::FunctionPointerType& type) override;

    virtual unique_ptr<TypeEncoding> visitStruct(const ::Meta::StructType& type) override;

    virtual unique_ptr<TypeEncoding> visitUnion(const ::Meta::UnionType& type) override;

    virtual unique_ptr<TypeEncoding> visitAnonymousStruct(const ::Meta::AnonymousStructType& type) override;

    virtual unique_ptr<TypeEncoding> visitAnonymousUnion(const ::Meta::AnonymousUnionType& type) override;

    virtual unique_ptr<TypeEncoding> visitEnum(const ::Meta::EnumType& type) override;

    virtual unique_ptr<TypeEncoding> visitTypeArgument(const ::Meta::TypeArgumentType& type) override;
};
}
