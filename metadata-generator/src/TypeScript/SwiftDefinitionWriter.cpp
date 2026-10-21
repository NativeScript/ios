#include "SwiftDefinitionWriter.h"

#include <llvm/ADT/StringExtras.h>

#include <deque>
#include <map>
#include <set>
#include <sstream>

#include "Swift/SwiftSource.h"
#include "Swift/SwiftSurface.h"

namespace TypeScript {

using namespace Swift;

namespace {

using Member = SwiftSurface::Member;

// One JS name on one owner, as NativeScript/runtime/SwiftInterop.mm groups
// members.
struct Group {
  int owner;
  // Module-level members: their module.
  std::string module;
  SwiftSurface::MemberKind kind;
  std::string jsName;
  std::vector<const Member*> overloads;
};

bool isReserved(const std::string& name) {
  static const std::set<std::string> reserved = {
      "break",    "case",      "catch",  "class",      "const",     "continue",
      "debugger", "default",   "delete", "do",         "else",      "enum",
      "export",   "extends",   "false",  "finally",    "for",       "function",
      "if",       "import",    "in",     "instanceof", "new",       "null",
      "return",   "super",     "switch", "this",       "throw",     "true",
      "try",      "typeof",    "var",    "void",       "while",     "with",
      "yield",    "let",       "static", "implements", "interface", "package",
      "private",  "protected", "public", "await",      "arguments", "eval"};
  return reserved.count(name) > 0;
}

bool isIdentifier(const std::string& name) {
  if (name.empty() ||
      !(llvm::isAlpha(name[0]) || name[0] == '_' || name[0] == '$')) {
    return false;
  }
  for (char c : name) {
    if (!(llvm::isAlnum(c) || c == '_' || c == '$')) {
      return false;
    }
  }
  return true;
}

std::string propertyKey(const std::string& name) {
  return isIdentifier(name) ? name : "\"" + name + "\"";
}

std::string parameterName(const Parameter& parameter, size_t index) {
  std::string name = !parameter.internalName.empty() ? parameter.internalName
                                                     : parameter.label;
  if (!isIdentifier(name)) {
    return "arg" + std::to_string(index);
  }
  return isReserved(name) ? name + "_" : name;
}

// Swift display name of a signature code, as the runtime spells it in typed
// keys ("scale(by: Int)").
std::string codeDisplayName(const SwiftSurface& surface,
                            const BridgedType& type) {
  std::string name;
  switch (type.bridge) {
    case Bridge::Void:
      name = "Void";
      break;
    case Bridge::Bool:
      name = "Bool";
      break;
    case Bridge::Integer: {
      std::string code = signatureCode(surface, type);
      bool isSigned = code[0] == 'i';
      std::string bits =
          llvm::StringRef(code).drop_front().take_while(llvm::isDigit).str();
      name =
          std::string(isSigned ? "Int" : "UInt") + (bits == "64" ? "" : bits);
      break;
    }
    case Bridge::Floating:
      name =
          unwrappedNode(type).usr() == KnownTypes::kFloat ? "Float" : "Double";
      break;
    case Bridge::String:
      name = "String";
      break;
    case Bridge::ClassHandle:
    case Bridge::StructBox:
    case Bridge::EnumCase:
    case Bridge::TaggedEnum:
    case Bridge::Protocol: {
      int index = surface.indexOf(type.symbolId);
      name = index >= 0 ? surface.types[index].symbol->name : "?";
      break;
    }
    case Bridge::Date:
      name = "Date";
      break;
    case Bridge::URL:
      name = "URL";
      break;
    case Bridge::Data:
      name = "Data";
      break;
    case Bridge::Array:
      name = "[" + codeDisplayName(surface, type.elements.at(0)) + "]";
      break;
    case Bridge::Dictionary:
      name = "[String: " + codeDisplayName(surface, type.elements.at(0)) + "]";
      break;
    case Bridge::Closure: {
      std::vector<std::string> parameters;
      for (const auto& element : type.elements) {
        parameters.push_back(codeDisplayName(surface, element));
      }
      name = "(" + llvm::join(parameters, ", ") + ") -> " +
             (type.results.empty() ? "Void"
                                   : codeDisplayName(surface, type.results[0]));
      break;
    }
    case Bridge::AsyncSequence:
      name = "AsyncSequence<" + codeDisplayName(surface, type.elements.at(0)) +
             ">";
      break;
    case Bridge::ObjCObject:
    case Bridge::TypeParameter:
      name = type.objcClass;
      break;
    case Bridge::None:
      name = "?";
      break;
  }
  return (type.isInout ? "inout " : "") + (type.optional ? name + "?" : name);
}

std::string typedKey(const SwiftSurface& surface, const Member& member) {
  const Symbol& symbol = *member.symbol;
  std::string key = symbol.baseName + "(";
  for (size_t i = 0; i < member.capability->parameters.size(); i++) {
    if (i > 0) {
      key += ", ";
    }
    std::string label =
        i < symbol.parameters.size() ? symbol.parameters[i].label : "";
    key += (label.empty() ? "_" : label) + ": " +
           codeDisplayName(surface, member.capability->parameters[i]);
  }
  return key + ")";
}

class Writer {
 public:
  Writer(const Module& module, const Classification& classification,
         const std::string& moduleName)
      : _module(module),
        _classification(classification),
        _name(moduleName),
        _surface(describeSurface(module, classification)) {
    // Instantiations of one generic type are declared once, by the first.
    for (const auto& type : _surface.types) {
      if (!type.symbol->genericBase.empty()) {
        _families.emplace(type.symbol->genericBase, type.index);
      }
    }
  }

