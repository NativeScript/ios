#include "SwiftDefinitionWriter.h"

#include "Meta/MetaEntities.h"

namespace TypeScript {
using namespace Meta;

std::string SwiftDefinitionWriter::write() {
    // Header
    _buffer << "// Generated from Swift Symbol Graphs\n";
    _buffer << "// Module: " << _module.first << "\n\n";

    for (auto *m : _module.second) {
        if (m) m->visit(this);
    }

    return _buffer.str();
}

void SwiftDefinitionWriter::visit(InterfaceMeta* meta) {
    _buffer << "declare class " << meta->jsName << " { }\n";
}

void SwiftDefinitionWriter::visit(ProtocolMeta* meta) {
    _buffer << "interface " << meta->jsName << " { }\n";
}

void SwiftDefinitionWriter::visit(CategoryMeta* /*meta*/) {}

void SwiftDefinitionWriter::visit(FunctionMeta* meta) {
    _buffer << "declare function " << meta->jsName << "(...args: any[]): any;\n";
}

void SwiftDefinitionWriter::visit(StructMeta* meta) {
    _buffer << "interface " << meta->jsName << " { }\n";
    _buffer << "declare var " << meta->jsName << ": interop.StructType<" << meta->jsName << ">;\n";
}

void SwiftDefinitionWriter::visit(UnionMeta* meta) {
    _buffer << "interface " << meta->jsName << " { }\n";
}

void SwiftDefinitionWriter::visit(EnumMeta* meta) {
    _buffer << "declare const enum " << meta->jsName << " { }\n";
}

void SwiftDefinitionWriter::visit(VarMeta* meta) {
    _buffer << "declare var " << meta->jsName << ": any;\n";
}

void SwiftDefinitionWriter::visit(MethodMeta* /*meta*/) {}
void SwiftDefinitionWriter::visit(PropertyMeta* /*meta*/) {}
void SwiftDefinitionWriter::visit(EnumConstantMeta* /*meta*/) {}

} // namespace TypeScript
