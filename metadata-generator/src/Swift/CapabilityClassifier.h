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
  // Set<T>: a JS Set copy (an array is accepted as input); `elements` holds
  // T.
  Set,
  // A tuple of two or more values: a JS array copy, or a plain object copy
  // when every element is labeled; `elements` holds the element types and
  // `labels` their labels.
  Tuple,
  // `any Error` as a value: a JS Error named "SwiftError"; any JS value
  // as input, whose message the Swift error describes.
  Error,
  // A C struct Swift imports whose fields are known (cStructBridge):
  // a plain JS object copy of its fields, `{ x, y }`; `elements` holds the
  // fields, `labels` their names, and `objcClass` the struct's name.
  CStruct,
  // Result<Success, Failure>: a plain JS object copy,
  // `{ case: "success", value }` or `{ case: "failure", value }`;
  // `elements` holds Success (Void for none) and Failure.
  Result,
  // A closure parameter (not async): a JS function. `elements` holds the
  // closure's parameters, `results` its result.
  Closure,
  // An Objective-C class instance: NativeScript's ordinary Objective-C
  // wrapper, with the same identity Objective-C calls give it.
  ObjCObject,
  // A generic parameter, in a generic type's declarations for TypeScript
  // only (Classification::templates); never generated.
  TypeParameter,
  // An adoptable module protocol as a value (`any P`): a JS object
  // implementing it (through a generated adapter), or a Swift value that
  // conforms to it.
  Protocol,
  // A result that is an asynchronous sequence (AsyncStream,
  // AsyncThrowingStream, `some AsyncSequence<E, F>`): a JS async iterator;
  // `elements` holds the element type.
  AsyncSequence,
};

struct BridgedType {
  Bridge bridge = Bridge::None;
  bool optional = false;
  // Nominal bridges: the module symbol the type refers to.
  std::string symbolId;
  // ObjCObject: the class's Objective-C runtime name. TypeParameter: the
  // parameter's name.
  std::string objcClass;
  // A generic type's arguments, for its TypeScript name (`Pair<number,
  // string>`).
  std::vector<BridgedType> typeArguments;
  TypeNode node;
  // Array, Dictionary and Set: the element (value) type. Tuple: the element
  // types. Closure: its parameters.
  std::vector<BridgedType> elements;
  // Tuple: the element labels, or empty when none is labeled.
  std::vector<std::string> labels;
  // Closure parameters declared @escaping (valid only in parameter
  // position, so kept out of `node`).
  bool escaping = false;
  // An inout parameter: JS passes a reference object, `{ value }`, whose
  // value is the argument and receives the final value.
  bool isInout = false;
  // Closure: its result (empty for Void), and whether it throws.
  std::vector<BridgedType> results;
  bool throwing = false;
  // AsyncSequence: a Combine publisher, iterated through its `values`.
  bool publisher = false;
};

struct Capability {
  Tier tier = Tier::NotApplicable;
  // Stable machine-readable codes, optionally with a detail after ':'
  // ("unbridged-type:Foundation.URL"). Codes:
  //   objc-visible, not-public, unavailable, obsoleted, unknown-kind,
  //   deinitializer, macro, extension-block, protocol, protocol-requirement,
  //   type-alias, associated-type, generic, noncopyable, protocol-static,
  //   async-sequence-parameter,
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
  // A requirement of an adoptable protocol, which JS implementations provide.
  bool isRequirement = false;
  // An Objective-C-visible class declared in Swift (ObjCDirect): its
  // Swift-only members are generated and installed on NativeScript's class
  // for `objcName`, its Objective-C runtime name.
  bool objcBacked = false;
  std::string objcName;
  // A bridged class or struct conforming to AsyncSequence: its element,
  // which its JS class iterates with `for await` (Symbol.asyncIterator).
  std::optional<BridgedType> asyncElement;

  // Bridges for SwiftGenerated callables: parameters in order, then the
  // result (or the property value type).
  std::vector<BridgedType> parameters;
  BridgedType result;
};

struct Classification {
  std::map<std::string, Capability> bySymbol;
  // Members of generic types with generated instantiations, with generic
  // parameters bridged as TypeParameter: one declaration for TypeScript
  // covering every instantiation.
  std::map<std::string, Capability> templates;

  const Capability* find(const std::string& id) const;
};

// `rejections` maps symbol ids the compiler refused (see ProbeVerifier) to
// the compiler's message; those symbols are classified compiler-rejected.
Classification classify(
    const Module& module,
    const std::map<std::string, std::string>& rejections = {});

// Whether `kind` is something JavaScript can call or read.
bool isCallableKind(SymbolKind kind);

// `name` (a C struct Swift imports, such as CGPoint or
// CLLocationCoordinate2D) as a CStruct bridge, when its fields are known.
std::optional<BridgedType> cStructBridge(const std::string& name);

// The framework that declares the C struct `name`, or null.
const char* frameworkOfCStruct(const std::string& name);

// Whether enum `symbol` has a case with associated values.
bool hasAssociatedValues(const Module& module, const Symbol& symbol);

// The JS keys of an enum case's associated values: the label, or "value"
// for a lone unlabeled value, or the position.
std::vector<std::string> caseKeys(const Symbol& enumCase);

// The availability entries that apply to `module`'s platform.
std::vector<const Availability*> applicableAvailability(const Module& module,
                                                        const Symbol& symbol);

}  // namespace Swift