  std::string write() {
    buildGroups();

    _out << "// Generated by objc-metadata-generator from the " << _name
         << " symbol graphs. Do not edit.\n"
         << "// The JavaScript surface ns:swift exposes for " << _name
         << ": every declaration is backed by a generated thunk.\n\n"
         << "declare module \"ns:swift/" << _name << "\" {\n";

    buildTree();
    for (const auto& path : _topLevel) {
      writeNode(_nodes.at(path), "  ");
    }
    writeTypeAliases();
    writeModuleMembers();

    _out << "}\n\n"
         << "declare module \"ns:swift\" {\n"
         << "  interface SwiftModules {\n"
         << "    " << propertyKey(_name) << ": typeof import(\"ns:swift/"
         << _name << "\");\n"
         << "  }\n"
         << "}\n";
    return _out.str();
  }

 private:
  // The first instantiation of a generic type's family, or -1.
  int familyOf(int typeIndex) const {
    if (typeIndex < 0) {
      return -1;
    }
    auto it = _families.find(_surface.types[typeIndex].symbol->genericBase);
    return it == _families.end() ? -1 : it->second;
  }

  // `member` of an instantiation as its generic type declares it, once per
  // family; null for the repeats.
  const Member* familyMember(const Member& member) {
    int family = familyOf(member.owner);
    const std::string& baseId = member.symbol->genericBase;
    auto capability = _classification.templates.find(baseId);
    const Symbol* symbol = _module.find(baseId);
    if (family < 0 || !_seenFamilyMembers.insert(baseId).second ||
        capability == _classification.templates.end() || !symbol) {
      return nullptr;
    }
    Member generic = member;
    generic.owner = family;
    generic.symbol = symbol;
    generic.capability = &capability->second;
    generic.result = capability->second.result;
    if (generic.kind == SwiftSurface::kInstanceProperty ||
        generic.kind == SwiftSurface::kStaticProperty) {
      generic.result = capability->second.result;
    }
    _familyMembers.push_back(generic);
    return &_familyMembers.back();
  }

  // A family's TypeScript type parameters, "<First, Second>", or "".
  std::string typeParameters(const SwiftSurface::Type& type) const {
    const Symbol* base = _module.find(type.symbol->genericBase);
    if (!base || base->genericParameters.empty()) {
      return "";
    }
    std::vector<std::string> names;
    for (const auto& parameter : base->genericParameters) {
      names.push_back(parameter.name);
    }
    return "<" + llvm::join(names, ", ") + ">";
  }

