#include "SymbolGraphLoader.h"

#include <llvm/ADT/STLFunctionalExtras.h>
#include <llvm/ADT/StringExtras.h>
#include <llvm/ADT/StringSwitch.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>

#include <algorithm>
#include <set>
#include <tuple>

#include "FragmentTokens.h"

namespace Swift {

namespace {

namespace fs = llvm::sys::fs;
namespace path = llvm::sys::path;
using llvm::json::Array;
using llvm::json::Object;

void report(std::vector<Diagnostic>& diagnostics, Severity severity,
            std::string code, std::string message, std::string file,
            std::string symbolId = "") {
  diagnostics.push_back(Diagnostic{severity, std::move(code),
                                   std::move(message), std::move(file),
                                   std::move(symbolId)});
}

std::string str(const Object* object, llvm::StringRef key) {
  if (!object) {
    return "";
  }
  auto value = object->getString(key);
  return value ? value->str() : "";
}

int integer(const Object* object, llvm::StringRef key) {
  if (!object) {
    return 0;
  }
  auto value = object->getInteger(key);
  return value ? static_cast<int>(*value) : 0;
}

bool boolean(const Object* object, llvm::StringRef key) {
  if (!object) {
    return false;
  }
  auto value = object->getBoolean(key);
  return value && *value;
}

std::optional<Version> version(const Object* object) {
  if (!object) {
    return std::nullopt;
  }
  return Version{integer(object, "major"), integer(object, "minor"),
                 integer(object, "patch")};
}

bool isGraphFileName(llvm::StringRef fileName) {
  return fileName.endswith(".symbols.json") ||
         fileName.endswith(".symbolgraph");
}

// --- Declaration fragment parsing -------------------------------------------

using namespace FragmentTokens;

bool isVoid(const TypeRef& type) {
  return type.spelling == "()" || type.spelling == "Void";
}

class DeclarationParser {
 public:
  DeclarationParser(const Tokens& tokens, Symbol& symbol)
      : _tokens(tokens), _symbol(symbol) {}

  // Returns false when the declaration does not have the expected shape.
  bool parse() {
    parsePrefix();
    if (_intro.empty()) {
      return false;
    }

    if (_intro == "init") {
      if (peekPunct('?')) {
        _symbol.isFailable = true;
        _pos++;
      } else if (peekPunct('!')) {
        _symbol.isFailable = true;
        _symbol.isImplicitlyUnwrappedFailable = true;
        _pos++;
      }
    } else if (_intro != "subscript" && _intro != "deinit") {
      skipSpaces();
      if (!atEnd() && _tokens[_pos].isFragment("identifier")) {
        _pos++;
      }
    }

    skipSpaces();
    if (peekPunct('<')) {
      skipBalanced();
    }

    bool isCallable = _intro == "func" || _intro == "init" ||
                      _intro == "subscript" || _intro == "case" ||
                      _intro == "macro";
    if (isCallable) {
      skipSpaces();
      if (peekPunct('(')) {
        if (!parseParameterList()) {
          return false;
        }
      } else if (_intro != "case") {
        return false;
      }
      parseEffects();
      skipSpaces();
      if (!atEnd() && _tokens[_pos].type == Token::Type::Arrow) {
        _pos++;
        size_t start = _pos;
        size_t end = findTypeEnd(start);
        _symbol.returnType =
            makeTypeRef(_tokens.begin() + start, _tokens.begin() + end);
        _pos = end;
      }
      if (_intro == "subscript") {
        _symbol.valueType = _symbol.returnType;
        parseAccessors(/*storedIfMissing*/ false);
      }
      return true;
    }

    if (_intro == "var" || _intro == "let") {
      skipSpaces();
      if (!peekPunct(':')) {
        return false;
      }
      _pos++;
      size_t start = _pos;
      size_t end = findTypeEnd(start);
      _symbol.valueType =
          makeTypeRef(_tokens.begin() + start, _tokens.begin() + end);
      _pos = end;
      _symbol.isLet = _intro == "let";
      parseAccessors(/*storedIfMissing*/ !_symbol.isLet);
      return true;
    }

    if (_intro == "typealias") {
      skipSpaces();
      if (peekPunct('=')) {
        _pos++;
        size_t start = _pos;
        size_t end = findTypeEnd(start);
        _symbol.aliasedType =
            makeTypeRef(_tokens.begin() + start, _tokens.begin() + end);
      }
      return true;
    }

    return true;
  }

  const std::string& intro() const { return _intro; }
  bool malformed() const { return _malformed; }

 private:
  bool atEnd() const { return _pos >= _tokens.size(); }

  bool peekPunct(char c) const { return !atEnd() && _tokens[_pos].isPunct(c); }

  void skipSpaces() {
    while (!atEnd() && _tokens[_pos].type == Token::Type::Space) {
      _pos++;
    }
  }

  // Returns the attribute at `index` together with an argument list that
  // follows it directly (`@attached(peer, names: ...)`), advancing `index`
  // past both.
  std::string consumeAttribute(size_t& index, size_t end) const {
    llvm::StringRef text = _tokens[index].text;
    std::string attribute = text.trim().str();
    index++;
    // "@autoclosure " carries its separator inside the fragment; a following
    // '(' then starts the attributed type, not an argument list.
    bool abuts = !text.empty() && !llvm::isSpace(text.back());
    if (abuts && index < end &&
        (_tokens[index].isPunct('(') || _tokens[index].isPunct('<'))) {
      int depth = 0;
      while (index < end) {
        const Token& token = _tokens[index++];
        attribute += token.text;
        if (opens(token)) {
          depth++;
        } else if (closes(token) && --depth == 0) {
          break;
        }
      }
    }
    return attribute;
  }

