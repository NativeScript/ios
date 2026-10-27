#include "SwiftTypes.h"

#include <llvm/ADT/StringExtras.h>

#include "FragmentTokens.h"

namespace Swift {

using namespace FragmentTokens;

const std::string& TypeNode::usr() const {
  static const std::string empty;
  return components.empty() ? empty : components.back().usr;
}

bool TypeNode::hasAttribute(const std::string& attribute) const {
  for (const auto& candidate : attributes) {
    if (candidate == attribute) {
      return true;
    }
  }
  return false;
}

const char* toString(TypeNode::Kind kind) {
  switch (kind) {
    case TypeNode::Kind::Nominal:
      return "nominal";
    case TypeNode::Kind::GenericParameter:
      return "genericParameter";
    case TypeNode::Kind::Optional:
      return "optional";
    case TypeNode::Kind::ImplicitlyUnwrappedOptional:
      return "implicitlyUnwrappedOptional";
    case TypeNode::Kind::Array:
      return "array";
    case TypeNode::Kind::Dictionary:
      return "dictionary";
    case TypeNode::Kind::Tuple:
      return "tuple";
    case TypeNode::Kind::Function:
      return "function";
    case TypeNode::Kind::Metatype:
      return "metatype";
    case TypeNode::Kind::Existential:
      return "existential";
    case TypeNode::Kind::Opaque:
      return "opaque";
    case TypeNode::Kind::Composition:
      return "composition";
    case TypeNode::Kind::Void:
      return "void";
    case TypeNode::Kind::Unknown:
      return "unknown";
  }
  return "unknown";
}

namespace {

bool isWord(const Token& token, llvm::StringRef word) {
  return (token.type == Token::Type::Word || token.isFragment("keyword")) &&
         token.text == word;
}

bool isName(const Token& token) {
  return token.isFragment("typeIdentifier") ||
         token.isFragment("genericParameter") ||
         token.isFragment("identifier") ||
         (token.isFragment("keyword") &&
          (token.text == "Self" || token.text == "Any" ||
           token.text == "AnyObject")) ||
         (token.type == Token::Type::Word && !token.text.empty() &&
          (llvm::isAlpha(token.text[0]) || token.text[0] == '_'));
}

class TypeParser {
 public:
  TypeParser(const Tokens& tokens, const std::set<std::string>& genericNames)
      : _tokens(tokens), _genericNames(genericNames) {}

  TypeNode parse(bool* complete) {
    TypeNode node = parseType();
    skipSpaces();
    if (complete) {
      *complete = !_failed && atEnd();
    }
    return node;
  }

 private:
  bool atEnd() const { return _pos >= _tokens.size(); }
  const Token& peek() const { return _tokens[_pos]; }

  void skipSpaces() {
    while (!atEnd() && peek().type == Token::Type::Space) {
      _pos++;
    }
  }

  bool acceptPunct(char c) {
    skipSpaces();
    if (!atEnd() && peek().isPunct(c)) {
      _pos++;
      return true;
    }
    return false;
  }

  TypeNode unknown(std::string text) {
    _failed = true;
    TypeNode node;
    node.kind = TypeNode::Kind::Unknown;
    node.text = std::move(text);
    return node;
  }