  void buildGroups() {
    std::map<std::tuple<int, int, std::string, std::string>, size_t> index;
    for (const auto& original : _surface.members) {
      const Member* resolved = &original;
      if (familyOf(original.owner) >= 0) {
        resolved = familyMember(original);
        if (resolved == nullptr) {
          continue;
        }
      }
      const Member& member = *resolved;
      std::string module = member.owner < 0 ? member.module : "";
      auto key = std::make_tuple(member.owner, static_cast<int>(member.kind),
                                 member.capability->jsName, module);
      auto it = index.find(key);
      if (it == index.end()) {
        index.emplace(key, _groups.size());
        _groups.push_back(Group{
            member.owner, module, member.kind, member.capability->jsName, {}});
        it = index.find(key);
      }
      _groups[it->second].overloads.push_back(&member);
    }

    // Inherited overloads the subclass does not override (see BuildGroups in
    // SwiftInterop.mm).
    for (auto& group : _groups) {
      if (group.kind != SwiftSurface::kInstanceMethod || group.owner < 0) {
        continue;
      }
      for (int ancestor = _surface.types[group.owner].superIndex; ancestor >= 0;
           ancestor = _surface.types[ancestor].superIndex) {
        auto inherited =
            index.find(std::make_tuple(ancestor, static_cast<int>(group.kind),
                                       group.jsName, std::string()));
        if (inherited == index.end()) {
          continue;
        }
        for (const Member* candidate : _groups[inherited->second].overloads) {
          bool overridden = false;
          for (const Member* own : group.overloads) {
            overridden |= own->symbol->name == candidate->symbol->name &&
                          own->signature == candidate->signature;
          }
          if (!overridden) {
            group.overloads.push_back(candidate);
          }
        }
      }
    }
  }

  bool isA(int type, int expected) const {
    for (int current = type; current >= 0;
         current = _surface.types[current].superIndex) {
      if (current == expected) {
        return true;
      }
    }
    return false;
  }

  // Whether some JS value is accepted as both `a` and `b` (overload
  // resolution in the runtime would then see both).
  bool overlaps(const BridgedType& a, const BridgedType& b) const {
    if (a.isInout || b.isInout) {
      // A reference object is a record.
      auto record = [](const BridgedType& type) {
        return type.isInout || type.bridge == Bridge::Dictionary ||
               type.bridge == Bridge::TaggedEnum;
      };
      return record(a) && record(b);
    }
    if (a.optional && b.optional) {
      return true;
    }
    auto numeric = [](Bridge bridge) {
      return bridge == Bridge::Integer || bridge == Bridge::Floating;
    };
    auto textual = [](Bridge bridge) {
      return bridge == Bridge::String || bridge == Bridge::EnumCase ||
             bridge == Bridge::URL;
    };
    auto record = [](Bridge bridge) {
      return bridge == Bridge::Dictionary || bridge == Bridge::TaggedEnum;
    };
    if (a.bridge == Bridge::Array && b.bridge == Bridge::Array) {
      // The runtime tells arrays apart by their first element; an empty
      // array still matches both.
      return a.elements.empty() || b.elements.empty() ||
             overlaps(a.elements[0], b.elements[0]);
    }
    if (a.bridge == b.bridge &&
        (a.bridge == Bridge::Date || a.bridge == Bridge::Data ||
         a.bridge == Bridge::Closure)) {
      return true;
    }
    if (record(a.bridge) && record(b.bridge)) {
      return true;
    }
    if (numeric(a.bridge) && numeric(b.bridge)) {
      return true;
    }
    if (textual(a.bridge) && textual(b.bridge)) {
      return true;
    }
    if (a.bridge == Bridge::Bool && b.bridge == Bridge::Bool) {
      return true;
    }
    bool objects =
        (a.bridge == Bridge::ClassHandle || a.bridge == Bridge::StructBox) &&
        (b.bridge == Bridge::ClassHandle || b.bridge == Bridge::StructBox);
    if (objects) {
      int left = _surface.indexOf(a.symbolId);
      int right = _surface.indexOf(b.symbolId);
      return isA(left, right) || isA(right, left);
    }
    return false;
  }

