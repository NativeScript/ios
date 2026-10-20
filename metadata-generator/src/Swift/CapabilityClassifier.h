#pragma once

#include <map>
#include <string>
#include <vector>

#include "SwiftIR.h"
#include "SwiftTypes.h"

namespace Swift {

// How a declaration is (or is not) reachable from JavaScript.
enum class Tier {
  // Objective-C-visible (`c:` USR): served by the existing metadata runtime.
  ObjCDirect,
  // Callable through a generated Swift thunk.
  SwiftGenerated,
  // Needs an explicit generic specialization or adapter before it can be
  // generated.
  SwiftSpecialized,
  // Representable in TypeScript but not callable (protocols, type aliases,
  // protocol requirements).
  TypeOnly,
  Unsupported,
  // Not an API surface (deinitializers, macros, extension blocks).
  NotApplicable,
};

const char* toString(Tier tier);

// How a Swift type crosses into JavaScript. Only types with a bridge other
// than None can appear in generated signatures.
enum class Bridge {
  None,
  Void,
  Bool,
  // Integers: JS numbers; values outside +/-(2^53 - 1) throw RangeError
  // instead of losing precision.
  Integer,
  Floating,
  String,
  // Module class or actor: an owned handle with stable JS identity.
  ClassHandle,
  // Module struct: a boxed copy; the JS object never aliases another copy.
  StructBox,
  // Module enum without payloads: its case name as a JS string.
  EnumCase,
  // Module enum with associated values: a plain JS object copy naming its
  // case, `{ case: "area", width: 3, height: 4 }` (see caseKeys).
  TaggedEnum,
  // Foundation.Date: a JS Date.
  Date,
  // Foundation.URL: a JS URL (a string is accepted as input).
  URL,
  // Foundation.Data: a Uint8Array copy (any ArrayBuffer or view as input).
  Data,
  // [T]: a JS array copy; `elements` holds T.
  Array,
  // [String: T]: a plain JS object copy; `elements` holds T.
  Dictionary,
  // A closure parameter returning Void: a JS function. `elements` holds the
  // closure's parameters.
  Closure,
};

struct BridgedType {
  Bridge bridge = Bridge::None;
  bool optional = false;
  // Nominal bridges: the module symbol the type refers to.
  std::string symbolId;
  TypeNode node;
  // Array and Dictionary: the element (value) type. Closure: its
  // parameters.
  std::vector<BridgedType> elements;
  // Closure parameters declared @escaping (valid only in parameter
  // position, so kept out of `node`).
  bool escaping = false;
};

struct Capability {
  Tier tier = Tier::NotApplicable;
  // Stable machine-readable codes, optionally with a detail after ':'
  // ("unbridged-type:Foundation.URL"). Codes:
  //   objc-visible, not-public, unavailable, obsoleted, unknown-kind,
  //   deinitializer, macro, extension-block, protocol, protocol-requirement,
  //   type-alias, associated-type, generic, noncopyable,
  //   nonescapable, async-initializer, operator, subscript,
  //   enum-associated-values,
  //   external-type-extension, owner-not-bridged, missing-owner,
  //   js-name-conflict,
  //   inout-parameter, variadic-parameter, closure, tuple, collection,
  //   existential, opaque-type, metatype, unbridged-type, unparsed-type,
  //   nested-optional, optional-element, dictionary-key, compiler-rejected
  std::vector<std::string> reasons;
  // Property name, method name, or "constructor" for initializers.
  std::string jsName;
  // Another generated overload with the same JS name accepts the same JS
  // argument kinds, so JS-side dispatch must use the signature key.
  bool ambiguousOverload = false;
  // The call completes asynchronously (an `async` declaration, or an actor
  // member called from outside the actor): JS receives a Promise.
  bool isAsync = false;
  // Isolated to the main actor; synchronous calls must come from the main
  // thread.
  bool isMainActor = false;
  // A property or variable JS can assign.
  bool isSettable = false;

  // Bridges for SwiftGenerated callables: parameters in order, then the
  // result (or the property value type).
  std::vector<BridgedType> parameters;
  BridgedType result;
};

struct Classification {
  std::map<std::string, Capability> bySymbol;

  const Capability* find(const std::string& id) const;
};

// `rejections` maps symbol ids the compiler refused (see ProbeVerifier) to
// the compiler's message; those symbols are classified compiler-rejected.
Classification classify(
    const Module& module,
    const std::map<std::string, std::string>& rejections = {});

// Whether `kind` is something JavaScript can call or read.
bool isCallableKind(SymbolKind kind);

// Whether enum `symbol` has a case with associated values.
bool hasAssociatedValues(const Module& module, const Symbol& symbol);

// The JS keys of an enum case's associated values: the label, or "value"
// for a lone unlabeled value, or the position.
std::vector<std::string> caseKeys(const Symbol& enumCase);

// The availability entries that apply to `module`'s platform.
std::vector<const Availability*> applicableAvailability(const Module& module,
                                                        const Symbol& symbol);

}  // namespace Swift