  void skipBalanced() {
    int depth = 0;
    while (!atEnd()) {
      const Token& token = _tokens[_pos++];
      if (opens(token)) {
        depth++;
      } else if (closes(token) && --depth == 0) {
        return;
      }
    }
  }

  bool isIntroKeyword(const Token& token) const {
    static const std::set<std::string> intros = {
        "func", "init",     "deinit",    "subscript",      "case",
        "var",  "let",      "typealias", "associatedtype", "struct",
        "enum", "protocol", "actor",     "extension",      "macro"};
    if (!token.isFragment("keyword")) {
      return false;
    }
    if (token.text == "class") {
      // `class func` / `class var` use `class` as a modifier.
      return _symbol.kind == SymbolKind::Class ||
             _symbol.kind == SymbolKind::Actor;
    }
    return intros.count(token.text) > 0;
  }

  void parsePrefix() {
    while (!atEnd()) {
      const Token& token = _tokens[_pos];
      if (token.isFragment("attribute")) {
        _symbol.attributes.push_back(consumeAttribute(_pos, _tokens.size()));
        continue;
      } else if (isIntroKeyword(token)) {
        _intro = token.text;
        _pos++;
        return;
      } else if (token.isFragment("keyword")) {
        _symbol.modifiers.push_back(token.text);
      } else if (token.type != Token::Type::Space) {
        return;
      }
      _pos++;
    }
  }

  // End of a type that starts at `start`: the first `where`, `{`, or `=` at
  // nesting depth zero, or the end of the declaration.
  size_t findTypeEnd(size_t start) const {
    int depth = 0;
    for (size_t i = start; i < _tokens.size(); i++) {
      const Token& token = _tokens[i];
      if (opens(token)) {
        depth++;
      } else if (closes(token)) {
        depth--;
      } else if (depth == 0 && (token.isKeyword("where") ||
                                token.isPunct('{') || token.isPunct('='))) {
        return i;
      }
    }
    return _tokens.size();
  }

  bool parseParameterList() {
    _pos++;  // '('
    std::vector<std::pair<size_t, size_t>> segments;
    size_t segmentStart = _pos;
    int depth = 0;
    while (!atEnd()) {
      const Token& token = _tokens[_pos];
      if (depth == 0 && (token.isPunct(',') || token.isPunct(')'))) {
        segments.emplace_back(segmentStart, _pos);
        segmentStart = _pos + 1;
        if (token.isPunct(')')) {
          _pos++;
          for (const auto& segment : segments) {
            parseParameter(segment.first, segment.second);
          }
          return true;
        }
      } else if (opens(token)) {
        depth++;
      } else if (closes(token)) {
        depth--;
      }
      _pos++;
    }
    return false;
  }

  void parseParameter(size_t begin, size_t end) {
    while (begin < end && _tokens[begin].type == Token::Type::Space) {
      begin++;
    }
    if (begin == end) {
      return;
    }

    Parameter parameter;
    // Parameter attributes (result builders, property wrappers) precede the
    // argument label: `@ViewBuilder content: () -> Content`.
    while (begin < end && (_tokens[begin].isFragment("attribute") ||
                           _tokens[begin].type == Token::Type::Space)) {
      if (_tokens[begin].type == Token::Type::Space) {
        begin++;
      } else {
        parameter.attributes.push_back(consumeAttribute(begin, end));
      }
    }
    bool hasExternal = false;
    if (begin < end && _tokens[begin].isFragment("externalParam")) {
      hasExternal = true;
      parameter.label = _tokens[begin].text == "_" ? "" : _tokens[begin].text;
      parameter.internalName = parameter.label;
      begin++;
    }
    while (begin < end && _tokens[begin].type == Token::Type::Space) {
      begin++;
    }
    if (begin < end && _tokens[begin].isFragment("internalParam")) {
      parameter.internalName = _tokens[begin].text;
      begin++;
    }
    while (begin < end && _tokens[begin].type == Token::Type::Space) {
      begin++;
    }
    if (begin < end && _tokens[begin].isPunct(':')) {
      begin++;
    } else if (hasExternal) {
      // An externalParam must be followed by a type annotation.
      _malformed = true;
    }

    // Default value: everything after a depth-zero '='.
    size_t typeEnd = end;
    int depth = 0;
    for (size_t i = begin; i < end; i++) {
      if (opens(_tokens[i])) {
        depth++;
      } else if (closes(_tokens[i])) {
        depth--;
      } else if (depth == 0 && _tokens[i].isPunct('=')) {
        typeEnd = i;
        parameter.defaultValue =
            makeTypeRef(_tokens.begin() + i + 1, _tokens.begin() + end)
                .spelling;
        break;
      }
    }

    static const std::set<std::string> modifiers = {
        "inout", "borrowing", "consuming", "sending", "__owned", "__shared"};
    while (begin < typeEnd) {
      const Token& token = _tokens[begin];
      if (token.type == Token::Type::Space) {
        begin++;
      } else if (token.isFragment("attribute")) {
        parameter.attributes.push_back(consumeAttribute(begin, typeEnd));
      } else if (token.isFragment("keyword") && modifiers.count(token.text)) {
        parameter.modifier = token.text;
        begin++;
      } else {
        break;
      }
    }

    size_t last = typeEnd;
    while (last > begin && _tokens[last - 1].type == Token::Type::Space) {
      last--;
    }
    if (last > begin && _tokens[last - 1].type == Token::Type::Word &&
        _tokens[last - 1].text == "...") {
      parameter.isVariadic = true;
      last--;
    }

    parameter.type =
        makeTypeRef(_tokens.begin() + begin, _tokens.begin() + last);
    _symbol.parameters.push_back(std::move(parameter));
  }