  bool ambiguousWithin(const Group& group, const Member& member) const {
    const auto& parameters = member.capability->parameters;
    for (const Member* other : group.overloads) {
      if (other == &member ||
          other->capability->parameters.size() != parameters.size()) {
        continue;
      }
      bool all = true;
      for (size_t i = 0; all && i < parameters.size(); i++) {
        all = overlaps(parameters[i], other->capability->parameters[i]);
      }
      if (all) {
        return true;
      }
    }
    return false;
  }

  // Keys installed per overload when the group has several (see
  // OverloadKeys in SwiftInterop.mm).
  std::vector<std::pair<std::string, const Member*>> overloadKeys(
      const Group& group) const {
    std::vector<std::pair<std::string, const Member*>> keys;
    if (group.overloads.size() < 2) {
      return keys;
    }
    std::map<std::string, int> counts;
    for (const Member* member : group.overloads) {
      counts[member->symbol->name]++;
    }
    for (const Member* member : group.overloads) {
      keys.emplace_back(counts[member->symbol->name] == 1
                            ? member->symbol->name
                            : typedKey(_surface, *member),
                        member);
    }
    return keys;
  }

  std::string typeName(const BridgedType& type) const {
    int index = _surface.indexOf(type.symbolId);
    if (index < 0) {
      // A generic type's own declarations naming the type.
      auto family = _families.find(type.symbolId);
      index = family == _families.end() ? -1 : family->second;
    }
    if (index < 0) {
      return "unknown";
    }
    std::string name = typePath(_surface.types[index]);
    if (!type.typeArguments.empty()) {
      std::vector<std::string> arguments;
      for (const auto& argument : type.typeArguments) {
        arguments.push_back(
            argument.bridge == Bridge::None ? "unknown" : outputType(argument));
      }
      name += "<" + llvm::join(arguments, ", ") + ">";
    }
    return name;
  }

  // `type` as this module's declarations name it.
  std::string typePath(const SwiftSurface::Type& type) const {
    std::string path = llvm::join(type.symbol->pathComponents, ".");
    return type.module == _name
               ? path
               : "import(\"ns:swift/" + type.module + "\")." + path;
  }

  // NativeScript's Objective-C typings declare classes globally by their
  // runtime name; Swift classes without @objc(Name) have none there.
  static std::string objcTypeName(const BridgedType& type) {
    return isIdentifier(type.objcClass) ? type.objcClass : "NSObject";
  }

  std::string inputType(const BridgedType& type) const {
    if (type.isInout) {
      BridgedType value = type;
      value.isInout = false;
      return "{ value: " + inputType(value) + " }";
    }
    std::string ts;
    switch (type.bridge) {
      case Bridge::Bool:
        ts = "boolean";
        break;
      case Bridge::Integer:
        ts = "number | bigint";
        break;
      case Bridge::Floating:
        ts = "number";
        break;
      case Bridge::String:
        ts = "string";
        break;
      case Bridge::ClassHandle:
      case Bridge::StructBox:
      case Bridge::EnumCase:
      case Bridge::TaggedEnum:
      case Bridge::Protocol:
        ts = typeName(type);
        break;
      case Bridge::ObjCObject:
        ts = objcTypeName(type);
        break;
      case Bridge::TypeParameter:
        ts = type.objcClass;
        break;
      case Bridge::Date:
        ts = "Date";
        break;
      case Bridge::URL:
        ts = "string | URL";
        break;
      case Bridge::Data:
        ts = "ArrayBuffer | ArrayBufferView";
        break;
      case Bridge::Array:
        ts = "readonly (" + inputType(type.elements.at(0)) + ")[]";
        break;
      case Bridge::Dictionary:
        ts = "Readonly<Record<string, " + inputType(type.elements.at(0)) + ">>";
        break;
      case Bridge::Closure: {
        // The function receives what Swift passes: output types.
        std::vector<std::string> parameters;
        for (size_t i = 0; i < type.elements.size(); i++) {
          parameters.push_back("arg" + std::to_string(i) + ": " +
                               outputType(type.elements[i]));
        }
        // What JS returns is converted like an argument: input types.
        ts = "(" + llvm::join(parameters, ", ") + ") => " +
             (type.results.empty() ? "void" : inputType(type.results[0]));
        break;
      }
      default:
        ts = "never";
        break;
    }
    return type.optional ? "(" + ts + ") | null | undefined" : ts;
  }

