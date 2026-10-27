#pragma once

#include <map>
#include <string>
#include <vector>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"

namespace Swift {

// What a module registers with the runtime: the shared model behind the
// thunks (ThunkEmitter) and the TypeScript declarations
// (SwiftDefinitionWriter), so the two cannot disagree. Kinds, flags and
// signature codes are those of NativeScript/runtime/SwiftInterop.h.
struct SwiftSurface {
  enum TypeKind { kClass = 0, kActor = 1, kStruct = 2, kEnum = 3 };
  enum MemberKind {
    kInitializer = 0,
    kInstanceMethod = 1,
    kStaticMethod = 2,
    kInstanceProperty = 3,
    kStaticProperty = 4,
    kFunction = 5,
    kVariable = 6,
    kEnumCase = 7,
  };
  enum Flags { kThrows = 1 << 0, kSettable = 1 << 1, kAmbiguous = 1 << 2 };

  struct Type {
    const Symbol* symbol;
    int index;
    TypeKind kind;
    // Type index of the registered superclass, or -1.
    int superIndex;
  };

  struct Member {
    const Symbol* symbol;
    const Capability* capability;
    // Type index, or -1 for module-level functions and variables.
    int owner;
    MemberKind kind;
    int flags;
    std::string signature;
    // The value the member produces: the owner for initializers and enum
    // cases, the property type for properties.
    BridgedType result;
  };

  std::vector<Type> types;
  std::vector<Member> members;

  // Type index of `symbolId`, or -1 when the type is not registered.
  int indexOf(const std::string& symbolId) const;

  std::map<std::string, int> typeIndex;
};

SwiftSurface describeSurface(const Module& module,
                             const Classification& classification);

// Signature code of one value ("i64", "o3?", ...).
std::string signatureCode(const SwiftSurface& surface, const BridgedType& type);

// Signed/unsigned integer width of an Integer bridge: {code, Swift type,
// signed}.
struct IntegerWidth {
  const char* code;
  const char* swiftType;
  bool isSigned;
};
const IntegerWidth* integerWidth(const BridgedType& type);

// The type a BridgedType names without its optional wrapper.
const TypeNode& unwrappedNode(const BridgedType& type);

}  // namespace Swift