  void parseEffects() {
    while (true) {
      skipSpaces();
      if (atEnd()) {
        return;
      }
      const Token& token = _tokens[_pos];
      if (token.isKeyword("async") || token.isKeyword("reasync")) {
        _symbol.isAsync = true;
        _pos++;
      } else if (token.isKeyword("throws")) {
        _symbol.isThrowing = true;
        _pos++;
        if (peekPunct('(')) {
          size_t start = _pos + 1;
          skipBalanced();
          _symbol.thrownType =
              makeTypeRef(_tokens.begin() + start, _tokens.begin() + _pos - 1);
        }
      } else if (token.isKeyword("rethrows")) {
        _symbol.isThrowing = true;
        _symbol.isRethrowing = true;
        _pos++;
      } else {
        return;
      }
    }
  }

  // `{ get }`, `{ get set }`, or no accessor block. A `var` without an
  // accessor block is stored and therefore settable.
  void parseAccessors(bool storedIfMissing) {
    skipSpaces();
    if (!peekPunct('{')) {
      _symbol.isSettable = storedIfMissing;
      return;
    }
    while (!atEnd() && !_tokens[_pos].isPunct('}')) {
      const Token& token = _tokens[_pos];
      if (token.isKeyword("set")) {
        _symbol.isSettable = true;
      } else if (token.isKeyword("async")) {
        _symbol.isAsync = true;
      } else if (token.isKeyword("throws")) {
        _symbol.isThrowing = true;
      }
      _pos++;
    }
  }

