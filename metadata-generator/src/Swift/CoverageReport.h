#pragma once

#include <string>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"

namespace Swift {

// `<Module>.coverage.json`: per-tier and per-kind counts, unsupported reason
// histogram, and the classification of every symbol. `compiledThunks` and
// `runtimeTested` stay null until a later stage measures them.
//
// `compilerRuns` is the number of type-check passes behind `classification`
// (see ProbeVerifier), or -1 when the classification was not compiler
// verified.
std::string coverageJSON(const Module& module,
                         const Classification& classification,
                         int compilerRuns = -1);

}  // namespace Swift
