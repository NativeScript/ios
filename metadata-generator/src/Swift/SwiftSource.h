#pragma once

#include <string>
#include <vector>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"
#include "SwiftTypes.h"

namespace Swift {

// Swift spelling of `node` with module-local types qualified by module name,
// so generated code is immune to shadowing by other imports.
std::string swiftTypeText(const TypeNode& node, const Module& module);

// The module that declares `symbol`: its cross-import overlay, if any.
std::string declaringModuleName(const Module& module, const Symbol& symbol);

// `Module.Outer.Inner` for a module-local type.
std::string qualifiedTypeName(const Module& module, const Symbol& symbol);

// `name` escaped for use as a Swift identifier or member name.
std::string swiftIdentifier(const std::string& name);

// How generated Swift code invokes a SwiftGenerated symbol. Shared by the
// compiler-validation probes and the thunks, so a probe that type-checks
// vouches for the thunk's call.
struct Invocation {
  enum class Form {
    Construct,         // Owner(args)
    InstanceMethod,    // receiver.name(args)
    StaticMethod,      // Owner.name(args)
    Function,          // Module.name(args)
    InstanceProperty,  // receiver.name
    StaticProperty,    // Owner.name
    Variable,          // Module.name
    EnumCase,          // Owner.name
  };

  Form form = Form::Function;
  // Qualified owner type, or the module name for top-level declarations.
  std::string owner;
  std::string member;
  std::vector<std::string> labels;
  std::vector<std::string> parameterTypes;
  // Qualified result type ("Void" when there is none).
  std::string resultType;
  bool isThrowing = false;
  // The call is awaited (`async`, or an actor member called from outside).
  bool isAsync = false;
  // Synchronous main-actor isolation: the caller must be on the main actor.
  bool isMainActor = false;
  bool isSettable = false;
  // The receiver must be passed `inout` (mutating members and setters of
  // value types).
  bool receiverIsInout = false;
  bool needsReceiver = false;
  // "iOS 16.0, *" when the symbol or an enclosing type is introduced after
  // the deployment target, empty otherwise.
  std::string availability;
};

Invocation describeInvocation(const Module& module, const Symbol& symbol,
                              const Capability& capability);

// "iOS 16.0, *" when `symbol` or an enclosing type is introduced after the
// deployment target, empty otherwise.
std::string availabilityCondition(const Module& module, const Symbol& symbol);

// The expression that reads/calls the symbol, including `try`/`await`.
std::string invocationExpression(const Invocation& invocation,
                                 const std::string& receiver,
                                 const std::vector<std::string>& arguments);

// The statement that assigns `value` to a settable property or variable.
std::string assignmentStatement(const Invocation& invocation,
                                const std::string& receiver,
                                const std::string& value);

}  // namespace Swift
