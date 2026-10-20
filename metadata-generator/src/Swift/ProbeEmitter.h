#pragma once

#include <map>
#include <string>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"

namespace Swift {

// Swift source that exercises every SwiftGenerated symbol the way a thunk
// will (`let _: Result = try owner.member(label: argument)`). Type-checking it
// against the module proves the IR's labels, types, optionality and effects
// match what the compiler accepts.
struct ProbeSource {
  std::string source;
  // 1-based source line -> symbol id, for mapping compiler diagnostics back
  // to the symbol they reject.
  std::map<int, std::string> lineToSymbol;
};

ProbeSource emitProbes(const Module& module,
                       const Classification& classification);

}  // namespace Swift
