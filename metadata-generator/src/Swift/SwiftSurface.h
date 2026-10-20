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
  enum TypeKind {
    kClass = 0,
    kActor = 1,
    kStruct = 2,
    kEnum = 3,
    kTaggedEnum = 4,
    kProtocol = 5,
  };
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
  enum Flags {
    kThrows = 1 << 0,
    kSettable = 1 << 1,
    kAmbiguous = 1 << 2,
    kAsync = 1 << 3,
    kMainActor = 1 << 4,
    // A protocol requirement; its position among the protocol's
    // requirements is the index adapters call it by.
    kRequirement = 1 << 5,
  };

  struct Type {
    const Symbol* symbol;
    int index;
    TypeKind kind;
    // Type index of the registered superclass (for a protocol, the protocol
    // it refines), or -1.
    int superIndex;
    // The Swift module whose JS namespace exposes the type.
    std::string module;
  };

  struct Member {
    const Symbol* symbol;
    const Capability* capability;
    // Type index, or -1 for module-level functions and variables.
    int owner;
    // The owner's module, or the declaring module of a module-level member.
    std::string module;
    MemberKind kind;
    int flags;
    std::string signature;
    // The value the member produces: the owner for initializers and enum
    // cases, the property type for properties.
    BridgedType result;
  };

  // A tagged enum's cases in registration order, which is the case index
  // the runtime and the thunks share.
  std::vector<const Member*> casesOf(int typeIndex) const;
  // A protocol's requirements, those of the protocol it refines first, then
  // its own in registration order: the index adapters call them by.
  std::vector<const Member*> requirementsOf(int typeIndex) const;

  std::vector<Type> types;
  std::vector<Member> members;

  // Type index of `symbolId`, or -1 when the type is not registered.
  int indexOf(const std::string& symbolId) const;

  std::map<std::string, int> typeIndex;
};

SwiftSurface describeSurface(const Module& module,
                             const Classification& classification);

// Signature code of one value ("i64", "o3?", "t2", "[s]", "{f64}",
// "(i64,s)", "&i64"...).
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
