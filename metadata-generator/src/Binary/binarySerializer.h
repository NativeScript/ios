#pragma once

#include "Meta/MetaEntities.h"
#include "metaFile.h"
#include "binaryTypeEncodingSerializer.h"
#include <map>

namespace binary {
/*
     * \class BinarySerializer
     * \brief Applies the Visitor pattern for serializing \c Meta::Meta objects in binary format.
     */
class BinarySerializer : public ::Meta::MetaVisitor {
private:
    MetaFile* file;
    BinaryWriter heapWriter;
    BinaryTypeEncodingSerializer typeEncodingSerializer;

    void serializeBase(::Meta::Meta* Meta, binary::Meta& binaryMetaStruct);

    void serializeBaseClass(::Meta::BaseClassMeta* Meta, binary::BaseClassMeta& binaryMetaStruct);

    void serializeMember(::Meta::Meta* meta, binary::MemberMeta& binaryMetaStruct);

    void serializeMethod(::Meta::MethodMeta* Meta, binary::MethodMeta& binaryMetaStruct);

    void serializeProperty(::Meta::PropertyMeta* Meta, binary::PropertyMeta& binaryMetaStruct);

    void serializeRecord(::Meta::RecordMeta* Meta, binary::RecordMeta& binaryMetaStruct);

    void serializeModule(clang::Module* module, binary::ModuleMeta& binaryMetaStruct);

    void serializeLibrary(clang::Module::LinkLibrary* library, binary::LibraryMeta& binaryLib);

public:
    BinarySerializer(MetaFile* file)
        : heapWriter(file->heap_writer())
        , typeEncodingSerializer(heapWriter)
    {
        this->file = file;
    }

    void serializeContainer(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container);

    void start(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container);

    void finish(std::vector<std::pair<clang::Module*, std::vector< ::Meta::Meta*> > >& container);

    virtual void visit(::Meta::InterfaceMeta* Meta) override;

    virtual void visit(::Meta::ProtocolMeta* Meta) override;

    virtual void visit(::Meta::CategoryMeta* Meta) override;

    virtual void visit(::Meta::FunctionMeta* Meta) override;

    virtual void visit(::Meta::StructMeta* Meta) override;

    virtual void visit(::Meta::UnionMeta* Meta) override;

    virtual void visit(::Meta::EnumMeta* Meta) override;

    virtual void visit(::Meta::VarMeta* Meta) override;

    virtual void visit(::Meta::EnumConstantMeta* Meta) override;

    virtual void visit(::Meta::PropertyMeta* Meta) override;

    virtual void visit(::Meta::MethodMeta* Meta) override;
};
}
