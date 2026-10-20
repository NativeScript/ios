#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace Swift {

// One `declarationFragments` entry. `preciseIdentifier` is the USR of the
// referenced declaration for typeIdentifier fragments, empty otherwise.
struct Fragment {
  std::string kind;
  std::string spelling;
  std::string preciseIdentifier;
};

using Fragments = std::vector<Fragment>;

// A type as written in a declaration. Kept unresolved here: `spelling` is the
// source text, `fragments` keep the per-identifier USRs that a type resolver
// needs to map nominal references back to symbols.
struct TypeRef {
  std::string spelling;
  Fragments fragments;

  bool empty() const { return spelling.empty(); }
};

enum class SymbolKind {
  Class,
  Actor,
  Struct,
  Enum,
  Protocol,
  EnumCase,
  Initializer,
  Deinitializer,
  InstanceMethod,
  TypeMethod,
  Operator,
  InstanceProperty,
  TypeProperty,
  InstanceSubscript,
  TypeSubscript,
  Function,
  Variable,
  TypeAlias,
  AssociatedType,
  Macro,
  Extension,
  Unknown,
};

const char* toString(SymbolKind kind);
bool isNominalType(SymbolKind kind);

enum class AccessLevel {
  Private,
  FilePrivate,
  Internal,
  Package,
  Public,
  Open,
  Unknown
};

const char* toString(AccessLevel level);

struct Version {
  int major = 0;
  int minor = 0;
  int patch = 0;
};

struct Availability {
  // "iOS", "macOS", ..., or "*" for platform-agnostic attributes.
  std::string domain;
  std::optional<Version> introduced;
  std::optional<Version> deprecated;
  std::optional<Version> obsoleted;
  std::string message;
  std::string renamed;
  bool isUnconditionallyDeprecated = false;
  bool isUnconditionallyUnavailable = false;
};

struct GenericParameter {
  std::string name;
  int depth = 0;
  int index = 0;
};

struct GenericConstraint {
  // "conformance", "superclass" or "sameType".
  std::string kind;
  std::string lhs;
  std::string rhs;
  std::string rhsPrecise;
};

struct Parameter {
  // Empty when the argument is unlabeled (`_`).
  std::string label;
  std::string internalName;
  TypeRef type;
  // Ownership/passing modifier in front of the type: "inout", "borrowing",
  // "consuming", "sending", or empty.
  std::string modifier;
  // Type attributes such as "@escaping", "@autoclosure", "@Sendable".
  std::vector<std::string> attributes;
  std::string defaultValue;
  bool isVariadic = false;
};

struct SourceLocation {
  std::string uri;
  int line = 0;
  int character = 0;
};

struct SwiftExtensionInfo {
  // Module that declares the extended type (e.g. "Swift" for `extension
  // String`).
  std::string extendedModule;
  std::string typeKind;
  std::vector<GenericConstraint> constraints;
};

struct Relationship {
  std::string kind;
  std::string source;
  std::string target;
  std::string targetFallback;
  std::string sourceOriginId;
  std::string sourceOriginName;
};

struct Symbol {
  // Canonical identifier: the USR, except for the `async` variant Swift
  // imports for an Objective-C completion-handler method, which shares the
  // method's USR and is keyed `<usr>#async`.
  std::string preciseId;
  std::string usr;
  SymbolKind kind = SymbolKind::Unknown;
  std::string kindIdentifier;
  std::vector<std::string> pathComponents;
  // Last path component as Swift spells it, e.g. "scale(by:)" or "x".
  std::string name;
  // `name` without the argument-label suffix, e.g. "scale".
  std::string baseName;
  AccessLevel access = AccessLevel::Unknown;
  Fragments declaration;
  std::string declarationText;

  // Leading declaration attributes ("@MainActor", "nonisolated", ...).
  std::vector<std::string> attributes;
  // Declaration modifiers ("static", "class", "mutating", "override",
  // "convenience", "final", "required", ...).
  std::vector<std::string> modifiers;

