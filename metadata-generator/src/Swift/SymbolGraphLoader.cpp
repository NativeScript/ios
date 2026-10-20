#include "SymbolGraphLoader.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/ADT/StringSwitch.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>

#include <algorithm>
#include <set>
#include <tuple>

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
//
// Symbol graphs carry most semantics (effects, settability, labels, failable
// initializers, actor-ness) only inside `declarationFragments`, where
// structural punctuation is mixed into "text" fragments (e.g. "?) -> ").
// Text fragments are therefore split into single structural tokens before
// parsing.

struct Token {
  enum class Type { Fragment, Punct, Space, Word, Arrow };
  Type type;
  // Fragment kind for Fragment tokens, "text" otherwise.
  std::string kind;
  std::string text;
  std::string precise;

  bool isPunct(char c) const {
    return type == Type::Punct && text.size() == 1 && text[0] == c;
  }
  bool isFragment(llvm::StringRef fragmentKind) const {
    return type == Type::Fragment && kind == fragmentKind;
  }
  bool isKeyword(llvm::StringRef keyword) const {
    return isFragment("keyword") && text == keyword;
  }
};

using Tokens = std::vector<Token>;

Tokens tokenize(const Fragments& fragments) {
  Tokens tokens;
  for (const auto& fragment : fragments) {
    // Custom attributes (global actors, property wrappers) arrive as an "@"
    // fragment followed by the attribute type's name.
    if (fragment.kind == "attribute" && !tokens.empty() &&
        tokens.back().isFragment("attribute") && tokens.back().text == "@") {
      tokens.back().text += fragment.spelling;
      tokens.back().precise = fragment.preciseIdentifier;
      continue;
    }
    if (fragment.kind != "text") {
      tokens.push_back(Token{Token::Type::Fragment, fragment.kind,
                             fragment.spelling, fragment.preciseIdentifier});
      continue;
    }

    llvm::StringRef text = fragment.spelling;
    // Attributes with arguments (e.g. "@backDeployed(before: iOS 17.0)\n") are
    // emitted as plain text rather than as attribute fragments.
    if (text.ltrim().startswith("@")) {
      tokens.push_back(
          Token{Token::Type::Fragment, "attribute", text.trim().str(), ""});
      continue;
    }

    size_t i = 0;
    while (i < text.size()) {
      char c = text[i];
      if (llvm::isSpace(c)) {
        size_t end = i;
        while (end < text.size() && llvm::isSpace(text[end])) {
          end++;
        }
        tokens.push_back(
            Token{Token::Type::Space, "text", text.slice(i, end).str(), ""});
        i = end;
      } else if (text.substr(i).startswith("->")) {
        tokens.push_back(Token{Token::Type::Arrow, "text", "->", ""});
        i += 2;
      } else if (llvm::StringRef("()[]<>,:?!={}&").contains(c)) {
        tokens.push_back(
            Token{Token::Type::Punct, "text", std::string(1, c), ""});
        i++;
      } else {
        size_t end = i;
        while (end < text.size() && !llvm::isSpace(text[end]) &&
               !llvm::StringRef("()[]<>,:?!={}&").contains(text[end]) &&
               !text.substr(end).startswith("->")) {
          end++;
        }
        tokens.push_back(
            Token{Token::Type::Word, "text", text.slice(i, end).str(), ""});
        i = end;
      }
    }
  }
  return tokens;
}

bool opens(const Token& token) {
  return token.isPunct('(') || token.isPunct('[') || token.isPunct('<');
}

bool closes(const Token& token) {
  return token.isPunct(')') || token.isPunct(']') || token.isPunct('>');
}