  std::string consumeAttribute() {
    std::string attribute = peek().text;
    bool abuts = !attribute.empty() && !llvm::isSpace(attribute.back());
    attribute = llvm::StringRef(attribute).trim().str();
    _pos++;
    if (abuts && !atEnd() && peek().isPunct('(')) {
      int depth = 0;
      while (!atEnd()) {
        const Token& token = _tokens[_pos++];
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

  TypeNode parseType() {
    std::vector<std::string> attributes;
    std::vector<std::string> modifiers;
    while (true) {
      skipSpaces();
      if (atEnd()) {
        break;
      }
      const Token& token = peek();
      if (token.isFragment("attribute") ||
          (token.isFragment("keyword") &&
           llvm::StringRef(token.text).startswith("nonisolated")) ||
          isWord(token, "nonisolated")) {
        // `nonisolated(nonsending)` qualifies closure types like an attribute.
        attributes.push_back(consumeAttribute());
      } else if (isWord(token, "inout") || isWord(token, "borrowing") ||
                 isWord(token, "consuming") || isWord(token, "sending") ||
                 isWord(token, "__owned") || isWord(token, "__shared") ||
                 isWord(token, "isolated") || isWord(token, "repeat") ||
                 isWord(token, "each")) {
        modifiers.push_back(token.text);
        _pos++;
      } else {
        break;
      }
    }

    TypeNode node;
    skipSpaces();
    if (!atEnd() && (isWord(peek(), "some") || isWord(peek(), "any"))) {
      bool opaque = peek().text == "some";
      _pos++;
      node.kind = opaque ? TypeNode::Kind::Opaque : TypeNode::Kind::Existential;
      node.children.push_back(parseComposition());
    } else {
      node = parseComposition();
    }

    node.attributes.insert(node.attributes.begin(), attributes.begin(),
                           attributes.end());
    if (!modifiers.empty()) {
      node.modifier = llvm::join(modifiers, " ");
    }
    if (llvm::StringRef(node.modifier).contains("each")) {
      // Parameter packs are not modeled.
      _failed = true;
    }
    return node;
  }

  TypeNode parseComposition() {
    TypeNode first = parsePostfix(parsePrimary());
    if (!acceptPunct('&')) {
      return first;
    }
    TypeNode composition;
    composition.kind = TypeNode::Kind::Composition;
    composition.children.push_back(std::move(first));
    do {
      composition.children.push_back(parsePostfix(parsePrimary()));
    } while (acceptPunct('&'));
    return composition;
  }

  TypeNode parsePostfix(TypeNode node) {
    while (true) {
      if (atEnd()) {
        return node;
      }
      const Token& token = peek();
      if (token.isPunct('?') || token.isPunct('!')) {
        TypeNode wrapper;
        wrapper.kind = token.isPunct('?')
                           ? TypeNode::Kind::Optional
                           : TypeNode::Kind::ImplicitlyUnwrappedOptional;
        wrapper.children.push_back(std::move(node));
        node = std::move(wrapper);
        _pos++;
      } else if (token.type == Token::Type::Word &&
                 (token.text == ".Type" || token.text == ".Protocol")) {
        TypeNode wrapper;
        wrapper.kind = TypeNode::Kind::Metatype;
        wrapper.text = token.text.substr(1);
        wrapper.children.push_back(std::move(node));
        node = std::move(wrapper);
        _pos++;
      } else {
        return node;
      }
    }
  }

  // Parses `(`-delimited elements; the opening parenthesis is consumed.
  std::vector<TypeNode> parseParenthesized(std::vector<std::string>& labels,
                                           bool& anyLabel) {
    std::vector<TypeNode> elements;
    anyLabel = false;
    skipSpaces();
    if (acceptPunct(')')) {
      return elements;
    }
    while (true) {
      skipSpaces();
      std::string label;
      // `label: Type` inside tuples (and argument-labeled closure types).
      if (!atEnd() && _pos + 1 < _tokens.size() &&
          (peek().type == Token::Type::Word ||
           peek().isFragment("identifier") ||
           peek().isFragment("externalParam") ||
           peek().isFragment("internalParam"))) {
        size_t lookahead = _pos + 1;
        while (lookahead < _tokens.size() &&
               _tokens[lookahead].type == Token::Type::Space) {
          lookahead++;
        }
        if (lookahead < _tokens.size() && _tokens[lookahead].isPunct(':')) {
          label = peek().text;
          anyLabel = true;
          _pos = lookahead + 1;
        }
      }
      labels.push_back(label);
      elements.push_back(parseType());
      if (acceptPunct(',')) {
        continue;
      }
      if (acceptPunct(')')) {
        return elements;
      }
      _failed = true;
      return elements;
    }
  }

  TypeNode parsePrimary() {
    skipSpaces();
    if (atEnd()) {
      return unknown("");
    }
    const Token& token = peek();

    if (token.isPunct('(')) {
      _pos++;
      std::vector<std::string> labels;
      bool anyLabel = false;
      std::vector<TypeNode> elements = parseParenthesized(labels, anyLabel);

      skipSpaces();
      bool isFunction =
          !atEnd() &&
          (isWord(peek(), "async") || isWord(peek(), "throws") ||
           isWord(peek(), "rethrows") || peek().type == Token::Type::Arrow);
      if (isFunction) {
        TypeNode function;
        function.kind = TypeNode::Kind::Function;
        function.children = std::move(elements);
        while (true) {
          skipSpaces();
          if (atEnd()) {
            break;
          }
          if (isWord(peek(), "async")) {
            function.isAsync = true;
            _pos++;
          } else if (isWord(peek(), "throws") || isWord(peek(), "rethrows")) {
            function.isThrowing = true;
            _pos++;
            if (!atEnd() && peek().isPunct('(')) {
              _pos++;
              function.thrownType.push_back(parseType());
              if (!acceptPunct(')')) {
                _failed = true;
              }
            }
          } else {
            break;
          }
        }
        skipSpaces();
        if (atEnd() || peek().type != Token::Type::Arrow) {
          _failed = true;
          return function;
        }
        _pos++;
        function.result.push_back(parseType());
        return function;
      }

      if (elements.empty()) {
        TypeNode voidNode;
        voidNode.kind = TypeNode::Kind::Void;
        return voidNode;
      }
      if (elements.size() == 1 && !anyLabel) {
        return std::move(elements.front());
      }
      TypeNode tuple;
      tuple.kind = TypeNode::Kind::Tuple;
      tuple.children = std::move(elements);
      tuple.labels = std::move(labels);
      return tuple;
    }

    if (token.isPunct('[')) {
      _pos++;
      TypeNode key = parseType();
      TypeNode node;
      if (acceptPunct(':')) {
        node.kind = TypeNode::Kind::Dictionary;
        node.children.push_back(std::move(key));
        node.children.push_back(parseType());
      } else {
        node.kind = TypeNode::Kind::Array;
        node.children.push_back(std::move(key));
      }
      if (!acceptPunct(']')) {
        _failed = true;
      }
      return node;
    }

    if (isName(token)) {
      return parseNominal();
    }

    _pos++;
    return unknown(token.text);
  }

  TypeNode parseNominal() {
    TypeNode node;
    node.kind = TypeNode::Kind::Nominal;
    while (true) {
      const Token& token = peek();
      TypeNode::Component component;
      component.name = token.text;
      component.usr = token.precise;
      _pos++;
      if (!atEnd() && peek().isPunct('<')) {
        _pos++;
        do {
          component.arguments.push_back(parseType());
        } while (acceptPunct(','));
        if (!acceptPunct('>')) {
          _failed = true;
        }
      }
      node.components.push_back(std::move(component));

      if (atEnd() || peek().type != Token::Type::Word) {
        break;
      }
      llvm::StringRef word = peek().text;
      if (word == ".") {
        // `Outer` "." `Inner`, the inner name being its own fragment.
        if (_pos + 1 < _tokens.size() && isName(_tokens[_pos + 1])) {
          _pos++;
          continue;
        }
        break;
      }
      if (word.startswith(".") && word != ".Type" && word != ".Protocol" &&
          word.size() > 1 && (llvm::isAlpha(word[1]) || word[1] == '_')) {
        // `Outer.Inner` written as one text run after the outer name.
        for (llvm::StringRef rest = word.drop_front(); !rest.empty();) {
          auto split = rest.split('.');
          node.components.push_back(
              TypeNode::Component{split.first.str(), "", {}});
          rest = split.second;
        }
        _pos++;
      }
      break;
    }
    return normalize(std::move(node));
  }

  TypeNode normalize(TypeNode node) {
    const std::string& first = node.components.front().name;
    if (first == "Self" || _genericNames.count(first)) {
      node.kind = TypeNode::Kind::GenericParameter;
      return node;
    }
    if (node.components.size() != 1) {
      return node;
    }
    TypeNode::Component& component = node.components.front();
    auto wrap = [&](TypeNode::Kind kind, size_t arity) -> TypeNode {
      if (component.arguments.size() != arity) {
        return node;
      }
      TypeNode wrapper;
      wrapper.kind = kind;
      wrapper.children = std::move(component.arguments);
      return wrapper;
    };
    const std::string& usr = component.usr;
    if (usr == KnownTypes::kOptional) {
      return wrap(TypeNode::Kind::Optional, 1);
    }
    if (usr == KnownTypes::kArray) {
      return wrap(TypeNode::Kind::Array, 1);
    }
    if (usr == KnownTypes::kDictionary) {
      return wrap(TypeNode::Kind::Dictionary, 2);
    }
    if (usr == KnownTypes::kVoid || (usr.empty() && component.name == "Void")) {
      TypeNode voidNode;
      voidNode.kind = TypeNode::Kind::Void;
      return voidNode;
    }
    if (component.name == "Any" || component.name == "AnyObject") {
      TypeNode existential;
      existential.kind = TypeNode::Kind::Existential;
      existential.children.push_back(std::move(node));
      return existential;
    }
    return node;
  }

  const Tokens& _tokens;
  const std::set<std::string>& _genericNames;
  size_t _pos = 0;
  bool _failed = false;
};

std::string spellComponents(const TypeNode& node) {
  std::string out;
  for (size_t i = 0; i < node.components.size(); i++) {
    const auto& component = node.components[i];
    if (i > 0) {
      out += ".";
    }
    out += component.name;
    if (!component.arguments.empty()) {
      out += "<";
      for (size_t j = 0; j < component.arguments.size(); j++) {
        if (j > 0) {
          out += ", ";
        }
        out += spelling(component.arguments[j]);
      }
      out += ">";
    }
  }
  return out;
}

// Postfix operators bind tighter than function arrows and compositions.
std::string spellOperand(const TypeNode& node) {
  std::string text = spelling(node);
  bool needsParens = node.kind == TypeNode::Kind::Function ||
                     node.kind == TypeNode::Kind::Composition ||
                     node.kind == TypeNode::Kind::Existential ||
                     node.kind == TypeNode::Kind::Opaque;
  return needsParens ? "(" + text + ")" : text;
}

}  // namespace

TypeNode parseType(const TypeRef& type,
                   const std::set<std::string>& genericNames, bool* complete) {
  Tokens tokens = tokenize(type.fragments);
  TypeParser parser(tokens, genericNames);
  return parser.parse(complete);
}

std::string spelling(const TypeNode& node) {
  std::string prefix;
  for (const auto& attribute : node.attributes) {
    prefix += attribute + " ";
  }
  if (!node.modifier.empty()) {
    prefix += node.modifier + " ";
  }

  std::string body;
  switch (node.kind) {
    case TypeNode::Kind::Nominal:
    case TypeNode::Kind::GenericParameter:
      body = spellComponents(node);
      break;
    case TypeNode::Kind::Optional:
      body = spellOperand(node.children[0]) + "?";
      break;
    case TypeNode::Kind::ImplicitlyUnwrappedOptional:
      body = spellOperand(node.children[0]) + "!";
      break;
    case TypeNode::Kind::Array:
      body = "[" + spelling(node.children[0]) + "]";
      break;
    case TypeNode::Kind::Dictionary:
      body = "[" + spelling(node.children[0]) + ": " +
             spelling(node.children[1]) + "]";
      break;
    case TypeNode::Kind::Tuple: {
      body = "(";
      for (size_t i = 0; i < node.children.size(); i++) {
        if (i > 0) {
          body += ", ";
        }
        if (i < node.labels.size() && !node.labels[i].empty()) {
          body += node.labels[i] + ": ";
        }
        body += spelling(node.children[i]);
      }
      body += ")";
      break;
    }
    case TypeNode::Kind::Function: {
      body = "(";
      for (size_t i = 0; i < node.children.size(); i++) {
        if (i > 0) {
          body += ", ";
        }
        body += spelling(node.children[i]);
      }
      body += ")";
      if (node.isAsync) {
        body += " async";
      }
      if (node.isThrowing) {
        body += " throws";
        if (!node.thrownType.empty()) {
          body += "(" + spelling(node.thrownType[0]) + ")";
        }
      }
      body += " -> " + (node.result.empty() ? std::string("Void")
                                            : spelling(node.result[0]));
      break;
    }
    case TypeNode::Kind::Metatype:
      body = spellOperand(node.children[0]) + "." +
             (node.text.empty() ? "Type" : node.text);
      break;
    case TypeNode::Kind::Existential:
      if (node.children.size() == 1 &&
          node.children[0].kind == TypeNode::Kind::Nominal &&
          node.children[0].components.size() == 1 &&
          (node.children[0].components[0].name == "Any" ||
           node.children[0].components[0].name == "AnyObject")) {
        body = node.children[0].components[0].name;
      } else {
        body = "any " + spelling(node.children[0]);
      }
      break;
    case TypeNode::Kind::Opaque:
      body = "some " + spelling(node.children[0]);
      break;
    case TypeNode::Kind::Composition: {
      for (size_t i = 0; i < node.children.size(); i++) {
        if (i > 0) {
          body += " & ";
        }
        body += spelling(node.children[i]);
      }
      break;
    }
    case TypeNode::Kind::Void:
      body = "Void";
      break;
    case TypeNode::Kind::Unknown:
      body = node.text;
      break;
  }
  return prefix + body;
}

std::string qualifiedNameFromUSR(const std::string& usr) {
  static const std::pair<const char*, const char*> standard[] = {
      {"s:Sb", "Swift.Bool"},      {"s:Si", "Swift.Int"},
      {"s:Su", "Swift.UInt"},      {"s:Sf", "Swift.Float"},
      {"s:Sd", "Swift.Double"},    {"s:SS", "Swift.String"},
      {"s:SJ", "Swift.Character"}, {"s:Sq", "Swift.Optional"},
      {"s:Sa", "Swift.Array"},     {"s:SD", "Swift.Dictionary"},
      {"s:Sh", "Swift.Set"},
  };
  for (const auto& entry : standard) {
    if (usr == entry.first) {
      return entry.second;
    }
  }
  // `s:` followed by length-prefixed identifiers (module first) and one
  // declaration-kind letter: s:10Foundation4DataV -> Foundation.Data.
  llvm::StringRef rest = usr;
  if (!rest.consume_front("s:")) {
    return "";
  }
  std::vector<std::string> names;
  // A leading `s` abbreviates the Swift module: s:s5Int64V.
  if (rest.consume_front("s")) {
    names.push_back("Swift");
  }
  while (!rest.empty() && llvm::isDigit(rest.front())) {
    size_t length = 0;
    while (!rest.empty() && llvm::isDigit(rest.front())) {
      length = length * 10 + (rest.front() - '0');
      rest = rest.drop_front();
    }
    if (length == 0 || length > rest.size()) {
      return "";
    }
    names.push_back(rest.take_front(length).str());
    rest = rest.drop_front(length);
  }
  if (names.size() < 2 || rest.size() != 1 ||
      !llvm::StringRef("VCOPa").contains(rest.front())) {
    return "";
  }
  return llvm::join(names, ".");
}

std::set<std::string> genericNamesInScope(const Module& module,
                                          const Symbol& symbol) {
  std::set<std::string> names;
  for (const Symbol* current = &symbol; current;
       current = current->parentId.empty() ? nullptr
                                           : module.find(current->parentId)) {
    for (const auto& parameter : current->genericParameters) {
      names.insert(parameter.name);
    }
  }
  return names;
}

}  // namespace Swift