  // Callables (functions, methods, initializers, subscripts, enum case
  // payloads).
  std::vector<Parameter> parameters;
  std::optional<TypeRef> returnType;
  bool isAsync = false;
  bool isThrowing = false;
  bool isRethrowing = false;
  TypeRef thrownType;
  // `init?` / `init!`.
  bool isFailable = false;
  bool isImplicitlyUnwrappedFailable = false;

  // Properties, variables and subscripts.
  std::optional<TypeRef> valueType;
  bool isSettable = false;
  bool isLet = false;

  // Type aliases.
  std::optional<TypeRef> aliasedType;

  bool isStatic = false;
  bool isSynthesized = false;
  bool isProtocolRequirement = false;
  bool isOptionalRequirement = false;

  std::vector<GenericParameter> genericParameters;
  std::vector<GenericConstraint> genericConstraints;
  std::optional<SwiftExtensionInfo> extension;
  std::vector<Availability> availability;
  // Doc comment lines joined with '\n'.
  std::string docComment;
  std::optional<SourceLocation> location;
  // Graph file the symbol was read from, relative to the scanned directory.
  std::string sourceGraph;
  // Set when a cross-import overlay (`_SwiftData_SwiftUI`) rather than the
  // module itself declares the symbol; code using it must import the overlay.
  std::string declaringModule;
  // The module whose graphs declare the symbol; differs from Module::name in
  // a generation unit (see mergeUnit).
  std::string module;

  // Resolved relationships.
  std::string parentId;
  std::vector<std::string> memberIds;
  std::vector<std::string> conformances;
  std::string superclassId;
  std::string overriddenId;
  // Requirement or default implementation this member originates from.
  std::string sourceOriginId;
  std::string sourceOriginName;
  std::vector<std::string> defaultImplementationOf;
};

// A type declared outside the module that the module extends
// (e.g. `extension String`). Its members live in Module::symbols.
struct ExternalType {
  std::string preciseId;
  // Qualified name as reported by the graph, e.g. "Swift.String".
  std::string qualifiedName;
  std::string extendedModule;
  std::string typeKind;
  std::vector<std::string> memberIds;
  // Protocols this module makes the type conform to through extensions.
  std::vector<std::string> conformances;
};

struct Platform {
  std::string architecture;
  std::string vendor;
  std::string operatingSystem;
  std::string environment;
  std::optional<Version> minimumVersion;
};

struct Module {
  std::string name;
  // A generation unit: the modules merged into this one, in order. Empty for
  // a single module.
  std::vector<std::string> unitModules;
  Platform platform;
  Version formatVersion;
  std::string generator;
  std::vector<std::string> graphFiles;

  std::map<std::string, Symbol> symbols;
  std::map<std::string, ExternalType> externalTypes;
  // Qualified names of declarations outside the module that relationships
  // point at (conformances, superclasses, extended types), by USR.
  std::map<std::string, std::string> externalNames;
  std::vector<Relationship> relationships;
  // Declarations without a parent inside the module, in source order.
  std::vector<std::string> topLevelIds;

  const Symbol* find(const std::string& preciseId) const;

  // The Swift modules this module covers: unitModules, or just `name`.
  std::vector<std::string> swiftModules() const;
};

enum class Severity { Warning, Error };

struct Diagnostic {
  Severity severity = Severity::Warning;
  // Stable machine-readable code, e.g. "duplicate-symbol".
  std::string code;
  std::string message;
  std::string file;
  std::string symbolId;
};

struct ModuleSet {
  std::map<std::string, Module> modules;
  std::vector<Diagnostic> diagnostics;

  bool hasErrors() const;
};

// Deterministic JSON rendering of a module's IR, used for snapshots and
// `--swift-ir-output`.
std::string dumpModuleJSON(const Module& module);

}  // namespace Swift
