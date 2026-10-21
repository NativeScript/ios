#include "SwiftTypes.h"

#include <llvm/ADT/StringExtras.h>

#include <algorithm>

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
    for (const auto& substitution : current->substitutions) {
      names.insert(substitution.first);
    }
  }
  return names;
}

TypeNode substitute(
    const TypeNode& node,
    const std::vector<std::pair<std::string, TypeNode>>& substitutions) {
  if (node.kind == TypeNode::Kind::GenericParameter &&
      node.components.size() == 1) {
    for (const auto& substitution : substitutions) {
      if (substitution.first == node.components[0].name) {
        TypeNode result = substitution.second;
        result.attributes.insert(result.attributes.end(),
                                 node.attributes.begin(),
                                 node.attributes.end());
        if (result.modifier.empty()) {
          result.modifier = node.modifier;
        }
        return result;
      }
    }
    return node;
  }
  TypeNode result = node;
  for (auto& child : result.children) {
    child = substitute(child, substitutions);
  }
  for (auto& child : result.result) {
    child = substitute(child, substitutions);
  }
  for (auto& child : result.thrownType) {
    child = substitute(child, substitutions);
  }
  for (auto& component : result.components) {
    for (auto& argument : component.arguments) {
      argument = substitute(argument, substitutions);
    }
  }
  return result;
}

