#include "SwiftSurface.h"

namespace Swift {

namespace {

const IntegerWidth kIntegerWidths[] = {
    {"i64", "Int", true},     {"i8", "Int8", true},
    {"i16", "Int16", true},   {"i32", "Int32", true},
    {"i64", "Int64", true},   {"u64", "UInt", false},
    {"u8", "UInt8", false},   {"u16", "UInt16", false},
    {"u32", "UInt32", false}, {"u64", "UInt64", false},
};

const char* const kIntegerUSRs[] = {
    KnownTypes::kInt,    KnownTypes::kInt8,   KnownTypes::kInt16,
    KnownTypes::kInt32,  KnownTypes::kInt64,  KnownTypes::kUInt,
    KnownTypes::kUInt8,  KnownTypes::kUInt16, KnownTypes::kUInt32,
    KnownTypes::kUInt64,
};

SwiftSurface::MemberKind memberKind(SymbolKind kind) {
  switch (kind) {
    case SymbolKind::Initializer:
      return SwiftSurface::kInitializer;
    case SymbolKind::InstanceMethod:
      return SwiftSurface::kInstanceMethod;
    case SymbolKind::TypeMethod:
      return SwiftSurface::kStaticMethod;
    case SymbolKind::InstanceProperty:
      return SwiftSurface::kInstanceProperty;
    case SymbolKind::TypeProperty:
      return SwiftSurface::kStaticProperty;
    case SymbolKind::Variable:
      return SwiftSurface::kVariable;
    case SymbolKind::EnumCase:
      return SwiftSurface::kEnumCase;
    default:
      return SwiftSurface::kFunction;
  }
}

}  // namespace

int SwiftSurface::indexOf(const std::string& symbolId) const {
  auto it = typeIndex.find(symbolId);
  return it == typeIndex.end() ? -1 : it->second;
}

std::vector<const SwiftSurface::Member*> SwiftSurface::casesOf(
    int typeIndex) const {
  std::vector<const Member*> cases;
  for (const auto& member : members) {
    if (member.kind == kEnumCase && member.owner == typeIndex) {
      cases.push_back(&member);
    }
  }
  return cases;
}

const TypeNode& unwrappedNode(const BridgedType& type) {
  const TypeNode& node = type.node;
  if (type.optional && !node.children.empty() &&
      (node.kind == TypeNode::Kind::Optional ||
       node.kind == TypeNode::Kind::ImplicitlyUnwrappedOptional)) {
    return node.children[0];
  }
  return node;
}

const IntegerWidth* integerWidth(const BridgedType& type) {
  const std::string& usr = unwrappedNode(type).usr();
  for (size_t i = 0; i < sizeof(kIntegerUSRs) / sizeof(kIntegerUSRs[0]); i++) {
    if (usr == kIntegerUSRs[i]) {
      return &kIntegerWidths[i];
    }
  }
  return nullptr;
}

std::string signatureCode(const SwiftSurface& surface,
                          const BridgedType& type) {
  std::string code;
  switch (type.bridge) {
    case Bridge::Void:
      code = "v";
      break;
    case Bridge::Bool:
      code = "b";
      break;
    case Bridge::Integer:
      code = integerWidth(type) ? integerWidth(type)->code : "i64";
      break;
    case Bridge::Floating:
      code = unwrappedNode(type).usr() == KnownTypes::kFloat ? "f32" : "f64";
      break;
    case Bridge::String:
      code = "s";
      break;
    case Bridge::ClassHandle:
    case Bridge::StructBox:
      code = "o" + std::to_string(surface.indexOf(type.symbolId));
      break;
    case Bridge::EnumCase:
      code = "e" + std::to_string(surface.indexOf(type.symbolId));
      break;
    case Bridge::TaggedEnum:
      code = "t" + std::to_string(surface.indexOf(type.symbolId));
      break;
    case Bridge::Date:
      code = "D";
      break;
    case Bridge::URL:
      code = "U";
      break;
    case Bridge::Data:
      code = "B";
      break;
    case Bridge::Array:
      code = "[" + signatureCode(surface, type.elements.at(0)) + "]";
      break;
    case Bridge::Dictionary:
      code = "{" + signatureCode(surface, type.elements.at(0)) + "}";
      break;
    case Bridge::Closure: {
      code = "(";
      for (size_t i = 0; i < type.elements.size(); i++) {
        code += (i > 0 ? "," : "") + signatureCode(surface, type.elements[i]);
      }
      code += ")";
      break;
    }
    case Bridge::None:
      code = "?";
      break;
  }
  return (type.isInout ? "&" : "") + (type.optional ? code + "?" : code);
}

SwiftSurface describeSurface(const Module& module,
                             const Classification& classification) {
  SwiftSurface surface;
  for (const auto& entry : module.symbols) {
    const Symbol& symbol = entry.second;
    const Capability* capability = classification.find(entry.first);
    if (!capability || capability->tier != Tier::SwiftGenerated ||
        !isNominalType(symbol.kind) || symbol.kind == SymbolKind::Protocol) {
      continue;
    }
    SwiftSurface::TypeKind kind =
        symbol.kind == SymbolKind::Struct ? SwiftSurface::kStruct
        : symbol.kind == SymbolKind::Enum
            ? (hasAssociatedValues(module, symbol) ? SwiftSurface::kTaggedEnum
                                                   : SwiftSurface::kEnum)
        : symbol.kind == SymbolKind::Actor ? SwiftSurface::kActor
                                           : SwiftSurface::kClass;
    int index = static_cast<int>(surface.types.size());
    surface.types.push_back(SwiftSurface::Type{&symbol, index, kind, -1});
    surface.typeIndex[symbol.preciseId] = index;
  }
  for (auto& type : surface.types) {
    type.superIndex = surface.indexOf(type.symbol->superclassId);
  }

  for (const auto& entry : module.symbols) {
    const Symbol& symbol = entry.second;
    const Capability* capability = classification.find(entry.first);
    if (!capability || capability->tier != Tier::SwiftGenerated ||
        !isCallableKind(symbol.kind)) {
      continue;
    }
    const Symbol* owner =
        symbol.parentId.empty() ? nullptr : module.find(symbol.parentId);

    SwiftSurface::Member member;
    member.symbol = &symbol;
    member.capability = capability;
    member.owner = owner ? surface.indexOf(owner->preciseId) : -1;
    member.kind = memberKind(symbol.kind);
    member.flags =
        (symbol.isThrowing ? SwiftSurface::kThrows : 0) |
        (capability->isSettable && member.kind != SwiftSurface::kEnumCase
             ? SwiftSurface::kSettable
             : 0) |
        (capability->ambiguousOverload ? SwiftSurface::kAmbiguous : 0) |
        (capability->isAsync ? SwiftSurface::kAsync : 0) |
        (capability->isMainActor && !capability->isAsync
             ? SwiftSurface::kMainActor
             : 0);
    member.result = capability->result;
    for (size_t i = 0; i < capability->parameters.size(); i++) {
      member.signature += (i > 0 ? "," : "") +
                          signatureCode(surface, capability->parameters[i]);
    }
    member.signature += ">" + signatureCode(surface, member.result);
    surface.members.push_back(std::move(member));
  }
  return surface;
}

}  // namespace Swift
