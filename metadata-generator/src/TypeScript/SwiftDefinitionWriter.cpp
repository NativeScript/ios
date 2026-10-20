#include "SwiftDefinitionWriter.h"

#include <sstream>

namespace TypeScript {

std::string SwiftDefinitionWriter::write() {
  std::ostringstream out;
  out << "// Generated from Swift symbol graphs for module " << _module.name
      << ".\n";
  out << "// Type-only: no Swift members are callable from JavaScript yet.\n\n";

  for (const auto& id : _module.topLevelIds) {
    const Swift::Symbol* symbol = _module.find(id);
    if (!symbol || !Swift::isNominalType(symbol->kind)) {
      continue;
    }
    if (symbol->kind == Swift::SymbolKind::Protocol) {
      out << "interface " << symbol->name << " {}\n";
    } else {
      out << "declare class " << symbol->name << " {}\n";
    }
  }
  return out.str();
}

}  // namespace TypeScript