  std::string outputType(const BridgedType& type) const {
    std::string ts;
    switch (type.bridge) {
      case Bridge::Void:
        return "void";
      case Bridge::Bool:
        ts = "boolean";
        break;
      case Bridge::Integer:
      case Bridge::Floating:
        ts = "number";
        break;
      case Bridge::String:
        ts = "string";
        break;
      case Bridge::ClassHandle:
      case Bridge::StructBox:
      case Bridge::EnumCase:
      case Bridge::TaggedEnum:
      case Bridge::Protocol:
        ts = typeName(type);
        break;
      case Bridge::ObjCObject:
        ts = objcTypeName(type);
        break;
      case Bridge::TypeParameter:
        ts = type.objcClass;
        break;
      case Bridge::Date:
        ts = "Date";
        break;
      case Bridge::URL:
        ts = "URL";
        break;
      case Bridge::Data:
        ts = "Uint8Array";
        break;
      case Bridge::Array:
        ts = "(" + outputType(type.elements.at(0)) + ")[]";
        break;
      case Bridge::Dictionary:
        ts = "Record<string, " + outputType(type.elements.at(0)) + ">";
        break;
      case Bridge::Closure:
        ts = "never";
        break;
      case Bridge::AsyncSequence:
        ts = "AsyncIterableIterator<" + outputType(type.elements.at(0)) + ">";
        break;
      case Bridge::None:
        ts = "never";
        break;
    }
    return type.optional ? ts + " | null" : ts;
  }

  // A member's JS result: a Promise for async calls.
  std::string resultOf(const Member& member) const {
    std::string type = outputType(member.result);
    return (member.flags & SwiftSurface::kAsync) ? "Promise<" + type + ">"
                                                 : type;
  }

  std::string parameterList(const Member& member,
                            const std::string& receiver = "") const {
    std::vector<std::string> parts;
    if (!receiver.empty()) {
      parts.push_back("value: " + receiver);
    }
    const auto& parameters = member.capability->parameters;
    for (size_t i = 0; i < parameters.size(); i++) {
      const Parameter* parameter = i < member.symbol->parameters.size()
                                       ? &member.symbol->parameters[i]
                                       : nullptr;
      std::string name =
          parameter ? parameterName(*parameter, i) : "arg" + std::to_string(i);
      parts.push_back(name + ": " + inputType(parameters[i]));
    }
    return llvm::join(parts, ", ");
  }

  // `{ x: number; y: number }` for initializers JS can call with labels.
  std::string labeledParameters(const Member& member) const {
    const auto& parameters = member.capability->parameters;
    if (parameters.empty()) {
      return "";
    }
    std::vector<std::string> fields;
    for (size_t i = 0; i < parameters.size(); i++) {
      const std::string& label = i < member.symbol->parameters.size()
                                     ? member.symbol->parameters[i].label
                                     : "";
      if (label.empty()) {
        return "";
      }
      fields.push_back(propertyKey(label) + ": " + inputType(parameters[i]));
    }
    return "{ " + llvm::join(fields, "; ") + " }";
  }

