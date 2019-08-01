#include "binaryTypeEncodingSerializer.h"
#include "../Meta/MetaEntities.h"
#include <llvm/ADT/STLExtras.h>

binary::MetaFileOffset binary::BinaryTypeEncodingSerializer::visit(std::vector< ::Meta::Type*>& types)
{
    vector<unique_ptr<binary::TypeEncoding> > binaryEncodings;
    for (::Meta::Type* type : types) {
        unique_ptr<binary::TypeEncoding> binaryEncoding = type->visit(*this);
        binaryEncodings.push_back(std::move(binaryEncoding));
    }

    binary::MetaFileOffset offset = this->_heapWriter.push_arrayCount(types.size());
    for (unique_ptr<binary::TypeEncoding>& binaryEncoding : binaryEncodings) {
        binaryEncoding->save(this->_heapWriter);
    }
    return offset;
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitVoid()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Void);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitBool()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Bool);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitShort()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Short);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUShort()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::UShort);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitInt()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Int);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUInt()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::UInt);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitLong()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Long);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUlong()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::ULong);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitLongLong()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::LongLong);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitULongLong()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::ULongLong);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitSignedChar()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Char);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUnsignedChar()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::UChar);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUnichar()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Unichar);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitCString()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::CString);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitFloat()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Float);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitDouble()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Double);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitVaList()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::VaList);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitSelector()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Selector);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitInstancetype()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::InstanceType);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitClass(const ::Meta::ClassType& type)
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::Class); // TODO: Add protocols
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitProtocol()
{
    return llvm::make_unique<binary::TypeEncoding>(binary::BinaryTypeEncodingType::ProtocolType);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitId(const ::Meta::IdType& type)
{
    auto s = llvm::make_unique<binary::IdEncoding>();
    std::vector<MetaFileOffset> offsets;
    for (auto protocol : type.protocols) {
        offsets.push_back(this->_heapWriter.push_string(protocol->jsName));
    }
    s->_protocols = this->_heapWriter.push_binaryArray(offsets);

    return unique_ptr<binary::TypeEncoding>(s.release());
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitConstantArray(const ::Meta::ConstantArrayType& type)
{
    binary::ConstantArrayEncoding* s = new binary::ConstantArrayEncoding();
    s->_size = type.size;
    s->_elementType = type.innerType->visit(*this);
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitIncompleteArray(const ::Meta::IncompleteArrayType& type)
{
    binary::IncompleteArrayEncoding* s = new binary::IncompleteArrayEncoding();
    s->_elementType = type.innerType->visit(*this);
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitInterface(const ::Meta::InterfaceType& type)
{
    auto* s = new binary::InterfaceDeclarationReferenceEncoding();
    s->_name = this->_heapWriter.push_string(type.interface->jsName);
    
    std::vector<MetaFileOffset> offsets;
    for (auto protocol : type.protocols) {
        offsets.push_back(this->_heapWriter.push_string(protocol->jsName));
    }
    s->_protocols = this->_heapWriter.push_binaryArray(offsets);
    
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitBridgedInterface(const ::Meta::BridgedInterfaceType& type)
{
    if (type.isId()) {
        return this->visitId(::Meta::IdType());
    }
    if (type.bridgedInterface == nullptr) {
        throw logic_error(std::string("Unresolved bridged interface for BridgedInterfaceType with name '") + type.bridgedInterface->name + "'.");
    }
    auto s = new binary::InterfaceDeclarationReferenceEncoding();
    s->_name = this->_heapWriter.push_string(type.bridgedInterface->jsName);

    std::vector<MetaFileOffset> offsets;
    s->_protocols = this->_heapWriter.push_binaryArray(offsets);
    
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitPointer(const ::Meta::PointerType& type)
{
    binary::PointerEncoding* s = new binary::PointerEncoding();
    s->_target = type.innerType->visit(*this);
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitBlock(const ::Meta::BlockType& type)
{
    binary::BlockEncoding* s = new binary::BlockEncoding();
    s->_encodingsCount = (uint8_t)type.signature.size();
    for (::Meta::Type* signatureType : type.signature) {
        s->_encodings.push_back(signatureType->visit(*this));
    }
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitFunctionPointer(const ::Meta::FunctionPointerType& type)
{
    binary::FunctionEncoding* s = new binary::FunctionEncoding();
    s->_encodingsCount = (uint8_t)type.signature.size();
    for (::Meta::Type* signatureType : type.signature) {
        s->_encodings.push_back(signatureType->visit(*this));
    }
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitStruct(const ::Meta::StructType& type)
{
    binary::DeclarationReferenceEncoding* s = new binary::DeclarationReferenceEncoding(BinaryTypeEncodingType::StructDeclarationReference);
    s->_name = this->_heapWriter.push_string(type.structMeta->jsName);
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitUnion(const ::Meta::UnionType& type)
{
    binary::DeclarationReferenceEncoding* s = new binary::DeclarationReferenceEncoding(BinaryTypeEncodingType::UnionDeclarationReference);
    s->_name = this->_heapWriter.push_string(type.unionMeta->jsName);
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitAnonymousStruct(const ::Meta::AnonymousStructType& type)
{
    return this->serializeRecordEncoding(binary::BinaryTypeEncodingType::AnonymousStruct, type.fields);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitAnonymousUnion(const ::Meta::AnonymousUnionType& type)
{
    return this->serializeRecordEncoding(binary::BinaryTypeEncodingType::AnonymousUnion, type.fields);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitEnum(const ::Meta::EnumType& type)
{
    return type.underlyingType->visit(*this);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitTypeArgument(const ::Meta::TypeArgumentType& type)
{
    return type.underlyingType->visit(*this);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::serializeRecordEncoding(const binary::BinaryTypeEncodingType encodingType, const std::vector< ::Meta::RecordField>& fields)
{
    binary::AnonymousRecordEncoding* s = new binary::AnonymousRecordEncoding(encodingType);
    s->_fieldsCount = (uint8_t)fields.size();

    for (const ::Meta::RecordField& field : fields) {
        s->_fieldNames.push_back(this->_heapWriter.push_string(field.name));
    }

    for (const ::Meta::RecordField& field : fields) {
        s->_fieldEncodings.push_back(field.encoding->visit(*this));
    }
    return unique_ptr<binary::TypeEncoding>(s);
}

unique_ptr<binary::TypeEncoding> binary::BinaryTypeEncodingSerializer::visitExtVector(const ::Meta::ExtVectorType& type)
{
    binary::ExtVectorEncoding* s = new binary::ExtVectorEncoding();
    s->_size = type.size;
    s->_elementType = type.innerType->visit(*this);
    return unique_ptr<binary::TypeEncoding>(s);
}
