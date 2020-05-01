#include "binaryStructures.h"
#include "metaFile.h"

binary::MetaFileOffset binary::Meta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = writer.push_pointer(this->_names);
    writer.push_pointer(this->_topLevelModule);
    writer.push_short(this->_flags);
    writer.push_byte(this->_introduced);
    return offset;
}

binary::MetaFileOffset binary::JsCodeMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    writer.push_pointer(this->_jsCode);
    return offset;
}

binary::MetaFileOffset binary::RecordMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    writer.push_pointer(this->_fieldNames);
    writer.push_pointer(this->_fieldsEncodings);
    return offset;
}

binary::MetaFileOffset binary::FunctionMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    writer.push_pointer(this->_encoding);
    return offset;
}

binary::MetaFileOffset binary::VarMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    writer.push_pointer(this->_encoding);
    return offset;
}

binary::MetaFileOffset binary::MethodMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = MemberMeta::save(writer);
    writer.push_pointer(this->_encoding);
    writer.push_pointer(this->_constructorTokens);
    return offset;
}

binary::MetaFileOffset binary::PropertyMeta::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    if (this->_getter) {
        writer.push_pointer(this->_getter);
    }
    if (this->_setter) {
        writer.push_pointer(this->_setter);
    }
    return offset;
}

binary::MetaFileOffset binary::BaseClassMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = Meta::save(writer);
    writer.push_pointer(this->_instanceMethods);
    writer.push_pointer(this->_staticMethods);
    writer.push_pointer(this->_instanceProperties);
    writer.push_pointer(this->_staticProperties);
    writer.push_pointer(this->_protocols);
    writer.push_short(this->_initializersStartIndex);
    return offset;
}

binary::MetaFileOffset binary::InterfaceMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = BaseClassMeta::save(writer);
    writer.push_pointer(this->_baseName);
    return offset;
}

binary::MetaFileOffset binary::ModuleMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = writer.push_byte(this->_flags);
    writer.push_pointer(this->_name);
    writer.push_pointer(this->_libraries);
    return offset;
}

binary::MetaFileOffset binary::LibraryMeta::save(BinaryWriter& writer)
{
    binary::MetaFileOffset offset = writer.push_byte(this->_flags);
    writer.push_pointer(this->_name);
    return offset;
}

binary::MetaFileOffset binary::TypeEncoding::save(binary::BinaryWriter& writer)
{
    return writer.push_byte(this->_type);
}

binary::MetaFileOffset binary::IdEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_pointer(this->_protocols);
    return offset;
}

binary::MetaFileOffset binary::IncompleteArrayEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    this->_elementType->save(writer);
    return offset;
}

binary::MetaFileOffset binary::ConstantArrayEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_int(this->_size);
    this->_elementType->save(writer);
    return offset;
}

binary::MetaFileOffset binary::ExtVectorEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_int(this->_size);
    this->_elementType->save(writer);
    return offset;
}

binary::MetaFileOffset binary::DeclarationReferenceEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_pointer(this->_name);
    return offset;
}

binary::MetaFileOffset binary::InterfaceDeclarationReferenceEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = DeclarationReferenceEncoding::save(writer);
    writer.push_pointer(this->_protocols);
    return offset;
}

binary::MetaFileOffset binary::PointerEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    this->_target->save(writer);
    return offset;
}

binary::MetaFileOffset binary::BlockEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_byte(this->_encodingsCount);
    for (int i = 0; i < this->_encodingsCount; i++) {
        this->_encodings[i]->save(writer);
    }
    return offset;
}

binary::MetaFileOffset binary::FunctionEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_byte(this->_encodingsCount);
    for (int i = 0; i < this->_encodingsCount; i++) {
        this->_encodings[i]->save(writer);
    }
    return offset;
}

binary::MetaFileOffset binary::AnonymousRecordEncoding::save(binary::BinaryWriter& writer)
{
    binary::MetaFileOffset offset = TypeEncoding::save(writer);
    writer.push_byte(this->_fieldsCount);
    for (int i = 0; i < this->_fieldsCount; i++) {
        writer.push_pointer(this->_fieldNames[i]);
    }
    for (int i = 0; i < this->_fieldsCount; i++) {
        this->_fieldEncodings[i]->save(writer);
    }
    return offset;
}
