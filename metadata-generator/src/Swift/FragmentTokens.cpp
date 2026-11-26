#include "FragmentTokens.h"

#include <llvm/ADT/StringExtras.h>

namespace Swift {
namespace FragmentTokens {

Tokens tokenize(const Fragments& fragments) {
  Tokens tokens;
  for (const auto& fragment : fragments) {
    // Custom attributes (global actors, property wrappers) arrive as an "@"
    // fragment followed by the attribute type's name, which inside types is a
    // typeIdentifier (`@MainActor (Message) -> Void`).
    if ((fragment.kind == "attribute" || fragment.kind == "typeIdentifier") &&
        !tokens.empty() && tokens.back().isFragment("attribute") &&
        tokens.back().text == "@") {
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
    // Some attributes arrive as plain text ("@backDeployed(before: iOS
    // 17.0)\n", "@abi(func f(...))"). Only the name becomes the attribute
    // token; its argument list is tokenized normally so consumeAttribute can
    // match the parentheses, which may close in a later fragment.
    if (text.ltrim().startswith("@")) {
      llvm::StringRef rest = text.ltrim();
      size_t nameEnd = 1;
      while (nameEnd < rest.size() &&
             (llvm::isAlnum(rest[nameEnd]) || rest[nameEnd] == '_')) {
        nameEnd++;
      }
      tokens.push_back(Token{Token::Type::Fragment, "attribute",
                             rest.take_front(nameEnd).str(), ""});
      text = rest.drop_front(nameEnd);
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
        llvm::StringRef word = text.slice(i, end);
        // "@" inside text starts an attribute whose name may follow as its
        // own fragment (": @" + typeIdentifier "MainActor").
        if (word.startswith("@")) {
          tokens.push_back(
              Token{Token::Type::Fragment, "attribute", word.str(), ""});
        } else {
          tokens.push_back(Token{Token::Type::Word, "text", word.str(), ""});
        }
        i = end;
      }
    }
  }
  return tokens;
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

}  // namespace FragmentTokens
}  // namespace Swift