  void writeDoc(const Symbol& symbol, const std::string& indent) {
    std::vector<std::string> lines;
    if (!symbol.docComment.empty()) {
      llvm::SmallVector<llvm::StringRef, 16> docLines;
      llvm::StringRef(symbol.docComment).split(docLines, '\n');
      for (llvm::StringRef line : docLines) {
        lines.push_back(line.str());
      }
    }
    for (const Availability* availability :
         applicableAvailability(_module, symbol)) {
      if (availability->isUnconditionallyDeprecated ||
          availability->deprecated) {
        std::string message = availability->message;
        if (message.empty() && !availability->renamed.empty()) {
          message = "Renamed to `" + availability->renamed + "`.";
        }
        lines.push_back("@deprecated" + (message.empty() ? "" : " " + message));
      }
    }
    std::string condition = availabilityCondition(_module, symbol);
    if (!condition.empty()) {
      lines.push_back(
          "@remarks Requires " +
          llvm::StringRef(condition).rsplit(',').first.trim().str() +
          "; throws on earlier versions.");
    }
    if (lines.empty()) {
      return;
    }
    _out << indent << "/**\n";
    for (const auto& line : lines) {
      std::string safe = line;
      for (size_t at = safe.find("*/"); at != std::string::npos;
           at = safe.find("*/")) {
        safe.replace(at, 2, "* /");
      }
      _out << indent << " *" << (safe.empty() ? "" : " " + safe) << "\n";
    }
    _out << indent << " */\n";
  }

  void writeMethodGroup(const Group& group, const std::string& indent,
                        const std::string& prefix,
                        const std::string& receiver = "") {
    for (const Member* member : group.overloads) {
      if (ambiguousWithin(group, *member)) {
        continue;
      }
      writeDoc(*member->symbol, indent);
      _out << indent << prefix << propertyKey(group.jsName) << "("
           << parameterList(*member, receiver) << "): " << resultOf(*member)
           << ";\n";
    }
    for (const auto& key : overloadKeys(group)) {
      writeDoc(*key.second->symbol, indent);
      _out << indent << prefix << propertyKey(key.first) << "("
           << parameterList(*key.second, receiver)
           << "): " << resultOf(*key.second) << ";\n";
    }
  }

  // A type, or a namespace standing in for an unbridged parent, by JS path.
  struct Node {
    std::string name;
    const SwiftSurface::Type* type = nullptr;
    std::vector<std::string> children;
  };

  void buildTree() {
    for (const auto& type : _surface.types) {
      int family = familyOf(type.index);
      if (type.module != _name || (family >= 0 && family != type.index)) {
        continue;
      }
      const auto& components = type.symbol->pathComponents;
      std::string path;
      for (size_t i = 0; i < components.size(); i++) {
        std::string parent = path;
        path += (i > 0 ? "." : "") + components[i];
        auto inserted = _nodes.emplace(path, Node{components[i], nullptr, {}});
        if (inserted.second) {
          (parent.empty() ? _topLevel : _nodes.at(parent).children)
              .push_back(path);
        }
      }
      _nodes.at(path).type = &type;
    }
  }

  void writeNode(const Node& node, const std::string& indent) {
    if (node.type && (node.type->kind == SwiftSurface::kEnum ||
                      node.type->kind == SwiftSurface::kTaggedEnum)) {
      writeEnum(*node.type, node, indent);
      return;
    }
    if (node.type && node.type->kind == SwiftSurface::kProtocol) {
      writeInterface(*node.type, indent);
    } else if (node.type) {
      writeClass(*node.type, indent);
    }
    if (!node.children.empty()) {
      _out << indent << "export namespace " << node.name << " {\n";
      for (const auto& child : node.children) {
        writeNode(_nodes.at(child), indent + "  ");
      }
      _out << indent << "}\n\n";
    }
  }

  // What a JS object implementing the protocol provides: its requirements.
  void writeInterface(const SwiftSurface::Type& type,
                      const std::string& indent) {
    const Symbol& symbol = *type.symbol;
    std::string inner = indent + "  ";
    writeDoc(symbol, indent);
    _out << indent << "export interface " << symbol.name;
    if (type.superIndex >= 0) {
      _out << " extends " << typePath(_surface.types[type.superIndex]);
    }
    _out << " {\n";
    for (const Member* member : _surface.requirementsOf(type.index)) {
      if (member->owner != type.index) {
        continue;
      }
      writeDoc(*member->symbol, inner);
      if (member->kind == SwiftSurface::kInstanceProperty) {
        _out << inner << (member->symbol->isSettable ? "" : "readonly ")
             << propertyKey(member->capability->jsName) << ": "
             << outputType(member->result) << ";\n";
      } else {
        _out << inner << propertyKey(member->capability->jsName) << "("
             << parameterList(*member) << "): " << outputType(member->result)
             << ";\n";
      }
    }
    _out << indent << "}\n\n";
  }

