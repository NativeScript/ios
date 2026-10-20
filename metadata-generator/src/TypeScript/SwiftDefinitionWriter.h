#pragma once

#include <string>

#include "Swift/SwiftIR.h"

namespace TypeScript {

// Writes `swift!<Module>.d.ts`. Declarations are type-only: they name the
// module's Swift types, but no Swift member is callable from JavaScript, so
// none is declared.
class SwiftDefinitionWriter {
 public:
  explicit SwiftDefinitionWriter(const Swift::Module& module)
      : _module(module) {}

  std::string write();

 private:
  const Swift::Module& _module;
};

}  // namespace TypeScript
