#include "SwiftSurface.h"

#include <algorithm>

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
    // Subscripts are methods: `subscript(...)` and `setSubscript(..., value)`.
    case SymbolKind::InstanceSubscript:
      return SwiftSurface::kInstanceMethod;
    case SymbolKind::TypeSubscript:
      return SwiftSurface::kStaticMethod;
    default:
      return SwiftSurface::kFunction;
  }
}

}  // namespace

bool isSwiftUIView(const Symbol& symbol) {
  return std::find(symbol.conformances.begin(), symbol.conformances.end(),
                   "s:7SwiftUI4ViewP") != symbol.conformances.end();
}

int SwiftSurface::indexOf(const std::string& symbolId) const {
  auto it = typeIndex.find(symbolId);
  return it == typeIndex.end() ? -1 : it->second;
}

std::vector<const SwiftSurface::Member*> SwiftSurface::requirementsOf(
    int typeIndex) const {
  std::vector<const Member*> requirements;
  if (types[typeIndex].superIndex >= 0) {
    requirements = requirementsOf(types[typeIndex].superIndex);
  }
  for (const auto& member : members) {
    if ((member.flags & kRequirement) && member.owner == typeIndex) {
      requirements.push_back(&member);
    }
  }
  return requirements;
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
    case Bridge::ObjCObject:
      code = "@" + type.objcClass;
      break;
    case Bridge::Protocol:
      code = "p" + std::to_string(surface.indexOf(type.symbolId));
      break;
    case Bridge::AsyncSequence:
      code = "~" + signatureCode(surface, type.elements.at(0));
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
    case Bridge::Set:
      code = "S[" + signatureCode(surface, type.elements.at(0)) + "]";
      break;
    case Bridge::Error:
      code = "!";
      break;
    case Bridge::Result:
      code = "R(" + signatureCode(surface, type.elements.at(0)) + "," +
             signatureCode(surface, type.elements.at(1)) + ")";
      break;
    case Bridge::Tuple:
    case Bridge::CStruct:
      code = "*(";
      for (size_t i = 0; i < type.elements.size(); i++) {
        code += (i > 0 ? "," : "") +
                (type.labels.empty() ? "" : type.labels[i] + ":") +
                signatureCode(surface, type.elements[i]);
      }
      code += ")";
      break;
    case Bridge::Closure: {
      code = "(";
      for (size_t i = 0; i < type.elements.size(); i++) {
        code += (i > 0 ? "," : "") + signatureCode(surface, type.elements[i]);
      }
      if (!type.results.empty()) {
        code += ">" + signatureCode(surface, type.results[0]);
      }
      code += ")";
      break;
    }
    case Bridge::TypeParameter:
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
    if (!capability || !isNominalType(symbol.kind) ||
        (capability->tier != Tier::SwiftGenerated && !capability->objcBacked)) {
      continue;
    }
    SwiftSurface::TypeKind kind =
        capability->objcBacked                ? SwiftSurface::kObjCClass
        : symbol.kind == SymbolKind::Protocol ? SwiftSurface::kProtocol
        : symbol.kind == SymbolKind::Struct   ? SwiftSurface::kStruct
        : symbol.kind == SymbolKind::Enum
            ? (hasAssociatedValues(module, symbol) ? SwiftSurface::kTaggedEnum
                                                   : SwiftSurface::kEnum)
        : symbol.kind == SymbolKind::Actor ? SwiftSurface::kActor
                                           : SwiftSurface::kClass;
    int index = static_cast<int>(surface.types.size());
    surface.types.push_back(SwiftSurface::Type{
        &symbol, index, kind, -1,
        symbol.module.empty() ? module.name : symbol.module});
    surface.typeIndex[symbol.preciseId] = index;
  }
  for (auto& type : surface.types) {
    type.superIndex = surface.indexOf(type.symbol->superclassId);
    if (type.kind == SwiftSurface::kProtocol) {
      for (const auto& id : type.symbol->conformances) {
        if (surface.indexOf(id) >= 0) {
          type.superIndex = surface.indexOf(id);
        }
      }
    }
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
    member.module = member.owner >= 0       ? surface.types[member.owner].module
                    : symbol.module.empty() ? module.name
                                            : symbol.module;
    member.kind = memberKind(symbol.kind);
    bool subscript = symbol.kind == SymbolKind::InstanceSubscript ||
                     symbol.kind == SymbolKind::TypeSubscript;
    member.flags =
        (symbol.isThrowing ? SwiftSurface::kThrows : 0) |
        (capability->isSettable && member.kind != SwiftSurface::kEnumCase &&
                 !subscript
             ? SwiftSurface::kSettable
             : 0) |
        (capability->ambiguousOverload ? SwiftSurface::kAmbiguous : 0) |
        (capability->isAsync ? SwiftSurface::kAsync : 0) |
        (capability->isMainActor && !capability->isAsync
             ? SwiftSurface::kMainActor
             : 0) |
        (capability->isRequirement ? SwiftSurface::kRequirement : 0);
    member.result = capability->result;
    for (size_t i = 0; i < capability->parameters.size(); i++) {
      member.signature += (i > 0 ? "," : "") +
                          signatureCode(surface, capability->parameters[i]);
    }
    member.signature += ">" + signatureCode(surface, member.result);
    if (subscript && capability->isSettable && !capability->isAsync) {
      Symbol setter = symbol;
      setter.name = "setSubscript(";
      for (size_t i = 0; i < symbol.parameters.size(); i++) {
        setter.name += "_:";
      }
      setter.name += "_:)";
      setter.baseName = "setSubscript";
      Parameter value;
      value.internalName = "value";
      value.type = *symbol.valueType;
      setter.parameters.push_back(value);
      setter.valueType.reset();
      setter.returnType.reset();
      surface.syntheticSymbols.push_back(std::move(setter));

      Capability assign = *capability;
      assign.jsName = "setSubscript";
      assign.isSettable = false;
      assign.parameters.push_back(capability->result);
      assign.result = BridgedType();
      assign.result.bridge = Bridge::Void;
      surface.syntheticCapabilities.push_back(std::move(assign));

      SwiftSurface::Member assigner = member;
      assigner.symbol = &surface.syntheticSymbols.back();
      assigner.capability = &surface.syntheticCapabilities.back();
      assigner.result = assigner.capability->result;
      assigner.assignsSubscript = &symbol;
      assigner.signature.clear();
      for (size_t i = 0; i < assigner.capability->parameters.size(); i++) {
        assigner.signature +=
            (i > 0 ? "," : "") +
            signatureCode(surface, assigner.capability->parameters[i]);
      }
      assigner.signature += ">v";
      surface.members.push_back(std::move(member));
      surface.members.push_back(std::move(assigner));
      continue;
    }
    surface.members.push_back(std::move(member));
  }

  for (const auto& type : surface.types) {
    const Symbol& view = *type.symbol;
    if (type.kind != SwiftSurface::kStruct || !isSwiftUIView(view)) {
      continue;
    }
    bool taken = false;
    for (const auto& member : surface.members) {
      taken |= member.owner == type.index &&
               member.capability->jsName == "hostingController";
    }
    if (taken) {
      continue;
    }
    Symbol symbol;
    symbol.preciseId = view.preciseId;
    symbol.kind = SymbolKind::InstanceMethod;
    symbol.name = "hostingController()";
    symbol.baseName = "hostingController";
    symbol.pathComponents = view.pathComponents;
    symbol.pathComponents.push_back(symbol.name);
    symbol.parentId = view.preciseId;
    symbol.module = view.module;
    symbol.docComment =
        "A UIHostingController showing this view (main thread only).";
    surface.syntheticSymbols.push_back(std::move(symbol));

    Capability capability;
    capability.tier = Tier::SwiftGenerated;
    capability.jsName = "hostingController";
    capability.isMainActor = true;
    capability.result.bridge = Bridge::ObjCObject;
    capability.result.objcClass = "UIViewController";
    surface.syntheticCapabilities.push_back(std::move(capability));

    SwiftSurface::Member member;
    member.symbol = &surface.syntheticSymbols.back();
    member.capability = &surface.syntheticCapabilities.back();
    member.owner = type.index;
    member.module = type.module;
    member.kind = SwiftSurface::kInstanceMethod;
    member.flags = SwiftSurface::kMainActor;
    member.result = member.capability->result;
    member.signature = ">" + signatureCode(surface, member.result);
    member.hostsView = true;
    surface.members.push_back(std::move(member));
  }
  return surface;
}

}  // namespace Swift