  void writeClass(const SwiftSurface::Type& type, const std::string& indent) {
    const Symbol& symbol = *type.symbol;
    std::string inner = indent + "  ";
    writeDoc(symbol, indent);
    _out << indent << "export class " << symbol.name << typeParameters(type);
    if (type.superIndex >= 0) {
      _out << " extends " << typePath(_surface.types[type.superIndex]);
    }
    _out << " {\n";

    bool hasInitializer = false;
    for (const Group& group : _groups) {
      if (group.owner != type.index ||
          group.kind != SwiftSurface::kInitializer) {
        continue;
      }
      hasInitializer = true;
      for (const Member* member : group.overloads) {
        writeDoc(*member->symbol, inner);
        _out << inner << "constructor(" << parameterList(*member) << ");\n";
        std::string labeled = labeledParameters(*member);
        if (!labeled.empty()) {
          _out << inner << "constructor(args: " << labeled << ");\n";
        }
      }
    }
    if (!hasInitializer) {
      _out << inner << "private constructor();\n";
    }

    for (const Group& group : _groups) {
      if (group.owner != type.index) {
        continue;
      }
      const Member& first = *group.overloads[0];
      switch (group.kind) {
        case SwiftSurface::kInstanceProperty:
        case SwiftSurface::kStaticProperty:
          writeDoc(*first.symbol, inner);
          _out << inner
               << (group.kind == SwiftSurface::kStaticProperty ? "static " : "")
               << ((first.flags & SwiftSurface::kSettable) ? "" : "readonly ")
               << propertyKey(group.jsName) << ": " << resultOf(first) << ";\n";
          break;
        case SwiftSurface::kInstanceMethod:
          writeMethodGroup(group, inner, "");
          break;
        case SwiftSurface::kStaticMethod:
          writeMethodGroup(group, inner, "static ");
          break;
        default:
          break;
      }
    }
    _out << indent << "}\n\n";
  }

  // `type` (a union of case names, or of case objects when cases carry
  // values) plus a namespace of the enum object's members, which can also
  // hold nested types; TypeScript cannot merge a namespace with a const.
  void writeEnum(const SwiftSurface::Type& type, const Node& node,
                 const std::string& indent) {
    const Symbol& symbol = *type.symbol;
    std::string self = llvm::join(symbol.pathComponents, ".");
    std::string inner = indent + "  ";
    bool tagged = type.kind == SwiftSurface::kTaggedEnum;
    std::string parameters = typeParameters(type);
    self += parameters;
    std::vector<const Member*> caseMembers;
    for (const Group& group : _groups) {
      if (group.owner == type.index && group.kind == SwiftSurface::kEnumCase) {
        caseMembers.push_back(group.overloads[0]);
      }
    }
    std::vector<std::string> cases;
    for (const Member* member : caseMembers) {
      const std::string& name = member->capability->jsName;
      if (!tagged) {
        cases.push_back("\"" + name + "\"");
        continue;
      }
      std::string shape = "{ case: \"" + name + "\"";
      std::vector<std::string> keys = caseKeys(*member->symbol);
      const auto& elements = member->capability->parameters;
      for (size_t i = 0; i < elements.size() && i < keys.size(); i++) {
        shape += "; " + propertyKey(keys[i]) + ": " + outputType(elements[i]);
      }
      cases.push_back(shape + " }");
    }
    writeDoc(symbol, indent);
    _out << indent << "export type " << symbol.name << parameters << " =";
    if (cases.empty()) {
      _out << " never";
    } else if (tagged) {
      for (const auto& shape : cases) {
        _out << "\n" << inner << "| " << shape;
      }
    } else {
      _out << " " << llvm::join(cases, " | ");
    }
    _out << ";\n";
    _out << indent << "export namespace " << symbol.name << " {\n";
    for (const Group& group : _groups) {
      if (group.owner != type.index || !isIdentifier(group.jsName) ||
          isReserved(group.jsName)) {
        continue;
      }
      const Member& first = *group.overloads[0];
      switch (group.kind) {
        case SwiftSurface::kEnumCase:
          if (!tagged) {
            _out << inner << "export const " << group.jsName << ": \""
                 << group.jsName << "\";\n";
          }
          break;
        case SwiftSurface::kInitializer:
          // Enum initializers are exposed as `init`: `new` cannot produce a
          // case.
          for (const Member* member : group.overloads) {
            writeDoc(*member->symbol, inner);
            _out << inner << "export function init(" << parameterList(*member)
                 << "): " << resultOf(*member) << ";\n";
          }
          break;
        case SwiftSurface::kStaticProperty:
          writeDoc(*first.symbol, inner);
          _out << inner << "export "
               << ((first.flags & SwiftSurface::kSettable) ? "let " : "const ")
               << group.jsName << ": " << resultOf(first) << ";\n";
          break;
        case SwiftSurface::kInstanceProperty:
          // A case value has no members; instance members take it first.
          writeDoc(*first.symbol, inner);
          _out << inner << "export function " << group.jsName
               << "(value: " << self << "): " << resultOf(first) << ";\n";
          break;
        case SwiftSurface::kInstanceMethod:
        case SwiftSurface::kStaticMethod:
          for (const Member* member : group.overloads) {
            if (ambiguousWithin(group, *member)) {
              continue;
            }
            writeDoc(*member->symbol, inner);
            _out << inner << "export function " << group.jsName << "("
                 << parameterList(
                        *member,
                        group.kind == SwiftSurface::kInstanceMethod ? self : "")
                 << "): " << resultOf(*member) << ";\n";
          }
          break;
        default:
          break;
      }
    }
    for (const auto& child : node.children) {
      writeNode(_nodes.at(child), inner);
    }
    _out << indent << "}\n\n";
  }