  const Tokens& _tokens;
  Symbol& _symbol;
  size_t _pos = 0;
  std::string _intro;
  bool _malformed = false;
};

// "scale(by:)" -> {"by"}, "describe(_:)" -> {""}, "x" -> none.
std::optional<std::vector<std::string>> labelsFromName(llvm::StringRef name) {
  size_t open = name.find('(');
  if (open == llvm::StringRef::npos || !name.endswith(")")) {
    return std::nullopt;
  }
  llvm::StringRef inner = name.slice(open + 1, name.size() - 1);
  std::vector<std::string> labels;
  while (!inner.empty()) {
    auto split = inner.split(':');
    labels.push_back(split.first == "_" ? "" : split.first.str());
    inner = split.second;
  }
  return labels;
}

SymbolKind kindFromIdentifier(llvm::StringRef identifier) {
  return llvm::StringSwitch<SymbolKind>(identifier)
      .Case("swift.class", SymbolKind::Class)
      .Case("swift.struct", SymbolKind::Struct)
      .Case("swift.enum", SymbolKind::Enum)
      .Case("swift.protocol", SymbolKind::Protocol)
      .Case("swift.enum.case", SymbolKind::EnumCase)
      .Case("swift.init", SymbolKind::Initializer)
      .Case("swift.deinit", SymbolKind::Deinitializer)
      .Case("swift.method", SymbolKind::InstanceMethod)
      .Case("swift.type.method", SymbolKind::TypeMethod)
      .Case("swift.func.op", SymbolKind::Operator)
      .Case("swift.property", SymbolKind::InstanceProperty)
      .Case("swift.type.property", SymbolKind::TypeProperty)
      .Case("swift.subscript", SymbolKind::InstanceSubscript)
      .Case("swift.type.subscript", SymbolKind::TypeSubscript)
      .Case("swift.func", SymbolKind::Function)
      .Case("swift.var", SymbolKind::Variable)
      .Case("swift.typealias", SymbolKind::TypeAlias)
      .Case("swift.associatedtype", SymbolKind::AssociatedType)
      .Case("swift.macro", SymbolKind::Macro)
      .Case("swift.extension", SymbolKind::Extension)
      .Default(SymbolKind::Unknown);
}

AccessLevel accessFromString(llvm::StringRef access) {
  return llvm::StringSwitch<AccessLevel>(access)
      .Case("private", AccessLevel::Private)
      .Case("fileprivate", AccessLevel::FilePrivate)
      .Case("internal", AccessLevel::Internal)
      .Case("package", AccessLevel::Package)
      .Case("public", AccessLevel::Public)
      .Case("open", AccessLevel::Open)
      .Default(AccessLevel::Unknown);
}

Fragments parseFragments(const Array* array) {
  Fragments fragments;
  if (!array) {
    return fragments;
  }
  for (const auto& value : *array) {
    const Object* object = value.getAsObject();
    if (!object) {
      continue;
    }
    fragments.push_back(Fragment{str(object, "kind"), str(object, "spelling"),
                                 str(object, "preciseIdentifier")});
  }
  return fragments;
}

std::vector<GenericConstraint> parseConstraints(const Array* array) {
  std::vector<GenericConstraint> constraints;
  if (!array) {
    return constraints;
  }
  for (const auto& value : *array) {
    const Object* object = value.getAsObject();
    if (!object) {
      continue;
    }
    constraints.push_back(
        GenericConstraint{str(object, "kind"), str(object, "lhs"),
                          str(object, "rhs"), str(object, "rhsPrecise")});
  }
  return constraints;
}

void parseAvailability(const Array* array, Symbol& symbol) {
  if (!array) {
    return;
  }
  for (const auto& value : *array) {
    const Object* object = value.getAsObject();
    if (!object) {
      continue;
    }
    Availability availability;
    availability.domain = str(object, "domain");
    availability.introduced = version(object->getObject("introduced"));
    availability.deprecated = version(object->getObject("deprecated"));
    availability.obsoleted = version(object->getObject("obsoleted"));
    availability.message = str(object, "message");
    availability.renamed = str(object, "renamed");
    availability.isUnconditionallyDeprecated =
        boolean(object, "isUnconditionallyDeprecated");
    availability.isUnconditionallyUnavailable =
        boolean(object, "isUnconditionallyUnavailable");
    symbol.availability.push_back(std::move(availability));
  }
}

std::optional<Symbol> parseSymbol(const Object& object,
                                  const std::string& graphName,
                                  std::vector<Diagnostic>& diagnostics) {
  Symbol symbol;
  symbol.usr = str(object.getObject("identifier"), "precise");
  symbol.preciseId = symbol.usr;
  if (symbol.preciseId.empty()) {
    report(diagnostics, Severity::Warning, "missing-field",
           "symbol without identifier.precise skipped", graphName);
    return std::nullopt;
  }

  symbol.kindIdentifier = str(object.getObject("kind"), "identifier");
  symbol.kind = kindFromIdentifier(symbol.kindIdentifier);
  if (symbol.kind == SymbolKind::Unknown) {
    report(diagnostics, Severity::Warning, "unknown-symbol-kind",
           "unrecognized symbol kind '" + symbol.kindIdentifier + "'",
           graphName, symbol.preciseId);
  }

  if (const Array* components = object.getArray("pathComponents")) {
    for (const auto& component : *components) {
      if (auto value = component.getAsString()) {
        symbol.pathComponents.push_back(value->str());
      }
    }
  }
  symbol.name = symbol.pathComponents.empty()
                    ? str(object.getObject("names"), "title")
                    : symbol.pathComponents.back();
  symbol.baseName = llvm::StringRef(symbol.name).split('(').first.str();
  symbol.access = accessFromString(str(&object, "accessLevel"));
  symbol.isSynthesized =
      llvm::StringRef(symbol.preciseId).contains("::SYNTHESIZED::");
  symbol.sourceGraph = graphName;

  symbol.declaration = parseFragments(object.getArray("declarationFragments"));
  for (const auto& fragment : symbol.declaration) {
    symbol.declarationText += fragment.spelling;
  }

  if (const Object* generics = object.getObject("swiftGenerics")) {
    if (const Array* parameters = generics->getArray("parameters")) {
      for (const auto& value : *parameters) {
        if (const Object* parameter = value.getAsObject()) {
          symbol.genericParameters.push_back(GenericParameter{
              str(parameter, "name"), integer(parameter, "depth"),
              integer(parameter, "index")});
        }
      }
    }
    symbol.genericConstraints =
        parseConstraints(generics->getArray("constraints"));
  }

  if (const Object* extension = object.getObject("swiftExtension")) {
    symbol.extension = SwiftExtensionInfo{
        str(extension, "extendedModule"), str(extension, "typeKind"),
        parseConstraints(extension->getArray("constraints"))};
  }

  parseAvailability(object.getArray("availability"), symbol);

  if (const Object* doc = object.getObject("docComment")) {
    if (const Array* lines = doc->getArray("lines")) {
      for (const auto& line : *lines) {
        if (!symbol.docComment.empty()) {
          symbol.docComment += '\n';
        }
        symbol.docComment += str(line.getAsObject(), "text");
      }
    }
  }

  if (const Object* location = object.getObject("location")) {
    const Object* position = location->getObject("position");
    symbol.location =
        SourceLocation{str(location, "uri"), integer(position, "line"),
                       integer(position, "character")};
  }

  Tokens tokens = tokenize(symbol.declaration);
  DeclarationParser parser(tokens, symbol);
  bool parsed = parser.parse();
  if (parser.intro() == "actor") {
    symbol.kind = SymbolKind::Actor;
  }
  if (!parsed || parser.malformed()) {
    report(diagnostics, Severity::Warning, "unparsed-declaration",
           "could not parse declaration '" + symbol.declarationText + "'",
           graphName, symbol.preciseId);
  }

  // The functionSignature return is cleaner than the declaration tail (no
  // trailing where-clause) and is present for every function-like symbol.
  if (const Object* signature = object.getObject("functionSignature")) {
    if (const Array* returns = signature->getArray("returns")) {
      Fragments fragments = parseFragments(returns);
      Tokens returnTokens = tokenize(fragments);
      TypeRef type = makeTypeRef(returnTokens.begin(), returnTokens.end());
      if (isVoid(type) || type.empty()) {
        symbol.returnType.reset();
      } else {
        symbol.returnType = type;
      }
    }
  }
  if (symbol.returnType && isVoid(*symbol.returnType)) {
    symbol.returnType.reset();
  }
  if (symbol.kind == SymbolKind::InstanceSubscript ||
      symbol.kind == SymbolKind::TypeSubscript) {
    symbol.valueType = symbol.returnType;
  }

  if (auto labels = labelsFromName(symbol.name)) {
    bool matches = labels->size() == symbol.parameters.size();
    for (size_t i = 0; matches && i < labels->size(); i++) {
      matches = (*labels)[i] == symbol.parameters[i].label;
    }
    if (!matches) {
      report(diagnostics, Severity::Warning, "parameter-label-mismatch",
             "parsed parameters of '" + symbol.declarationText +
                 "' do not match the symbol name '" + symbol.name + "'",
             graphName, symbol.preciseId);
    }
  }

  switch (symbol.kind) {
    case SymbolKind::TypeMethod:
    case SymbolKind::TypeProperty:
    case SymbolKind::TypeSubscript:
      symbol.isStatic = true;
      break;
    case SymbolKind::Operator:
      symbol.isStatic = std::count(symbol.modifiers.begin(),
                                   symbol.modifiers.end(), "static") > 0;
      break;
    default:
      break;
  }

  return symbol;
}

// Members and top-level declarations are listed in source order; synthesized
// symbols have no location and follow, ordered by USR.
void sortBySourceOrder(std::vector<std::string>& ids, const Module& module) {
  auto key = [&](const std::string& id) {
    const Symbol* symbol = module.find(id);
    if (!symbol || !symbol->location) {
      return std::make_tuple(1, std::string(), 0, 0, id);
    }
    return std::make_tuple(0, symbol->location->uri, symbol->location->line,
                           symbol->location->character, id);
  };
  std::sort(ids.begin(), ids.end(),
            [&](const std::string& a, const std::string& b) {
              return key(a) < key(b);
            });
  ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
}

void resolve(Module& module, std::vector<Diagnostic>& diagnostics) {
  std::sort(module.relationships.begin(), module.relationships.end(),
            [](const Relationship& a, const Relationship& b) {
              return std::tie(a.kind, a.source, a.target) <
                     std::tie(b.kind, b.source, b.target);
            });
  module.relationships.erase(
      std::unique(module.relationships.begin(), module.relationships.end(),
                  [](const Relationship& a, const Relationship& b) {
                    return std::tie(a.kind, a.source, a.target) ==
                           std::tie(b.kind, b.source, b.target);
                  }),
      module.relationships.end());

  auto rememberExternal = [&](const Relationship& relationship) {
    if (!module.find(relationship.target)) {
      module.externalNames[relationship.target] =
          relationship.targetFallback.empty() ? relationship.target
                                              : relationship.targetFallback;
    }
  };

  for (const auto& relationship : module.relationships) {
    const std::string& kind = relationship.kind;

    // A relationship names a USR, which every variant keyed by it shares
    // (see insertSymbol). Membership applies only to the variant declared
    // in the target type.
    std::vector<Symbol*> sources;
    const Symbol* target = module.find(relationship.target);
    bool isMembership = kind == "memberOf" || kind == "requirementOf" ||
                        kind == "optionalRequirementOf";
    for (auto it = module.symbols.lower_bound(relationship.source);
         it != module.symbols.end() &&
         llvm::StringRef(it->first).startswith(relationship.source);
         ++it) {
      Symbol& candidate = it->second;
      if (candidate.usr != relationship.source) {
        continue;
      }
      if (isMembership && target && !candidate.pathComponents.empty() &&
          !std::equal(target->pathComponents.begin(),
                      target->pathComponents.end(),
                      candidate.pathComponents.begin(),
                      candidate.pathComponents.end() - 1)) {
        continue;
      }
      sources.push_back(&candidate);
    }

    if (sources.empty()) {
      // Conformances this module's extensions add to external types
      // (`extension Array: DataProtocol where Element == UInt8`).
      if (kind == "conformsTo" || kind == "inheritsFrom") {
        ExternalType& external = module.externalTypes[relationship.source];
        external.preciseId = relationship.source;
        external.conformances.push_back(relationship.target);
        rememberExternal(relationship);
        continue;
      }
      report(diagnostics, Severity::Warning, "dangling-relationship",
             kind + " relationship from unknown symbol '" +
                 relationship.source + "'",
             module.name, relationship.source);
      continue;
    }

    for (Symbol* sourcePtr : sources) {
      Symbol& source = *sourcePtr;
      if (kind == "memberOf" || kind == "requirementOf" ||
          kind == "optionalRequirementOf") {
        source.parentId = relationship.target;
        if (!relationship.sourceOriginId.empty()) {
          source.sourceOriginId = relationship.sourceOriginId;
          source.sourceOriginName = relationship.sourceOriginName;
        }
        if (kind != "memberOf") {
          source.isProtocolRequirement = true;
          source.isOptionalRequirement = kind == "optionalRequirementOf";
        }

        auto targetIt = module.symbols.find(relationship.target);
        if (targetIt != module.symbols.end()) {
          targetIt->second.memberIds.push_back(source.preciseId);
          continue;
        }
        rememberExternal(relationship);
        ExternalType& external = module.externalTypes[relationship.target];
        external.preciseId = relationship.target;
        if (source.extension) {
          external.extendedModule = source.extension->extendedModule;
          external.typeKind = source.extension->typeKind;
        }
        external.memberIds.push_back(source.preciseId);
      } else if (kind == "conformsTo") {
        source.conformances.push_back(relationship.target);
        rememberExternal(relationship);
      } else if (kind == "inheritsFrom") {
        if (source.kind == SymbolKind::Protocol) {
          source.conformances.push_back(relationship.target);
        } else {
          source.superclassId = relationship.target;
        }
        rememberExternal(relationship);
      } else if (kind == "overrides") {
        source.overriddenId = relationship.target;
        rememberExternal(relationship);
      } else if (kind == "defaultImplementationOf") {
        source.defaultImplementationOf.push_back(relationship.target);
        rememberExternal(relationship);
      }
    }
  }

  for (auto& entry : module.symbols) {
    Symbol& symbol = entry.second;
    sortBySourceOrder(symbol.memberIds, module);
    std::sort(symbol.conformances.begin(), symbol.conformances.end());
    symbol.conformances.erase(
        std::unique(symbol.conformances.begin(), symbol.conformances.end()),
        symbol.conformances.end());
    std::sort(symbol.defaultImplementationOf.begin(),
              symbol.defaultImplementationOf.end());
    if (symbol.parentId.empty()) {
      module.topLevelIds.push_back(symbol.preciseId);
    }
  }
  for (auto& entry : module.externalTypes) {
    ExternalType& external = entry.second;
    sortBySourceOrder(external.memberIds, module);
    std::sort(external.conformances.begin(), external.conformances.end());
    external.conformances.erase(
        std::unique(external.conformances.begin(), external.conformances.end()),
        external.conformances.end());
    // Graphs name a relationship's target, never its source; an extended
    // type's name is only known when some relationship targets it.
    auto name = module.externalNames.find(external.preciseId);
    external.qualifiedName =
        name != module.externalNames.end() ? name->second : external.preciseId;
  }
  sortBySourceOrder(module.topLevelIds, module);
  std::sort(module.graphFiles.begin(), module.graphFiles.end());
}

// Structural scan of JSON text that locates object members and array
// elements without building a DOM. Whole SDK graphs run to hundreds of MB, and
// an llvm::json DOM of one costs tens of GB, so the loader skims the top level
// and parses each symbol and relationship on its own.
namespace JsonSkimmer {

size_t skipSpace(llvm::StringRef text, size_t i) {
  while (i < text.size() && llvm::isSpace(text[i])) {
    i++;
  }
  return i;
}

// Index one past the value starting at `i`, or npos.
size_t skipValue(llvm::StringRef text, size_t i) {
  if (i >= text.size()) {
    return llvm::StringRef::npos;
  }
  char c = text[i];
  if (c == '"') {
    for (i++; i < text.size(); i++) {
      if (text[i] == '\\') {
        i++;
      } else if (text[i] == '"') {
        return i + 1;
      }
    }
    return llvm::StringRef::npos;
  }
  if (c == '{' || c == '[') {
    int depth = 0;
    for (; i < text.size(); i++) {
      char d = text[i];
      if (d == '"') {
        size_t end = skipValue(text, i);
        if (end == llvm::StringRef::npos) {
          return end;
        }
        i = end - 1;
      } else if (d == '{' || d == '[') {
        depth++;
      } else if ((d == '}' || d == ']') && --depth == 0) {
        return i + 1;
      }
    }
    return llvm::StringRef::npos;
  }
  size_t start = i;
  while (i < text.size() && !llvm::isSpace(text[i]) &&
         !llvm::StringRef(",}]").contains(text[i])) {
    i++;
  }
  return i == start ? llvm::StringRef::npos : i;
}

bool fail(std::string& error, const char* what, size_t offset) {
  error = std::string(what) + " at offset " + std::to_string(offset);
  return false;
}

bool objectMembers(
    llvm::StringRef text,
    std::vector<std::pair<llvm::StringRef, llvm::StringRef>>& members,
    std::string& error) {
  size_t i = skipSpace(text, 0);
  if (i >= text.size() || text[i] != '{') {
    return fail(error, "expected '{'", i);
  }
  i = skipSpace(text, i + 1);
  if (i < text.size() && text[i] == '}') {
    i++;
  } else {
    while (true) {
      i = skipSpace(text, i);
      size_t keyEnd = skipValue(text, i);
      if (i >= text.size() || text[i] != '"' ||
          keyEnd == llvm::StringRef::npos) {
        return fail(error, "expected member name", i);
      }
      llvm::StringRef key = text.slice(i + 1, keyEnd - 1);
      i = skipSpace(text, keyEnd);
      if (i >= text.size() || text[i] != ':') {
        return fail(error, "expected ':'", i);
      }
      i = skipSpace(text, i + 1);
      size_t valueEnd = skipValue(text, i);
      if (valueEnd == llvm::StringRef::npos) {
        return fail(error, "malformed value", i);
      }
      members.emplace_back(key, text.slice(i, valueEnd));
      i = skipSpace(text, valueEnd);
      if (i < text.size() && text[i] == ',') {
        i++;
        continue;
      }
      if (i < text.size() && text[i] == '}') {
        i++;
        break;
      }
      return fail(error, "expected ',' or '}'", i);
    }
  }
  if (skipSpace(text, i) != text.size()) {
    return fail(error, "trailing content", i);
  }
  return true;
}

bool arrayElements(llvm::StringRef text,
                   llvm::function_ref<void(llvm::StringRef)> visit,
                   std::string& error) {
  size_t i = skipSpace(text, 0);
  if (i >= text.size() || text[i] != '[') {
    return fail(error, "expected '['", i);
  }
  i = skipSpace(text, i + 1);
  if (i < text.size() && text[i] == ']') {
    return true;
  }
  while (true) {
    i = skipSpace(text, i);
    size_t end = skipValue(text, i);
    if (end == llvm::StringRef::npos) {
      return fail(error, "malformed element", i);
    }
    visit(text.slice(i, end));
    i = skipSpace(text, end);
    if (i < text.size() && text[i] == ',') {
      i++;
      continue;
    }
    if (i < text.size() && text[i] == ']') {
      return true;
    }
    return fail(error, "expected ',' or ']'", i);
  }
}

}  // namespace JsonSkimmer

}  // namespace

std::vector<std::string> SymbolGraphLoader::findGraphFiles(
    const std::string& directory, std::vector<Diagnostic>& diagnostics) {
  std::vector<std::string> files;
  if (!fs::is_directory(directory)) {
    report(diagnostics, Severity::Error, "missing-directory",
           "symbol graph directory does not exist", directory);
    return files;
  }

  std::error_code ec;
  for (fs::recursive_directory_iterator it(directory, ec), end;
       it != end && !ec; it.increment(ec)) {
    if (it->type() != fs::file_type::regular_file) {
      continue;
    }
    if (isGraphFileName(path::filename(it->path()))) {
      files.push_back(it->path());
    }
  }
  if (ec) {
    report(diagnostics, Severity::Error, "unreadable-directory", ec.message(),
           directory);
  }
  std::sort(files.begin(), files.end());
  return files;
}

void SymbolGraphLoader::addFile(const std::string& filePath,
                                const std::string& displayName) {
  auto buffer = llvm::MemoryBuffer::getFile(filePath);
  if (!buffer) {
    report(_diagnostics, Severity::Error, "unreadable-file",
           buffer.getError().message(), displayName);
    return;
  }
  addBuffer((*buffer)->getBuffer(), displayName);
}

void SymbolGraphLoader::addBuffer(llvm::StringRef json,
                                  const std::string& displayName) {
  std::vector<std::pair<llvm::StringRef, llvm::StringRef>> members;
  std::string error;
  if (!JsonSkimmer::objectMembers(json, members, error)) {
    report(_diagnostics, Severity::Error, "invalid-json", error, displayName);
    return;
  }
  llvm::StringRef metadataText, moduleText, symbolsText, relationshipsText;
  for (const auto& member : members) {
    if (member.first == "metadata") {
      metadataText = member.second;
    } else if (member.first == "module") {
      moduleText = member.second;
    } else if (member.first == "symbols") {
      symbolsText = member.second;
    } else if (member.first == "relationships") {
      relationshipsText = member.second;
    }
  }

  auto parseSection =
      [&](llvm::StringRef text,
          llvm::StringRef name) -> std::optional<llvm::json::Value> {
    if (text.empty()) {
      return std::nullopt;
    }
    auto value = llvm::json::parse(text);
    if (!value) {
      report(_diagnostics, Severity::Error, "invalid-json",
             name.str() + ": " + llvm::toString(value.takeError()),
             displayName);
      return std::nullopt;
    }
    return std::move(*value);
  };

  auto metadataValue = parseSection(metadataText, "metadata");
  const Object* metadata =
      metadataValue ? metadataValue->getAsObject() : nullptr;
  auto format =
      version(metadata ? metadata->getObject("formatVersion") : nullptr);
  if (!format) {
    report(_diagnostics, Severity::Error, "missing-field",
           "metadata.formatVersion is missing", displayName);
    return;
  }
  if (format->major != kSupportedFormatMajor) {
    report(_diagnostics, Severity::Error, "unsupported-format-version",
           "symbol graph format " + std::to_string(format->major) + "." +
               std::to_string(format->minor) + " is not supported",
           displayName);
    return;
  }
  if (format->minor > kNewestKnownFormatMinor) {
    report(_diagnostics, Severity::Warning, "newer-format-version",
           "symbol graph format 0." + std::to_string(format->minor) +
               " is newer than the newest validated format 0." +
               std::to_string(kNewestKnownFormatMinor),
           displayName);
  }

  auto moduleValue = parseSection(moduleText, "module");
  const Object* moduleObject =
      moduleValue ? moduleValue->getAsObject() : nullptr;
  std::string moduleName = str(moduleObject, "name");
  if (moduleName.empty()) {
    report(_diagnostics, Severity::Error, "missing-field",
           "module.name is missing", displayName);
    return;
  }

  Module& module = _modules[moduleName];
  if (module.name.empty()) {
    module.name = moduleName;
    module.formatVersion = *format;
    module.generator = str(metadata, "generator");
    if (const Object* platform = moduleObject->getObject("platform")) {
      module.platform.architecture = str(platform, "architecture");
      module.platform.vendor = str(platform, "vendor");
      module.platform.environment = str(platform, "environment");
      if (const Object* os = platform->getObject("operatingSystem")) {
        module.platform.operatingSystem = str(os, "name");
        module.platform.minimumVersion =
            version(os->getObject("minimumVersion"));
      }
    }
  } else if (std::tie(module.formatVersion.major, module.formatVersion.minor) !=
             std::tie(format->major, format->minor)) {
    report(_diagnostics, Severity::Warning, "mixed-format-versions",
           "graph files of module '" + moduleName +
               "' use different format versions",
           displayName);
  }
  module.graphFiles.push_back(displayName);

  // Elements are parsed one at a time; see JsonSkimmer.
  auto forEachObject = [&](llvm::StringRef arrayText, llvm::StringRef name,
                           llvm::function_ref<void(const Object&)> visit) {
    if (arrayText.empty()) {
      return;
    }
    std::string arrayError;
    bool ok = JsonSkimmer::arrayElements(
        arrayText,
        [&](llvm::StringRef element) {
          auto value = llvm::json::parse(element);
          if (!value) {
            report(_diagnostics, Severity::Error, "invalid-json",
                   name.str() + ": " + llvm::toString(value.takeError()),
                   displayName);
            return;
          }
          if (const Object* object = value->getAsObject()) {
            visit(*object);
          }
        },
        arrayError);
    if (!ok) {
      report(_diagnostics, Severity::Error, "invalid-json",
             name.str() + ": " + arrayError, displayName);
    }
  };

  // `<Declaring>@<Extended>.symbols.json`: graphs of cross-import overlays
  // carry the overlay's name only in the file name.
  std::string declaringModule = llvm::StringRef(path::filename(displayName))
                                    .split('@')
                                    .first.split('.')
                                    .first.str();
  if (declaringModule == moduleName) {
    declaringModule.clear();
  }

  forEachObject(symbolsText, "symbols", [&](const Object& object) {
    auto symbol = parseSymbol(object, displayName, _diagnostics);
    if (symbol) {
      symbol->declaringModule = declaringModule;
      insertSymbol(module, std::move(*symbol), displayName);
    }
  });

  forEachObject(relationshipsText, "relationships", [&](const Object& object) {
    const Object* origin = object.getObject("sourceOrigin");
    module.relationships.push_back(
        Relationship{str(&object, "kind"), str(&object, "source"),
                     str(&object, "target"), str(&object, "targetFallback"),
                     str(origin, "identifier"), str(origin, "displayName")});
  });
}

void SymbolGraphLoader::insertSymbol(Module& module, Symbol symbol,
                                     const std::string& displayName) {
  auto existing = module.symbols.find(symbol.preciseId);
  if (existing == module.symbols.end()) {
    std::string id = symbol.preciseId;
    module.symbols.emplace(std::move(id), std::move(symbol));
    return;
  }
  Symbol& other = existing->second;
  if (other.declarationText == symbol.declarationText &&
      other.pathComponents == symbol.pathComponents) {
    return;
  }
  auto ownerOf = [](const Symbol& s) {
    return std::vector<std::string>(s.pathComponents.begin(),
                                    s.pathComponents.empty()
                                        ? s.pathComponents.end()
                                        : s.pathComponents.end() - 1);
  };
  if (ownerOf(other) != ownerOf(symbol)) {
    // An Objective-C method redeclared by a subclass (NSMutableArray's
    // settable subscript) keeps the superclass method's USR. The variant
    // whose path sorts first keeps the plain USR; others are keyed by owner.
    if (symbol.pathComponents < other.pathComponents) {
      std::swap(other, symbol);
    }
    symbol.preciseId = symbol.usr + "#" + llvm::join(ownerOf(symbol), ".");
    if (!module.symbols.count(symbol.preciseId)) {
      std::string id = symbol.preciseId;
      module.symbols.emplace(std::move(id), std::move(symbol));
    }
    return;
  }
  if (other.isAsync != symbol.isAsync) {
    // Swift imports an Objective-C completion-handler method twice, as the
    // original and as an `async` variant, under the same USR. Keep both; the
    // original keeps the plain USR.
    if (!symbol.isAsync) {
      std::swap(other, symbol);
    }
    symbol.preciseId = symbol.usr + "#async";
    if (!module.symbols.count(symbol.preciseId)) {
      std::string id = symbol.preciseId;
      module.symbols.emplace(std::move(id), std::move(symbol));
    }
    return;
  }
  report(_diagnostics, Severity::Warning, "duplicate-symbol",
         "symbol declared differently in '" + other.sourceGraph + "' and '" +
             displayName + "'; keeping the first",
         displayName, symbol.preciseId);
}

ModuleSet SymbolGraphLoader::finish() {
  ModuleSet result;
  for (auto& entry : _modules) {
    resolve(entry.second, _diagnostics);
    for (auto& symbol : entry.second.symbols) {
      symbol.second.module = entry.second.name;
    }
  }
  result.modules = std::move(_modules);
  result.diagnostics = std::move(_diagnostics);
  return result;
}

ModuleSet loadSymbolGraphDirectory(const std::string& directory) {
  return loadSymbolGraphDirectories({directory});
}

ModuleSet loadSymbolGraphDirectories(
    const std::vector<std::string>& directories) {
  std::vector<Diagnostic> diagnostics;
  SymbolGraphLoader loader;
  for (const auto& directory : directories) {
    auto files = SymbolGraphLoader::findGraphFiles(directory, diagnostics);
    for (const auto& file : files) {
      llvm::StringRef relative = file;
      relative.consume_front(directory);
      relative = relative.ltrim('/');
      loader.addFile(file, relative.str());
    }
  }
  ModuleSet result = loader.finish();
  result.diagnostics.insert(result.diagnostics.begin(), diagnostics.begin(),
                            diagnostics.end());
  return result;
}

Module mergeUnit(ModuleSet& set, const std::string& name,
                 const std::map<std::string, std::string>& reexports) {
  Module unit;
  unit.name = name;
  for (auto& entry : set.modules) {
    Module& module = entry.second;
    if (unit.unitModules.empty()) {
      unit.platform = module.platform;
      unit.formatVersion = module.formatVersion;
      unit.generator = module.generator;
    }
    auto reexport = reexports.find(module.name);
    std::string owner =
        reexport == reexports.end() ? module.name : reexport->second;
    if (std::find(unit.unitModules.begin(), unit.unitModules.end(), owner) ==
        unit.unitModules.end()) {
      unit.unitModules.push_back(owner);
    }
    if (owner != module.name) {
      for (auto& symbol : module.symbols) {
        symbol.second.module = owner;
      }
    }
    unit.graphFiles.insert(unit.graphFiles.end(), module.graphFiles.begin(),
                           module.graphFiles.end());
    for (auto& symbol : module.symbols) {
      unit.symbols.emplace(symbol.first, std::move(symbol.second));
    }
    for (auto& external : module.externalNames) {
      unit.externalNames.insert(external);
    }
    unit.relationships.insert(unit.relationships.end(),
                              module.relationships.begin(),
                              module.relationships.end());
    unit.topLevelIds.insert(unit.topLevelIds.end(), module.topLevelIds.begin(),
                            module.topLevelIds.end());
  }
  // Extensions of a type another module of the unit declares.
  for (auto& entry : set.modules) {
    for (auto& external : entry.second.externalTypes) {
      auto target = unit.symbols.find(external.first);
      if (target == unit.symbols.end()) {
        ExternalType& kept = unit.externalTypes[external.first];
        if (kept.preciseId.empty()) {
          kept = external.second;
        } else {
          kept.memberIds.insert(kept.memberIds.end(),
                                external.second.memberIds.begin(),
                                external.second.memberIds.end());
          kept.conformances.insert(kept.conformances.end(),
                                   external.second.conformances.begin(),
                                   external.second.conformances.end());
        }
        continue;
      }
      Symbol& type = target->second;
      for (const auto& id : external.second.memberIds) {
        if (std::find(type.memberIds.begin(), type.memberIds.end(), id) ==
            type.memberIds.end()) {
          type.memberIds.push_back(id);
        }
      }
      for (const auto& id : external.second.conformances) {
        if (std::find(type.conformances.begin(), type.conformances.end(), id) ==
            type.conformances.end()) {
          type.conformances.push_back(id);
        }
      }
    }
  }
  for (const auto& id : unit.symbols) {
    unit.externalNames.erase(id.first);
  }
  set.modules.clear();
  return unit;
}

}  // namespace Swift