TypeRef makeTypeRef(Tokens::const_iterator begin, Tokens::const_iterator end) {
  while (begin != end && begin->type == Token::Type::Space) {
    ++begin;
  }
  while (end != begin && std::prev(end)->type == Token::Type::Space) {
    --end;
  }

  TypeRef type;
  for (auto it = begin; it != end; ++it) {
    type.spelling += it->text;
    if (it->type == Token::Type::Fragment) {
      type.fragments.push_back(Fragment{it->kind, it->text, it->precise});
    } else if (!type.fragments.empty() &&
               type.fragments.back().kind == "text") {
      type.fragments.back().spelling += it->text;
    } else {
      type.fragments.push_back(Fragment{"text", it->text, ""});
    }
  }
  return type;
}

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
        _symbol.attributes.push_back(llvm::StringRef(token.text).trim().str());
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
    bool hasExternal = false;
    if (_tokens[begin].isFragment("externalParam")) {
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
        parameter.attributes.push_back(
            llvm::StringRef(token.text).trim().str());
        begin++;
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
      if (_tokens[_pos].isKeyword("set")) {
        _symbol.isSettable = true;
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
  symbol.preciseId = str(object.getObject("identifier"), "precise");
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
        symbol.docComment.push_back(str(line.getAsObject(), "text"));
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
    auto sourceIt = module.symbols.find(relationship.source);
    if (sourceIt == module.symbols.end()) {
      report(diagnostics, Severity::Warning, "dangling-relationship",
             relationship.kind + " relationship from unknown symbol '" +
                 relationship.source + "'",
             module.name, relationship.source);
      continue;
    }
    Symbol& source = sourceIt->second;
    const std::string& kind = relationship.kind;

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
      external.qualifiedName = module.externalNames[relationship.target];
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
    sortBySourceOrder(entry.second.memberIds, module);
  }
  sortBySourceOrder(module.topLevelIds, module);
  std::sort(module.graphFiles.begin(), module.graphFiles.end());
}

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
  auto parsed = llvm::json::parse(json);
  if (!parsed) {
    report(_diagnostics, Severity::Error, "invalid-json",
           llvm::toString(parsed.takeError()), displayName);
    return;
  }
  const Object* root = parsed->getAsObject();
  if (!root) {
    report(_diagnostics, Severity::Error, "invalid-json",
           "symbol graph root is not an object", displayName);
    return;
  }

  const Object* metadata = root->getObject("metadata");
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

  const Object* moduleObject = root->getObject("module");
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

  if (const Array* symbols = root->getArray("symbols")) {
    for (const auto& value : *symbols) {
      const Object* object = value.getAsObject();
      if (!object) {
        continue;
      }
      auto symbol = parseSymbol(*object, displayName, _diagnostics);
      if (!symbol) {
        continue;
      }
      auto existing = module.symbols.find(symbol->preciseId);
      if (existing != module.symbols.end()) {
        if (existing->second.declarationText != symbol->declarationText) {
          report(_diagnostics, Severity::Warning, "duplicate-symbol",
                 "symbol declared differently in '" +
                     existing->second.sourceGraph + "' and '" + displayName +
                     "'; keeping the first",
                 displayName, symbol->preciseId);
        }
        continue;
      }
      std::string id = symbol->preciseId;
      module.symbols.emplace(std::move(id), std::move(*symbol));
    }
  }

  if (const Array* relationships = root->getArray("relationships")) {
    for (const auto& value : *relationships) {
      const Object* object = value.getAsObject();
      if (!object) {
        continue;
      }
      const Object* origin = object->getObject("sourceOrigin");
      module.relationships.push_back(
          Relationship{str(object, "kind"), str(object, "source"),
                       str(object, "target"), str(object, "targetFallback"),
                       str(origin, "identifier"), str(origin, "displayName")});
    }
  }
}

ModuleSet SymbolGraphLoader::finish() {
  ModuleSet result;
  for (auto& entry : _modules) {
    resolve(entry.second, _diagnostics);
  }
  result.modules = std::move(_modules);
  result.diagnostics = std::move(_diagnostics);
  return result;
}

ModuleSet loadSymbolGraphDirectory(const std::string& directory) {
  std::vector<Diagnostic> diagnostics;
  auto files = SymbolGraphLoader::findGraphFiles(directory, diagnostics);

  SymbolGraphLoader loader;
  for (const auto& file : files) {
    llvm::StringRef relative = file;
    relative.consume_front(directory);
    relative = relative.ltrim('/');
    loader.addFile(file, relative.str());
  }
  ModuleSet result = loader.finish();
  result.diagnostics.insert(result.diagnostics.begin(), diagnostics.begin(),
                            diagnostics.end());
  return result;
}

}  // namespace Swift
