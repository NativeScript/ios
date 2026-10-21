#pragma once

#include <string>

#include "Swift/CapabilityClassifier.h"
#include "Swift/SwiftIR.h"

namespace TypeScript {

// Writes `swift!<Module>.d.ts`: the module's JavaScript surface as `ns:swift`
// exposes it. For a generation unit, `moduleName` picks one of its modules;
// types of the unit's other modules are referenced through their own
// `ns:swift/<Module>` declarations. Only declarations with generated thunks are
// declared, through the same registration model the thunks are emitted from
// (SwiftSurface), so the declarations describe exactly what runs.
class SwiftDefinitionWriter {
 public:
  SwiftDefinitionWriter(const Swift::Module& module,
                        const Swift::Classification& classification,
                        std::string moduleName = "")
      : _module(module),
        _classification(classification),
        _moduleName(moduleName.empty() ? module.name : std::move(moduleName)) {}

  std::string write();

 private:
  const Swift::Module& _module;
  const Swift::Classification& _classification;
  std::string _moduleName;
};

}  // namespace TypeScript