namespace {

std::string typeKey(const TypeNode& node) {
  switch (node.kind) {
    case TypeNode::Kind::Nominal: {
      std::string key = node.usr().empty() ? spelling(node) : node.usr();
      const auto& arguments = node.components.back().arguments;
      if (!arguments.empty()) {
        key += "<";
        for (size_t i = 0; i < arguments.size(); i++) {
          key += (i > 0 ? "," : "") + typeKey(arguments[i]);
        }
        key += ">";
      }
      return key;
    }
    case TypeNode::Kind::Optional:
    case TypeNode::Kind::ImplicitlyUnwrappedOptional:
      return typeKey(node.children.at(0)) + "?";
    case TypeNode::Kind::Array:
      return "[" + typeKey(node.children.at(0)) + "]";
    case TypeNode::Kind::Dictionary:
      return "[" + typeKey(node.children.at(0)) + ":" +
             typeKey(node.children.at(1)) + "]";
    default:
      return spelling(node);
  }
}

bool isConcrete(const TypeNode& node) {
  if (node.kind == TypeNode::Kind::GenericParameter ||
      node.kind == TypeNode::Kind::Opaque ||
      node.kind == TypeNode::Kind::Unknown) {
    return false;
  }
  for (const auto* list : {&node.children, &node.result, &node.thrownType}) {
    for (const auto& child : *list) {
      if (!isConcrete(child)) {
        return false;
      }
    }
  }
  for (const auto& component : node.components) {
    for (const auto& argument : component.arguments) {
      if (!isConcrete(argument)) {
        return false;
      }
    }
  }
  return true;
}

// Concrete generic nominals in `node`, outermost first.
void collectInstantiations(const TypeNode& node,
                           std::vector<const TypeNode*>& out) {
  if (node.kind == TypeNode::Kind::Nominal && !node.components.empty() &&
      !node.components.back().arguments.empty() && isConcrete(node)) {
    out.push_back(&node);
  }
  for (const auto* list : {&node.children, &node.result, &node.thrownType}) {
    for (const auto& child : *list) {
      collectInstantiations(child, out);
    }
  }
  for (const auto& component : node.components) {
    for (const auto& argument : component.arguments) {
      collectInstantiations(argument, out);
    }
  }
}

std::vector<const TypeRef*> typesOf(const Symbol& symbol) {
  std::vector<const TypeRef*> types;
  for (const auto& parameter : symbol.parameters) {
    types.push_back(&parameter.type);
  }
  for (const auto* type :
       {&symbol.returnType, &symbol.valueType, &symbol.aliasedType}) {
    if (*type) {
      types.push_back(&**type);
    }
  }
  return types;
}

std::string withoutSpaces(llvm::StringRef text) {
  std::string out;
  for (char c : text) {
    if (c != ' ') {
      out += c;
    }
  }
  return out;
}

// Whether `member`'s same-type requirements (`where UnitType == UnitMass`,
// `where Self == Style<Double>`) hold for `base` instantiated with
// `arguments`. Requirements this cannot decide count as holding; compiler
// verification has the last word.
bool sameTypeRequirementsHold(const Symbol& member, const Symbol& base,
                              const std::vector<TypeNode>& arguments) {
  std::vector<const GenericConstraint*> constraints;
  for (const auto& constraint : member.genericConstraints) {
    constraints.push_back(&constraint);
  }
  if (member.extension) {
    for (const auto& constraint : member.extension->constraints) {
      constraints.push_back(&constraint);
    }
  }
  std::vector<std::string> spelled;
  for (const auto& argument : arguments) {
    spelled.push_back(withoutSpaces(spelling(argument)));
  }
  for (const GenericConstraint* constraint : constraints) {
    if (constraint->kind != "sameType") {
      continue;
    }
    std::string rhs = withoutSpaces(constraint->rhs);
    for (size_t i = 0; i < base.genericParameters.size() && i < spelled.size();
         i++) {
      if (constraint->lhs == base.genericParameters[i].name &&
          rhs != spelled[i] &&
          llvm::StringRef(spelled[i]).rsplit('.').second != rhs) {
        return false;
      }
    }
    // `Self == Outer.Base<Args>`, qualified or not.
    std::string prefix = base.name + "<";
    size_t at = rhs.find(prefix);
    if (constraint->lhs == "Self" && at != std::string::npos &&
        (at == 0 || rhs[at - 1] == '.') && llvm::StringRef(rhs).endswith(">") &&
        rhs.find('<') == at + base.name.size()) {
      std::string own = prefix + llvm::join(spelled, ",") + ">";
      if (rhs.substr(at) != own) {
        return false;
      }
    }
  }
  return true;
}

// How a generic function's type parameter appears in its types.
struct ParameterUse {
  // In an argument outside closures, so the arguments JS passes tell its
  // instantiations apart.
  bool inArgument = false;
  // As a metatype (`T.Type`) or through an associated type (`T.Element`),
  // which no stand-in substitutes.
  bool unsupported = false;
};

void collectUse(const TypeNode& node, const std::string& name, bool argument,
                bool inClosure, bool inMetatype, ParameterUse& use) {
  if (node.kind == TypeNode::Kind::GenericParameter &&
      !node.components.empty() && node.components[0].name == name) {
    if (node.components.size() > 1 || inMetatype) {
      use.unsupported = true;
    } else if (argument && !inClosure) {
      use.inArgument = true;
    }
    return;
  }
  bool closure = inClosure || node.kind == TypeNode::Kind::Function;
  bool metatype = inMetatype || node.kind == TypeNode::Kind::Metatype;
  for (const auto* list : {&node.children, &node.result, &node.thrownType}) {
    for (const auto& child : *list) {
      collectUse(child, name, argument, closure, metatype, use);
    }
  }
  for (const auto& component : node.components) {
    for (const auto& argumentType : component.arguments) {
      collectUse(argumentType, name, argument, closure, metatype, use);
    }
  }
}

TypeNode nominalNode(const std::string& qualifiedName, const std::string& usr) {
  TypeNode node;
  node.kind = TypeNode::Kind::Nominal;
  llvm::SmallVector<llvm::StringRef, 4> names;
  llvm::StringRef(qualifiedName).split(names, '.');
  for (llvm::StringRef name : names) {
    TypeNode::Component component;
    component.name = name.str();
    node.components.push_back(std::move(component));
  }
  node.components.back().usr = usr;
  return node;
}

// Standard library types that stand in for a type parameter constrained only
// by standard library protocols, with the protocols each conforms to. At most
// one number type stands in, since a JS number converts to every one.
struct Primitive {
  const char* name;
  const char* usr;
  std::set<std::string> protocols;
};

const std::vector<Primitive>& primitives() {
  static const std::vector<Primitive> list = [] {
    std::set<std::string> common = {"Equatable",
                                    "Hashable",
                                    "Encodable",
                                    "Decodable",
                                    "Codable",
                                    "Sendable",
                                    "CustomStringConvertible",
                                    "CustomDebugStringConvertible",
                                    "LosslessStringConvertible"};
    std::set<std::string> number = {
        "Comparable",         "Numeric",    "SignedNumeric",
        "AdditiveArithmetic", "Strideable", "ExpressibleByIntegerLiteral",
        "BitwiseCopyable"};
    auto with = [&](std::set<std::string> base,
                    std::initializer_list<const char*> more) {
      base.insert(common.begin(), common.end());
      base.insert(more.begin(), more.end());
      return base;
    };
    return std::vector<Primitive>{
        {"Double", KnownTypes::kDouble,
         with(number, {"FloatingPoint", "BinaryFloatingPoint",
                       "ExpressibleByFloatLiteral"})},
        {"Int", KnownTypes::kInt,
         with(number, {"BinaryInteger", "FixedWidthInteger", "SignedInteger"})},
        {"String", KnownTypes::kString,
         with({}, {"Comparable", "StringProtocol", "ExpressibleByStringLiteral",
                   "TextOutputStream", "TextOutputStreamable"})},
        {"Bool", KnownTypes::kBool,
         with({}, {"ExpressibleByBooleanLiteral", "BitwiseCopyable"})},
    };
  }();
  return list;
}

// Standard library USRs follow "s:" with a substitution ("s:SQ") or the
// module's own "s"; other modules' start with their name's length.
bool isStandardLibraryUSR(llvm::StringRef usr) {
  return usr.size() > 2 && usr.startswith("s:") && !llvm::isDigit(usr[2]);
}

// The concrete types `parameter` is instantiated with, given the function's
// constraints; empty when none is known to satisfy them. A unit protocol
// stands in as its existential, which Swift opens at the call.
std::vector<TypeNode> standIns(
    const Module& module, const std::string& parameter,
    const std::vector<GenericConstraint>& constraints) {
  std::vector<std::string> standard;
  std::vector<const Symbol*> protocols;
  const GenericConstraint* superclass = nullptr;
  for (const auto& constraint : constraints) {
    llvm::StringRef lhs(constraint.lhs);
    if (lhs.startswith(parameter + ".")) {
      return {};
    }
    if (lhs != parameter) {
      continue;
    }
    if (constraint.kind == "superclass") {
      superclass = &constraint;
    } else if (constraint.kind != "conformance") {
      return {};
    } else if (const Symbol* protocol = module.find(constraint.rhsPrecise);
               protocol && protocol->kind == SymbolKind::Protocol) {
      protocols.push_back(protocol);
    } else if (isStandardLibraryUSR(constraint.rhsPrecise)) {
      llvm::StringRef name(constraint.rhs);
      standard.push_back(name.substr(name.rfind('.') + 1).str());
    } else {
      return {};
    }
  }
  if (superclass) {
    if (!protocols.empty() || !standard.empty()) {
      return {};
    }
    return {nominalNode(superclass->rhs, superclass->rhsPrecise)};
  }
  if (!protocols.empty()) {
    if (protocols.size() > 1) {
      return {};
    }
    TypeNode existential;
    existential.kind = TypeNode::Kind::Existential;
    existential.children.push_back(
        nominalNode(protocols[0]->name, protocols[0]->preciseId));
    return {existential};
  }
  std::vector<TypeNode> result;
  bool number = false;
  for (const Primitive& primitive : primitives()) {
    bool isNumber = primitive.usr == KnownTypes::kDouble ||
                    primitive.usr == KnownTypes::kInt;
    if (isNumber && number) {
      continue;
    }
    bool satisfies = std::all_of(standard.begin(), standard.end(),
                                 [&](const std::string& name) {
                                   return primitive.protocols.count(name);
                                 });
    if (satisfies) {
      number |= isNumber;
      result.push_back(nominalNode(primitive.name, primitive.usr));
    }
  }
  return result;
}

bool isGenericFunctionKind(SymbolKind kind) {
  return kind == SymbolKind::Function || kind == SymbolKind::InstanceMethod ||
         kind == SymbolKind::TypeMethod || kind == SymbolKind::Initializer;
}

// Adds a synthetic copy of every generic function, method and initializer
// for each combination of its type parameters' stand-ins (see standIns).
// Members of generic types and protocols are left generic.
void instantiateGenericFunctions(Module& module) {
  // Each combination becomes one overload of the function's JS name.
  constexpr size_t kMaxInstantiations = 6;
  std::vector<std::string> ids;
  for (const auto& entry : module.symbols) {
    if (isGenericFunctionKind(entry.second.kind) &&
        !entry.second.genericParameters.empty()) {
      ids.push_back(entry.first);
    }
  }

  for (const std::string& id : ids) {
    const Symbol source = *module.find(id);
    bool genericContext = false;
    for (const Symbol* parent =
             source.parentId.empty() ? nullptr : module.find(source.parentId);
         parent;
         parent = parent->parentId.empty() ? nullptr
                                           : module.find(parent->parentId)) {
      genericContext |= !parent->genericParameters.empty() ||
                        !parent->genericBase.empty() ||
                        parent->kind == SymbolKind::Protocol;
    }
    // A depth above 0 is nested in a generic context, which may be a type
    // of another module (`extension Array`).
    for (const auto& parameter : source.genericParameters) {
      genericContext |= parameter.depth != 0;
    }
    if (genericContext) {
      continue;
    }

    std::set<std::string> generics = genericNamesInScope(module, source);
    std::vector<TypeNode> types;
    std::vector<bool> isArgument;
    bool parsed = true;
    auto add = [&](const TypeRef& type, bool argument) {
      bool complete = true;
      types.push_back(parseType(type, generics, &complete));
      isArgument.push_back(argument);
      parsed &= complete;
    };
    for (const auto& parameter : source.parameters) {
      add(parameter.type, true);
    }
    if (source.returnType) {
      add(*source.returnType, false);
    }
    if (!parsed) {
      continue;
    }

    std::vector<std::vector<TypeNode>> options;
    size_t combinations = 1;
    for (const auto& parameter : source.genericParameters) {
      ParameterUse use;
      for (size_t i = 0; i < types.size(); i++) {
        collectUse(types[i], parameter.name, isArgument[i], false, false, use);
      }
      std::vector<TypeNode> candidates =
          llvm::StringRef(parameter.name).contains(' ')
              ? std::vector<TypeNode>()
              : standIns(module, parameter.name, source.genericConstraints);
      if (use.unsupported || candidates.empty() ||
          (candidates.size() > 1 && !use.inArgument)) {
        combinations = 0;
        break;
      }
      combinations *= candidates.size();
      options.push_back(std::move(candidates));
    }
    if (combinations == 0 || combinations > kMaxInstantiations) {
      continue;
    }

    std::vector<std::string> copies;
    for (size_t n = 0; n < combinations; n++) {
      Symbol copy = source;
      copy.genericParameters.clear();
      copy.genericConstraints.clear();
      copy.genericBase = source.preciseId;
      std::string key;
      size_t rest = n;
      for (size_t i = 0; i < options.size(); i++) {
        const TypeNode& argument = options[i][rest % options[i].size()];
        rest /= options[i].size();
        copy.substitutions.emplace_back(source.genericParameters[i].name,
                                        argument);
        key += (i > 0 ? "," : "") + typeKey(argument);
      }
      copy.preciseId = source.preciseId + "@<" + key + ">";
      copies.push_back(copy.preciseId);
      module.symbols.emplace(copy.preciseId, std::move(copy));
    }

    auto insertAfter = [&](std::vector<std::string>& list) {
      auto at = std::find(list.begin(), list.end(), id);
      if (at != list.end()) {
        list.insert(at + 1, copies.begin(), copies.end());
      }
    };
    if (source.parentId.empty()) {
      insertAfter(module.topLevelIds);
    } else if (auto parent = module.symbols.find(source.parentId);
               parent != module.symbols.end()) {
      insertAfter(parent->second.memberIds);
    } else if (auto external = module.externalTypes.find(source.parentId);
               external != module.externalTypes.end()) {
      insertAfter(external->second.memberIds);
    }
  }
}

}  // namespace

