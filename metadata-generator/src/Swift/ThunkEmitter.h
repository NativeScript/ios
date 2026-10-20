#pragma once

#include <string>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"

namespace Swift {

// ABI version the emitted thunks implement; must match NS_SWIFT_ABI_VERSION
// in NativeScript/runtime/SwiftInterop.h, which documents the contract.
constexpr int kThunkABIVersion = 4;

struct ThunkSource {
  std::string source;
  // Exported C symbol the runtime calls to register the module.
  std::string registerSymbol;
  // Changes whenever the registered surface changes.
  std::string fingerprint;
  int thunkCount = 0;
};

// Swift source registering every SwiftGenerated type and member of `module`
// with the NativeScript runtime, one thunk per callable. Compile it in a
// module that can import `module`.
ThunkSource emitThunks(const Module& module,
                       const Classification& classification);

}  // namespace Swift