  // Top-level typealiases whose type bridges (`Score = Pair<string, number>`).
  void writeTypeAliases() {
    for (const auto& id : _module.topLevelIds) {
      const Symbol* symbol = _module.find(id);
      const Capability* capability = _classification.find(id);
      if (!symbol || symbol->kind != SymbolKind::TypeAlias || !capability ||
          capability->result.bridge == Bridge::None ||
          (symbol->module.empty() ? _module.name : symbol->module) != _name ||
          !isIdentifier(symbol->name) || isReserved(symbol->name)) {
        continue;
      }
      writeDoc(*symbol, "  ");
      _out << "  export type " << symbol->name << " = "
           << outputType(capability->result) << ";\n";
    }
  }

  void writeModuleMembers() {
    for (const Group& group : _groups) {
      if (group.owner >= 0 || group.module != _name) {
        continue;
      }
      const Member& first = *group.overloads[0];
      if (!isIdentifier(group.jsName) || isReserved(group.jsName)) {
        continue;
      }
      if (group.kind == SwiftSurface::kVariable) {
        writeDoc(*first.symbol, "  ");
        _out << "  export "
             << ((first.flags & SwiftSurface::kSettable) ? "let " : "const ")
             << group.jsName << ": " << resultOf(first) << ";\n";
        continue;
      }
      for (const Member* member : group.overloads) {
        if (ambiguousWithin(group, *member)) {
          continue;
        }
        writeDoc(*member->symbol, "  ");
        _out << "  export function " << group.jsName << "("
             << parameterList(*member) << "): " << resultOf(*member) << ";\n";
      }
    }
  }

  const Module& _module;
  const Classification& _classification;
  // The unit module these declarations are for.
  std::string _name;
  // Generic type id -> the instantiation that declares the family.
  std::map<std::string, int> _families;
  std::set<std::string> _seenFamilyMembers;
  std::deque<Member> _familyMembers;
  SwiftSurface _surface;
  std::vector<Group> _groups;
  std::map<std::string, Node> _nodes;
  std::vector<std::string> _topLevel;
  std::ostringstream _out;
};

}  // namespace

std::string SwiftDefinitionWriter::write() {
  return Writer(_module, _classification, _moduleName).write();
}

}  // namespace TypeScript