std::string instantiationKey(const TypeNode& node) { return typeKey(node); }

void instantiateGenerics(Module& module) {
  // Instantiations a synthetic member spells are followed this deep, which
  // stops `Box<T>.wrapped() -> Box<Box<T>>` from unfolding forever.
  constexpr int kMaxDepth = 2;
  struct Pending {
    std::string id;
    int depth;
  };
  std::vector<Pending> queue;
  for (const auto& entry : module.symbols) {
    queue.push_back(Pending{entry.first, 0});
  }

  for (size_t next = 0; next < queue.size(); next++) {
    Pending pending = queue[next];
    const Symbol* source = module.find(pending.id);
    if (!source) {
      continue;
    }
    std::set<std::string> generics = genericNamesInScope(module, *source);
    std::vector<std::pair<std::string, TypeNode>> substitutions;
    for (const Symbol* current = source; current;
         current = current->parentId.empty() ? nullptr
                                             : module.find(current->parentId)) {
      substitutions.insert(substitutions.end(), current->substitutions.begin(),
                           current->substitutions.end());
    }

    std::vector<TypeNode> found;
    for (const TypeRef* type : typesOf(*source)) {
      bool complete = true;
      TypeNode node =
          substitute(parseType(*type, generics, &complete), substitutions);
      if (!complete) {
        continue;
      }
      std::vector<const TypeNode*> nodes;
      collectInstantiations(node, nodes);
      for (const TypeNode* instance : nodes) {
        found.push_back(*instance);
      }
    }

    for (const TypeNode& instance : found) {
      std::string key = instantiationKey(instance);
      const Symbol* base = module.find(instance.usr());
      const auto& arguments = instance.components.back().arguments;
      if (module.find(key) || !base || !isNominalType(base->kind) ||
          base->kind == SymbolKind::Protocol || !base->genericBase.empty() ||
          base->genericParameters.size() != arguments.size() ||
          pending.depth >= kMaxDepth) {
        continue;
      }
      // Only the type's own parameters: one nested in a generic type is not
      // instantiated.
      bool nestedInGeneric = false;
      for (const Symbol* parent =
               base->parentId.empty() ? nullptr : module.find(base->parentId);
           parent;
           parent = parent->parentId.empty() ? nullptr
                                             : module.find(parent->parentId)) {
        nestedInGeneric |= !parent->genericParameters.empty();
      }
      if (nestedInGeneric) {
        continue;
      }

      Symbol type = *base;
      type.preciseId = key;
      type.genericBase = base->preciseId;
      type.genericParameters.clear();
      type.genericConstraints.clear();
      type.typeArguments = arguments;
      type.memberIds.clear();
      for (size_t i = 0; i < arguments.size(); i++) {
        type.substitutions.emplace_back(base->genericParameters[i].name,
                                        arguments[i]);
      }
      std::vector<std::string> members;
      for (const auto& memberId : base->memberIds) {
        const Symbol* member = module.find(memberId);
        if (!member || isNominalType(member->kind) ||
            !sameTypeRequirementsHold(*member, *base, arguments)) {
          continue;
        }
        Symbol copy = *member;
        // Graphs repeat the enclosing type's parameters on its members.
        auto substituted = [&](const std::string& name) {
          for (const auto& parameter : base->genericParameters) {
            if (parameter.name == name) {
              return true;
            }
          }
          return false;
        };
        copy.genericParameters.erase(
            std::remove_if(
                copy.genericParameters.begin(), copy.genericParameters.end(),
                [&](const GenericParameter& p) { return substituted(p.name); }),
            copy.genericParameters.end());
        copy.genericConstraints.erase(
            std::remove_if(copy.genericConstraints.begin(),
                           copy.genericConstraints.end(),
                           [&](const GenericConstraint& c) {
                             return substituted(
                                 llvm::StringRef(c.lhs).split('.').first.str());
                           }),
            copy.genericConstraints.end());
        copy.preciseId = member->preciseId + "@" + key;
        copy.parentId = key;
        copy.genericBase = member->preciseId;
        copy.memberIds.clear();
        members.push_back(copy.preciseId);
        module.symbols.emplace(copy.preciseId, std::move(copy));
      }
      type.memberIds = members;
      module.symbols.emplace(key, std::move(type));
      queue.push_back(Pending{key, pending.depth});
      for (const auto& member : members) {
        queue.push_back(Pending{member, pending.depth + 1});
      }
    }
  }
  instantiateGenericFunctions(module);
}

}  // namespace Swift
