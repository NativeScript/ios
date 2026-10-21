#pragma once

#include <set>
#include <string>
#include <vector>

#include "SwiftIR.h"

namespace Swift {

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
// enclosing declaration, including those an instantiation substitutes.
std::set<std::string> genericNamesInScope(const Module& module,
                                          const Symbol& symbol);

// `node` with each generic parameter `substitutions` names replaced by its
// argument.
TypeNode substitute(
    const TypeNode& node,
    const std::vector<std::pair<std::string, TypeNode>>& substitutions);

// The id of the instantiation `node` (a generic nominal with arguments)
// names: its USR followed by its arguments' keys.
std::string instantiationKey(const TypeNode& node);

// Adds a synthetic, non-generic type for every concrete instantiation of a
// module generic type that the module spells (`Forecast<DayWeather>` in a
// signature or a public typealias), with copies of the generic type's
// members whose generic parameters stand for its arguments. Instantiations
// spelled only inside other instantiations' members are followed to a
// bounded depth.
//
// Also adds a synthetic copy of each generic function, method and
// initializer outside generic types for every combination of concrete
// stand-ins for its type parameters: `Double`, `String` and `Bool` (`Int`
// for integer protocols) as its standard library constraints allow, a unit
// protocol's existential, or its superclass constraint. Combinations JS
// arguments could not tell apart are not added.
void instantiateGenerics(Module& module);

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
constexpr const char* kAsyncSequence = "s:Sci";
constexpr const char* kAsyncStream = "s:ScS";
constexpr const char* kAsyncThrowingStream = "s:Scs";
constexpr const char* kVoid = "s:s4Voida";
constexpr const char* kURL = "s:10Foundation3URLV";
constexpr const char* kData = "s:10Foundation4DataV";
constexpr const char* kDate = "s:10Foundation4DateV";
constexpr const char* kError = "s:s5ErrorP";
constexpr const char* kResult = "s:s6ResultO";
constexpr const char* kAnyPublisher = "s:7Combine12AnyPublisherV";
constexpr const char* kPassthroughSubject = "s:7Combine18PassthroughSubjectC";
constexpr const char* kCurrentValueSubject = "s:7Combine19CurrentValueSubjectC";
}  // namespace KnownTypes

}  // namespace Swift
