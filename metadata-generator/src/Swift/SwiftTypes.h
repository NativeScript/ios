#pragma once

#include <set>
#include <string>
#include <vector>

#include "SwiftIR.h"

namespace Swift {

// A Swift type as a tree, parsed from a TypeRef's fragments.
struct TypeNode {
  enum class Kind {
    // A named type, possibly nested (`AttributedString.Index`) and generic
    // (`Binding<Bool>`). Optional, Array and Dictionary spelled as named
    // generics are normalized to their own kinds.
    Nominal,
    // A generic parameter in scope, `Self`, or a member of one (`T.Value`).
    GenericParameter,
    Optional,
    ImplicitlyUnwrappedOptional,
    Array,
    Dictionary,
    Tuple,
    Function,
    Metatype,
    // `any P` (also `Any`, `AnyObject`).
    Existential,
    // `some P`.
    Opaque,
    // `P & Q`.
    Composition,
    Void,
    // Anything the parser does not model (parameter packs, `~Copyable`);
    // `text` holds the spelling.
    Unknown,
  };

  struct Component {
    std::string name;
    std::string usr;
    std::vector<TypeNode> arguments;
  };

  Kind kind = Kind::Unknown;
  // Nominal: one entry per dot-separated name; GenericParameter: its name(s).
  std::vector<Component> components;
  // Element/wrapped types, tuple elements, function parameters, composition
  // members, dictionary key and value.
  std::vector<TypeNode> children;
  std::vector<std::string> labels;
  // Function result; empty for other kinds.
  std::vector<TypeNode> result;
  std::vector<TypeNode> thrownType;
  bool isAsync = false;
  bool isThrowing = false;
  // "@escaping", "@Sendable", "@MainActor", "@convention(c)", ...
  std::vector<std::string> attributes;
  // "inout", "borrowing", "consuming", "sending", "repeat each".
  std::string modifier;
  std::string text;

  // USR of the last component (Nominal only).
  const std::string& usr() const;
  bool hasAttribute(const std::string& attribute) const;
};

const char* toString(TypeNode::Kind kind);

// Parses `type`. Names in `genericNames` (and `Self`) are generic parameters.
// `complete` is cleared when trailing tokens could not be parsed; the
// returned node then describes only a prefix.
TypeNode parseType(const TypeRef& type,
                   const std::set<std::string>& genericNames,
                   bool* complete = nullptr);

// Canonical Swift spelling of `node`.
std::string spelling(const TypeNode& node);

// Qualified name encoded in a simple nominal USR ("s:10Foundation4DataV" ->
// "Foundation.Data"), or "" when the USR is not of that shape.
std::string qualifiedNameFromUSR(const std::string& usr);

// Generic parameter names in scope for `symbol`: its own and those of every
// enclosing declaration.
std::set<std::string> genericNamesInScope(const Module& module,
                                          const Symbol& symbol);

// Well-known USRs of standard library and Foundation types.
namespace KnownTypes {
constexpr const char* kBool = "s:Sb";
constexpr const char* kInt = "s:Si";
constexpr const char* kInt8 = "s:s4Int8V";
constexpr const char* kInt16 = "s:s5Int16V";
constexpr const char* kInt32 = "s:s5Int32V";
constexpr const char* kInt64 = "s:s5Int64V";
constexpr const char* kUInt = "s:Su";
constexpr const char* kUInt8 = "s:s5UInt8V";
constexpr const char* kUInt16 = "s:s6UInt16V";
constexpr const char* kUInt32 = "s:s6UInt32V";
constexpr const char* kUInt64 = "s:s6UInt64V";
constexpr const char* kFloat = "s:Sf";
constexpr const char* kDouble = "s:Sd";
constexpr const char* kCGFloat = "s:14CoreFoundation7CGFloatV";
constexpr const char* kString = "s:SS";
constexpr const char* kCharacter = "s:SJ";
constexpr const char* kOptional = "s:Sq";
constexpr const char* kArray = "s:Sa";
constexpr const char* kDictionary = "s:SD";
constexpr const char* kSet = "s:Sh";
constexpr const char* kVoid = "s:s4Voida";
constexpr const char* kURL = "s:10Foundation3URLV";
constexpr const char* kData = "s:10Foundation4DataV";
constexpr const char* kDate = "s:10Foundation4DateV";
constexpr const char* kError = "s:s5ErrorP";
}  // namespace KnownTypes

}  // namespace Swift
