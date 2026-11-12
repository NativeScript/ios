#pragma once

#include <llvm/ADT/StringRef.h>

#include <string>
#include <vector>

#include "SwiftIR.h"

// Symbol graphs carry most semantics (effects, settability, labels, failable
// initializers, actor-ness) only inside `declarationFragments`, where
// structural punctuation is mixed into "text" fragments (e.g. "?) -> ").
// Text fragments are therefore split into single structural tokens before
// parsing.
namespace Swift {
namespace FragmentTokens {

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

Tokens tokenize(const Fragments& fragments);

inline bool opens(const Token& token) {
  return token.isPunct('(') || token.isPunct('[') || token.isPunct('<');
}

inline bool closes(const Token& token) {
  return token.isPunct(')') || token.isPunct(']') || token.isPunct('>');
}

// The tokens in [begin, end) as a TypeRef, without surrounding whitespace.
TypeRef makeTypeRef(Tokens::const_iterator begin, Tokens::const_iterator end);

}  // namespace FragmentTokens
}  // namespace Swift
