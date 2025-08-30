#pragma once

#include "DocSetManager.h"
#include "Meta/MetaEntities.h"
#include <sstream>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace TypeScript {
class SwiftDefinitionWriter : Meta::MetaVisitor {
public:
    SwiftDefinitionWriter(std::pair<std::string, std::vector<Meta::Meta*>> &module,
                          std::string docSetPath)
        : _module(module), _docSet(docSetPath) {}

    std::string write();

    // MetaVisitor
    void visit(Meta::InterfaceMeta* meta) override;
    void visit(Meta::ProtocolMeta* meta) override;
    void visit(Meta::CategoryMeta* meta) override;
    void visit(Meta::FunctionMeta* meta) override;
    void visit(Meta::StructMeta* meta) override;
    void visit(Meta::UnionMeta* meta) override;
    void visit(Meta::EnumMeta* meta) override;
    void visit(Meta::VarMeta* meta) override;
    void visit(Meta::MethodMeta* meta) override;
    void visit(Meta::PropertyMeta* meta) override;
    void visit(Meta::EnumConstantMeta* meta) override;

private:
    std::pair<std::string, std::vector<Meta::Meta*>> &_module; // moduleName, metas
    DocSetManager _docSet;
    std::ostringstream _buffer;
};
}
