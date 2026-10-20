#pragma once

#include <string>

#include "Swift/CapabilityClassifier.h"
#include "Swift/SwiftIR.h"

namespace TypeScript {

// Writes `swift!<Module>.d.ts`: the module's JavaScript surface as `ns:swift`
// exposes it. Only declarations with generated thunks are declared, through
// the same registration model the thunks are emitted from (SwiftSurface), so
// the declarations describe exactly what runs.
class SwiftDefinitionWriter {
 public:
  SwiftDefinitionWriter(const Swift::Module& module,
                        const Swift::Classification& classification)
      : _module(module), _classification(classification) {}

  std::string write();

 private:
  const Swift::Module& _module;
  const Swift::Classification& _classification;
};

}  // namespace TypeScript
