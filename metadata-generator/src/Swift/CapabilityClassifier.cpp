#include "CapabilityClassifier.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/ADT/StringRef.h>

#include <algorithm>
#include <tuple>

namespace Swift {

const char* toString(Tier tier) {
  switch (tier) {
    case Tier::ObjCDirect:
      return "objc-direct";
    case Tier::SwiftGenerated:
      return "swift-generated";
    case Tier::SwiftSpecialized:
      return "swift-specialized";
    case Tier::TypeOnly:
      return "type-only";
    case Tier::Unsupported:
      return "unsupported";
    case Tier::NotApplicable:
      return "not-applicable";
  }
  return "unsupported";
}

const Capability* Classification::find(const std::string& id) const {
  auto it = bySymbol.find(id);
  return it == bySymbol.end() ? nullptr : &it->second;
}

bool isCallableKind(SymbolKind kind) {
  switch (kind) {
    case SymbolKind::EnumCase:
    case SymbolKind::Initializer:
    case SymbolKind::InstanceMethod:
    case SymbolKind::TypeMethod:
    case SymbolKind::Operator:
    case SymbolKind::InstanceProperty:
    case SymbolKind::TypeProperty:
    case SymbolKind::InstanceSubscript:
    case SymbolKind::TypeSubscript:
    case SymbolKind::Function:
    case SymbolKind::Variable:
      return true;
    default:
      return false;
  }
}

bool hasAssociatedValues(const Module& module, const Symbol& symbol) {
  if (symbol.kind != SymbolKind::Enum) {
    return false;
  }
  for (const auto& id : symbol.memberIds) {
    const Symbol* member = module.find(id);
    if (member && member->kind == SymbolKind::EnumCase &&
        !member->parameters.empty()) {
      return true;
    }
  }
  return false;
}

std::vector<std::string> caseKeys(const Symbol& enumCase) {
  std::vector<std::string> keys;
  const auto& parameters = enumCase.parameters;
  for (size_t i = 0; i < parameters.size(); i++) {
    keys.push_back(!parameters[i].label.empty() ? parameters[i].label
                   : parameters.size() == 1     ? "value"
                                                : std::to_string(i));
  }
  return keys;
}

namespace {

std::string availabilityDomain(const Platform& platform) {
  llvm::StringRef os = platform.operatingSystem;
  if (os == "ios") {
    return platform.environment == "macabi" ? "macCatalyst" : "iOS";
  }
  if (os == "macosx" || os == "macos") {
    return "macOS";
  }
  if (os == "tvos") {
    return "tvOS";
  }
  if (os == "watchos") {
    return "watchOS";
  }
  if (os == "xros" || os == "visionos") {
    return "visionOS";
  }
  return os.str();
}

bool versionAtMost(const Version& a, const Version& b) {
  return std::tie(a.major, a.minor, a.patch) <=
         std::tie(b.major, b.minor, b.patch);
}

bool hasAttribute(const Symbol& symbol, llvm::StringRef attribute) {
  for (const auto& candidate : symbol.attributes) {
    if (llvm::StringRef(candidate).startswith(attribute)) {
      return true;
    }
  }
  return false;
}

bool isPrimitive(const std::string& usr, Bridge& bridge) {
  using namespace KnownTypes;
  static const char* integers[] = {kInt,  kInt8,  kInt16,  kInt32,  kInt64,
                                   kUInt, kUInt8, kUInt16, kUInt32, kUInt64};
  for (const char* candidate : integers) {
    if (usr == candidate) {
      bridge = Bridge::Integer;
      return true;
    }
  }
  if (usr == kDouble || usr == kFloat || usr == kCGFloat) {
    bridge = Bridge::Floating;
    return true;
  }
  if (usr == kBool) {
    bridge = Bridge::Bool;
    return true;
  }
  if (usr == kString) {
    bridge = Bridge::String;
    return true;
  }
  return false;
}

class Classifier {
 public:
  Classifier(const Module& module,
             const std::map<std::string, std::string>& rejections)
      : _module(module), _rejections(rejections) {}

  Classification run() {
    // Types first: member classification depends on the owner's tier.
    for (const auto& entry : _module.symbols) {
      if (isNominalType(entry.second.kind)) {
        _result.bySymbol[entry.first] = classifyType(entry.second);
      }
    }
    rejectUnbridgedPayloads();
    rejectUnadoptableProtocols();
    for (const auto& entry : _module.symbols) {
      if (!isNominalType(entry.second.kind)) {
        _result.bySymbol[entry.first] = classifyOther(entry.second);
      }
    }
    resolveNames();
    classifyTemplates();
    return std::move(_result);
  }

 private:
  static Capability make(Tier tier, std::string reason = "") {
    Capability capability;
    capability.tier = tier;
    if (!reason.empty()) {
      capability.reasons.push_back(std::move(reason));
    }
    return capability;
  }

  // Reasons shared by every declaration kind.
  bool commonRejection(const Symbol& symbol, Capability& out) const {
    auto rejected = _rejections.find(symbol.preciseId);
    if (rejected != _rejections.end()) {
      out = make(Tier::Unsupported, "compiler-rejected:" + rejected->second);
      return true;
    }
    if (llvm::StringRef(symbol.usr).startswith("c:")) {
      out = make(Tier::ObjCDirect, "objc-visible");
      return true;
    }
    if (symbol.access != AccessLevel::Public &&
        symbol.access != AccessLevel::Open) {
      out = make(Tier::Unsupported, "not-public");
      return true;
    }
    for (const Availability* availability :
         applicableAvailability(_module, symbol)) {
      if (availability->isUnconditionallyUnavailable) {
        out = make(Tier::Unsupported, "unavailable");
        return true;
      }
      if (availability->obsoleted && _module.platform.minimumVersion &&
          versionAtMost(*availability->obsoleted,
                        *_module.platform.minimumVersion)) {
        out = make(Tier::Unsupported, "obsoleted");
        return true;
      }
    }
    return false;
  }

  Capability classifyType(const Symbol& symbol) const {
    Capability capability;
    if (commonRejection(symbol, capability)) {
      return capability;
    }
    if (symbol.kind == SymbolKind::Protocol) {
      return classifyProtocol(symbol);
    }
    if (!symbol.genericParameters.empty()) {
      return make(Tier::SwiftSpecialized, "generic");
    }
    // A nested type is reached through its parent's JS path; it is generic
    // when any enclosing type is.
    for (const Symbol* current = &symbol; !current->parentId.empty();) {
      const Symbol* parent = _module.find(current->parentId);
      if (!parent) {
        return make(Tier::Unsupported, "external-type-extension");
      }
      if (!parent->genericParameters.empty()) {
        return make(Tier::SwiftSpecialized, "generic");
      }
      current = parent;
    }
    // Graphs show suppressed conformances only when the declaration spells
    // them; other noncopyable types are caught by compiler verification.
    if (llvm::StringRef(symbol.declarationText).contains("~Copyable")) {
      return make(Tier::Unsupported, "noncopyable");
    }
    if (llvm::StringRef(symbol.declarationText).contains("~Escapable")) {
      return make(Tier::Unsupported, "nonescapable");
    }
    return make(Tier::SwiftGenerated);
  }

  // A protocol JS objects can implement: every requirement is an instance
  // method or property, and the protocols it refines are such protocols or
  // markers. Requirement types are checked by rejectUnadoptableProtocols.
  Capability classifyProtocol(const Symbol& symbol) const {
    static const std::set<std::string> markers = {
        "s:s8SendableP", "s:s16SendableMetatypeP", "s:s8CopyableP",
        "s:s9EscapableP"};
    int refinedModuleProtocols = 0;
    for (const auto& id : symbol.conformances) {
      const Symbol* refined = _module.find(id);
      if (!markers.count(id) &&
          (!refined || refined->kind != SymbolKind::Protocol)) {
        return make(Tier::TypeOnly, "protocol");
      }
      refinedModuleProtocols += refined != nullptr;
    }
    // Adapters number requirements along a single refinement chain.
    if (refinedModuleProtocols > 1) {
      return make(Tier::TypeOnly, "protocol");
    }
    if (hasAttribute(symbol, "@MainActor")) {
      return make(Tier::TypeOnly, "protocol");
    }
    for (const auto& id : symbol.memberIds) {
      const Symbol* member = _module.find(id);
      if (!member || !member->isProtocolRequirement) {
        continue;
      }
      if (member->kind == SymbolKind::AssociatedType) {
        return make(Tier::TypeOnly, "associated-type");
      }
      bool callable =
          (member->kind == SymbolKind::InstanceMethod ||
           member->kind == SymbolKind::InstanceProperty) &&
          !member->isAsync && member->genericParameters.empty() &&
          !hasAttribute(*member, "@MainActor") &&
          !llvm::StringRef(member->declarationText).contains("Self");
      if (!callable) {
        return make(Tier::TypeOnly, "protocol");
      }
    }
    return make(Tier::SwiftGenerated);
  }

  // Adoptable protocols whose requirements do not bridge (or that refine one
  // that is not adoptable) are not; repeated until nothing changes.
  void rejectUnadoptableProtocols() {
    bool changed = true;
    while (changed) {
      changed = false;
      for (const auto& entry : _module.symbols) {
        const Symbol& symbol = entry.second;
        Capability& capability = _result.bySymbol[entry.first];
        if (symbol.kind != SymbolKind::Protocol ||
            capability.tier != Tier::SwiftGenerated) {
          continue;
        }
        std::vector<std::string> reasons;
        for (const auto& id : symbol.conformances) {
          const Capability* refined = _result.find(id);
          if (_module.find(id) &&
              (!refined || refined->tier != Tier::SwiftGenerated)) {
            reasons.push_back("protocol");
          }
        }
        for (const auto& id : symbol.memberIds) {
          const Symbol* member = _module.find(id);
          if (!member || !member->isProtocolRequirement) {
            continue;
          }
          if (_rejections.count(member->preciseId)) {
            reasons.push_back("compiler-rejected:" +
                              _rejections.at(member->preciseId));
          }
          std::set<std::string> generics =
              genericNamesInScope(_module, *member);
          generics.insert("Self");
          _substitutions.clear();
          for (const auto& parameter : member->parameters) {
            BridgedType bridged = bridge(parameter.type, generics, reasons);
            if (parameter.modifier == "inout" ||
                bridged.bridge == Bridge::Closure) {
              reasons.push_back("protocol");
            }
          }
          if (member->returnType) {
            bridge(*member->returnType, generics, reasons);
          }
          if (member->valueType) {
            bridge(*member->valueType, generics, reasons);
          }
        }
        if (!reasons.empty()) {
          std::sort(reasons.begin(), reasons.end());
          reasons.erase(std::unique(reasons.begin(), reasons.end()),
                        reasons.end());
          capability = make(Tier::TypeOnly, "protocol");
          for (const auto& reason : reasons) {
            if (reason != "protocol") {
              capability.reasons.push_back(reason);
            }
          }
          changed = true;
        }
      }
    }
  }

  // An enum with associated values crosses whole, so every case JS may see
  // must bridge. Payloads can name other such enums: demote until nothing
  // changes.
  void rejectUnbridgedPayloads() {
    bool changed = true;
    while (changed) {
      changed = false;
      for (const auto& entry : _module.symbols) {
        const Symbol& symbol = entry.second;
        Capability& capability = _result.bySymbol[entry.first];
        if (capability.tier != Tier::SwiftGenerated ||
            !hasAssociatedValues(_module, symbol)) {
          continue;
        }
        std::vector<std::string> reasons;
        for (const auto& id : symbol.memberIds) {
          const Symbol* member = _module.find(id);
          if (!member || member->kind != SymbolKind::EnumCase ||
              isUnavailable(*member)) {
            continue;
          }
          auto rejected = _rejections.find(member->preciseId);
          if (rejected != _rejections.end()) {
            reasons.push_back("compiler-rejected:" + rejected->second);
          }
          for (const auto& key : caseKeys(*member)) {
            if (key == "case") {
              reasons.push_back("js-name-conflict");
            }
          }
          std::set<std::string> generics =
              genericNamesInScope(_module, *member);
          _substitutions = substitutionsOf(*member);
          for (const auto& parameter : member->parameters) {
            BridgedType bridged = bridge(parameter.type, generics, reasons);
            if (bridged.bridge == Bridge::Closure) {
              reasons.push_back("closure");
            }
          }
        }
        if (!reasons.empty()) {
          std::sort(reasons.begin(), reasons.end());
          reasons.erase(std::unique(reasons.begin(), reasons.end()),
                        reasons.end());
          capability = make(Tier::Unsupported, "enum-associated-values");
          capability.reasons.insert(capability.reasons.end(), reasons.begin(),
                                    reasons.end());
          changed = true;
        }
      }
    }
  }

  bool isUnavailable(const Symbol& symbol) const {
    for (const Availability* availability :
         applicableAvailability(_module, symbol)) {
      if (availability->isUnconditionallyUnavailable) {
        return true;
      }
    }
    return false;
  }

  Capability classifyOther(const Symbol& symbol) const {
    _substitutions = substitutionsOf(symbol);
    Capability capability;
    switch (symbol.kind) {
      case SymbolKind::Deinitializer:
        return make(Tier::NotApplicable, "deinitializer");
      case SymbolKind::Macro:
        return make(Tier::NotApplicable, "macro");
      case SymbolKind::Extension:
        return make(Tier::NotApplicable, "extension-block");
      case SymbolKind::Unknown:
        return make(Tier::Unsupported, "unknown-kind");
      default:
        break;
    }
    if (commonRejection(symbol, capability)) {
      return capability;
    }
    if (symbol.kind == SymbolKind::TypeAlias) {
      // Declared for TypeScript when what it names bridges.
      Capability alias = make(Tier::TypeOnly, "type-alias");
      if (symbol.aliasedType && symbol.genericParameters.empty()) {
        std::vector<std::string> reasons;
        alias.result = bridge(*symbol.aliasedType,
                              genericNamesInScope(_module, symbol), reasons);
        if (!reasons.empty()) {
          alias.result = BridgedType();
        }
      }
      return alias;
    }
    if (symbol.kind == SymbolKind::AssociatedType) {
      return make(Tier::TypeOnly, "associated-type");
    }

    const Symbol* owner =
        symbol.parentId.empty() ? nullptr : _module.find(symbol.parentId);
    bool isMemberKind = symbol.kind != SymbolKind::Function &&
                        symbol.kind != SymbolKind::Variable;
    if (symbol.parentId.empty() && isMemberKind) {
      // A member whose owner the graph omits (no memberOf edge).
      return make(Tier::Unsupported, "missing-owner");
    }
    if (!symbol.parentId.empty()) {
      if (!owner) {
        return make(Tier::Unsupported, "external-type-extension");
      }
      if (owner->kind == SymbolKind::Protocol) {
        const Capability* protocol = _result.find(owner->preciseId);
        if (!protocol || protocol->tier != Tier::SwiftGenerated) {
          return make(Tier::TypeOnly, "protocol-requirement");
        }
        // Static members need a conforming type, which a value of the
        // protocol does not name.
        if (symbol.isStatic || symbol.kind == SymbolKind::Initializer) {
          return make(Tier::Unsupported, "protocol-static");
        }
      }
      const Capability* ownerCapability = _result.find(owner->preciseId);
      if (!ownerCapability || ownerCapability->tier != Tier::SwiftGenerated) {
        Tier tier =
            ownerCapability && ownerCapability->tier == Tier::SwiftSpecialized
                ? Tier::SwiftSpecialized
                : Tier::Unsupported;
        return make(tier, "owner-not-bridged");
      }
    }

    if (symbol.kind == SymbolKind::Operator) {
      return make(Tier::Unsupported, "operator");
    }
    if (symbol.kind == SymbolKind::InstanceSubscript ||
        symbol.kind == SymbolKind::TypeSubscript) {
      return make(Tier::Unsupported, "subscript");
    }
    if (symbol.kind == SymbolKind::EnumCase) {
      // The owner bridged, so its payloads do (rejectUnbridgedPayloads).
      capability = make(Tier::SwiftGenerated);
      capability.jsName = symbol.baseName;
      std::set<std::string> generics = genericNamesInScope(_module, symbol);
      std::vector<std::string> reasons;
      for (const auto& parameter : symbol.parameters) {
        capability.parameters.push_back(
            bridge(parameter.type, generics, reasons));
      }
      capability.result = bridgeOwner(*owner);
      return capability;
    }

    if (!symbol.genericParameters.empty()) {
      return make(Tier::SwiftSpecialized, "generic");
    }

    // Isolation decides how a call is made, not whether it can be: actor
    // members are awaited from outside their actor, main-actor members run
    // only on the main thread.
    bool nonisolated = hasAttribute(symbol, "nonisolated");
    bool actorIsolated = owner && owner->kind == SymbolKind::Actor &&
                         !nonisolated && !symbol.isStatic &&
                         symbol.kind != SymbolKind::Initializer;
    capability.isAsync = symbol.isAsync || actorIsolated;
    if (capability.isAsync && symbol.kind == SymbolKind::Initializer) {
      // `new` cannot await.
      return make(Tier::Unsupported, "async-initializer");
    }
    capability.isMainActor =
        !nonisolated && (hasAttribute(symbol, "@MainActor") ||
                         (owner && hasAttribute(*owner, "@MainActor")));
    // Another actor's state cannot be assigned from outside it.
    capability.isSettable = symbol.isSettable && !capability.isAsync;

    std::set<std::string> generics = genericNamesInScope(_module, symbol);
    std::vector<std::string> reasons;
    for (const auto& parameter : symbol.parameters) {
      // An async call returns before its arguments' final values exist.
      if (parameter.modifier == "inout" && capability.isAsync) {
        reasons.push_back("inout-parameter");
        continue;
      }
      if (parameter.isVariadic) {
        reasons.push_back("variadic-parameter");
        continue;
      }
      if (std::find(parameter.attributes.begin(), parameter.attributes.end(),
                    "@autoclosure") != parameter.attributes.end()) {
        reasons.push_back("closure");
        continue;
      }
      BridgedType bridged = bridge(parameter.type, generics, reasons);
      if (parameter.modifier == "inout") {
        if (bridged.bridge == Bridge::Closure) {
          reasons.push_back("inout-parameter");
        }
        bridged.isInout = true;
      }
      if (bridged.bridge == Bridge::AsyncSequence) {
        reasons.push_back("async-sequence-parameter");
      }
      if (bridged.bridge == Bridge::Closure) {
        // The declaration parser lifts type attributes onto the parameter;
        // the closure type needs them back (@Sendable, @MainActor).
        TypeNode& node =
            bridged.optional ? bridged.node.children[0] : bridged.node;
        for (const auto& attribute : parameter.attributes) {
          if (attribute == "@escaping") {
            bridged.escaping = true;
          } else if (!node.hasAttribute(attribute)) {
            node.attributes.push_back(attribute);
          }
        }
      }
      capability.parameters.push_back(std::move(bridged));
    }

    if (symbol.kind == SymbolKind::Initializer) {
      // Initializers produce the owner; failable ones may produce nil.
      BridgedType self = bridgeOwner(*owner);
      self.optional = symbol.isFailable;
      capability.result = std::move(self);
    } else if (symbol.valueType) {
      capability.result = bridge(*symbol.valueType, generics, reasons);
      if (capability.result.bridge == Bridge::Closure) {
        reasons.push_back("closure");
      }
    } else if (symbol.returnType) {
      capability.result = bridge(*symbol.returnType, generics, reasons);
      if (capability.result.bridge == Bridge::Closure) {
        reasons.push_back("closure");
      }
    } else {
      capability.result.bridge = Bridge::Void;
    }

    std::sort(reasons.begin(), reasons.end());
    reasons.erase(std::unique(reasons.begin(), reasons.end()), reasons.end());
    if (!reasons.empty()) {
      bool onlyGeneric =
          std::all_of(reasons.begin(), reasons.end(),
                      [](const std::string& r) { return r == "generic"; });
      Capability rejected;
      rejected.tier = onlyGeneric ? Tier::SwiftSpecialized : Tier::Unsupported;
      rejected.reasons = reasons;
      return rejected;
    }

    capability.tier = Tier::SwiftGenerated;
    capability.jsName = symbol.kind == SymbolKind::Initializer
                            ? "constructor"
                            : symbol.baseName;
    if (owner && owner->kind == SymbolKind::Protocol) {
      capability.isRequirement = symbol.isProtocolRequirement;
      // Assigning through a value of a protocol that is not class-bound
      // would change a copy.
      if (!llvm::StringRef(owner->declarationText).contains("AnyObject")) {
        capability.isSettable = false;
      }
    }
    return capability;
  }

  BridgedType bridgeOwner(const Symbol& owner) const {
    BridgedType bridged;
    bridged.symbolId = owner.preciseId;
    bridged.bridge = owner.kind == SymbolKind::Struct      ? Bridge::StructBox
                     : owner.kind != SymbolKind::Enum      ? Bridge::ClassHandle
                     : hasAssociatedValues(_module, owner) ? Bridge::TaggedEnum
                                                           : Bridge::EnumCase;
    TypeNode::Component component;
    component.name = owner.name;
    component.usr = owner.preciseId;
    bridged.node.kind = TypeNode::Kind::Nominal;
    bridged.node.components.push_back(std::move(component));
    return bridged;
  }

  BridgedType bridge(const TypeRef& type, const std::set<std::string>& generics,
                     std::vector<std::string>& reasons) const {
    bool complete = true;
    BridgedType bridged;
    bridged.node =
        substitute(parseType(type, generics, &complete), _substitutions);
    if (!complete) {
      reasons.push_back("unparsed-type");
      return bridged;
    }
    const TypeNode* node = &bridged.node;
    if (node->kind == TypeNode::Kind::Optional ||
        node->kind == TypeNode::Kind::ImplicitlyUnwrappedOptional) {
      bridged.optional = true;
      node = &node->children[0];
      if (node->kind == TypeNode::Kind::Optional ||
          node->kind == TypeNode::Kind::ImplicitlyUnwrappedOptional) {
        reasons.push_back("nested-optional");
        return bridged;
      }
    }
    std::string reason = bridgeNonOptional(*node, bridged);
    if (!reason.empty()) {
      reasons.push_back(reason);
    }
    return bridged;
  }

  // Bridges a collection's element (value) type into `container.elements`.
  std::string bridgeElement(const TypeNode& node,
                            BridgedType& container) const {
    BridgedType element;
    element.node = node;
    if (node.kind == TypeNode::Kind::Optional ||
        node.kind == TypeNode::Kind::ImplicitlyUnwrappedOptional) {
      return "optional-element";
    }
    std::string reason = bridgeNonOptional(node, element);
    if (reason.empty() && element.bridge == Bridge::Void) {
      reason = "unbridged-type:Void";
    }
    if (reason.empty() && element.bridge == Bridge::Closure) {
      reason = "closure";
    }
    if (reason.empty() && element.bridge == Bridge::AsyncSequence) {
      reason = "unbridged-type:AsyncSequence";
    }
    container.elements.push_back(std::move(element));
    return reason;
  }

  // Returns the rejection reason, or "" with `bridged` filled in.
  std::string bridgeNonOptional(const TypeNode& node,
                                BridgedType& bridged) const {
    switch (node.kind) {
      case TypeNode::Kind::Void:
        bridged.bridge = Bridge::Void;
        return "";
      case TypeNode::Kind::GenericParameter:
        if (_template && node.components.size() == 1 &&
            _templateParameters.count(node.components[0].name)) {
          bridged.bridge = Bridge::TypeParameter;
          bridged.objcClass = node.components[0].name;
          return "";
        }
        return "generic";
      case TypeNode::Kind::Function: {
        // JS functions stand in for closures. A caller on another thread
        // waits for the JS thread to run one that returns a value.
        if (node.isAsync) {
          return "closure";
        }
        bridged.bridge = Bridge::Closure;
        bridged.throwing = node.isThrowing;
        if (!node.result.empty() &&
            node.result[0].kind != TypeNode::Kind::Void) {
          BridgedType result;
          result.node = node.result[0];
          const TypeNode* inner = &node.result[0];
          if (inner->kind == TypeNode::Kind::Optional ||
              inner->kind == TypeNode::Kind::ImplicitlyUnwrappedOptional) {
            result.optional = true;
            inner = &inner->children[0];
          }
          std::string reason = bridgeNonOptional(*inner, result);
          if (reason.empty() && (result.bridge == Bridge::Closure ||
                                 result.bridge == Bridge::AsyncSequence)) {
            reason = "closure";
          }
          if (!reason.empty()) {
            return reason;
          }
          bridged.results.push_back(std::move(result));
        }
        for (const auto& parameter : node.children) {
          BridgedType element;
          element.node = parameter;
          const TypeNode* inner = &parameter;
          if (!parameter.modifier.empty()) {
            return "closure";
          }
          if (inner->kind == TypeNode::Kind::Optional ||
              inner->kind == TypeNode::Kind::ImplicitlyUnwrappedOptional) {
            element.optional = true;
            inner = &inner->children[0];
          }
          std::string reason = bridgeNonOptional(*inner, element);
          if (reason.empty() && (element.bridge == Bridge::Void ||
                                 element.bridge == Bridge::Closure)) {
            reason = "closure";
          }
          if (!reason.empty()) {
            return reason;
          }
          bridged.elements.push_back(std::move(element));
        }
        return "";
      }
      case TypeNode::Kind::Tuple:
        return "tuple";
      case TypeNode::Kind::Array:
        bridged.bridge = Bridge::Array;
        return bridgeElement(node.children[0], bridged);
      case TypeNode::Kind::Dictionary: {
        const TypeNode& key = node.children[0];
        if (key.kind != TypeNode::Kind::Nominal ||
            key.usr() != KnownTypes::kString) {
          return "dictionary-key";
        }
        bridged.bridge = Bridge::Dictionary;
        return bridgeElement(node.children[1], bridged);
      }
      case TypeNode::Kind::Existential: {
        const TypeNode* inner =
            node.children.empty() ? nullptr : &node.children[0];
        const Symbol* protocol = inner && inner->kind == TypeNode::Kind::Nominal
                                     ? _module.find(inner->usr())
                                     : nullptr;
        const Capability* capability =
            protocol ? _result.find(protocol->preciseId) : nullptr;
        if (protocol && protocol->kind == SymbolKind::Protocol && capability &&
            capability->tier == Tier::SwiftGenerated) {
          bridged.bridge = Bridge::Protocol;
          bridged.symbolId = protocol->preciseId;
          return "";
        }
        return "existential";
      }
      case TypeNode::Kind::Composition:
        return "existential";
      case TypeNode::Kind::Opaque: {
        // `some AsyncSequence<Element, Failure>`.
        const TypeNode* inner =
            node.children.empty() ? nullptr : &node.children[0];
        if (inner && inner->kind == TypeNode::Kind::Nominal &&
            inner->usr() == KnownTypes::kAsyncSequence &&
            !inner->components.back().arguments.empty()) {
          bridged.bridge = Bridge::AsyncSequence;
          return bridgeElement(inner->components.back().arguments[0], bridged);
        }
        return "opaque-type";
      }
      case TypeNode::Kind::Metatype:
        return "metatype";
      case TypeNode::Kind::Unknown:
        return "unparsed-type";
      case TypeNode::Kind::Optional:
      case TypeNode::Kind::ImplicitlyUnwrappedOptional:
        return "nested-optional";
      case TypeNode::Kind::Nominal:
        break;
    }

    const std::string& usr = node.usr();
    if (node.components.size() == 1 && node.components[0].arguments.empty() &&
        isPrimitive(usr, bridged.bridge)) {
      return "";
    }
    if ((usr == KnownTypes::kAsyncStream ||
         usr == KnownTypes::kAsyncThrowingStream) &&
        !node.components.back().arguments.empty()) {
      bridged.bridge = Bridge::AsyncSequence;
      return bridgeElement(node.components.back().arguments[0], bridged);
    }
    if (usr == KnownTypes::kDate) {
      bridged.bridge = Bridge::Date;
      return "";
    }
    if (usr == KnownTypes::kURL) {
      bridged.bridge = Bridge::URL;
      return "";
    }
    if (usr == KnownTypes::kData) {
      bridged.bridge = Bridge::Data;
      return "";
    }
    // An instantiation the module spells has its own synthetic type.
    const Symbol* target = nullptr;
    const auto& arguments = node.components.empty()
                                ? std::vector<TypeNode>()
                                : node.components.back().arguments;
    if (!usr.empty() && !arguments.empty()) {
      target = _module.find(instantiationKey(node));
      if (target || _template) {
        for (const auto& argument : arguments) {
          BridgedType bridgedArgument;
          bridgedArgument.node = argument;
          const TypeNode* inner = &argument;
          if (argument.kind == TypeNode::Kind::Optional &&
              !argument.children.empty()) {
            bridgedArgument.optional = true;
            inner = &argument.children[0];
          }
          bridgeNonOptional(*inner, bridgedArgument);
          bridged.typeArguments.push_back(std::move(bridgedArgument));
        }
      }
      // A generic type's own declaration refers to its instantiations
      // generically.
      const Symbol* base = _module.find(usr);
      if (!target && _template && base && _families.count(base->preciseId)) {
        bridged.bridge = bridgeOwner(*base).bridge;
        bridged.symbolId = base->preciseId;
        return "";
      }
    }
    if (!target && !usr.empty()) {
      target = _module.find(usr);
    }
    if (target && target->kind == SymbolKind::TypeAlias &&
        target->aliasedType && target->genericParameters.empty()) {
      // A typealias bridges as what it names; Swift code keeps its name.
      bool complete = true;
      TypeNode aliased =
          parseType(*target->aliasedType, genericNamesInScope(_module, *target),
                    &complete);
      if (!complete) {
        return "unparsed-type";
      }
      BridgedType resolved;
      resolved.node = aliased;
      const TypeNode* inner = &aliased;
      if (aliased.kind == TypeNode::Kind::Optional ||
          aliased.kind == TypeNode::Kind::Array ||
          aliased.kind == TypeNode::Kind::Dictionary) {
        return "type-alias";
      }
      std::string reason = bridgeNonOptional(*inner, resolved);
      TypeNode spelled = bridged.node;
      bool optional = bridged.optional;
      bridged = std::move(resolved);
      bridged.node = spelled;
      bridged.optional = optional;
      return reason;
    }
    std::string objcClass = objcClassName(usr, target);
    if (!objcClass.empty()) {
      bridged.bridge = Bridge::ObjCObject;
      bridged.objcClass = objcClass;
      return "";
    }
    if (target) {
      const Capability* capability = _result.find(target->preciseId);
      if (capability && capability->tier == Tier::SwiftGenerated &&
          target->kind == SymbolKind::Protocol) {
        // A bare protocol name is an existential.
        bridged.bridge = Bridge::Protocol;
        bridged.symbolId = target->preciseId;
        return "";
      }
      if (target->kind == SymbolKind::Protocol) {
        return "existential";
      }
      if (capability && capability->tier == Tier::SwiftGenerated) {
        bridged.bridge = bridgeOwner(*target).bridge;
        bridged.symbolId = target->preciseId;
        return "";
      }
      return "unbridged-type:" + llvm::join(target->pathComponents, ".");
    }
    auto name = _module.externalNames.find(usr);
    if (name != _module.externalNames.end()) {
      return "unbridged-type:" + name->second;
    }
    std::string qualified = qualifiedNameFromUSR(usr);
    return "unbridged-type:" + (qualified.empty() ? spelling(node) : qualified);
  }

  // The runtime name of the Objective-C class `usr` names, or "" when it
  // names no class. Swift classes keep their module-qualified name unless
  // they declare @objc(Name).
  std::string objcClassName(const std::string& usr,
                            const Symbol* target) const {
    llvm::StringRef ref(usr);
    if (ref.consume_front("c:objc(cs)")) {
      return ref.str();
    }
    size_t marker = ref.find("@objc(cs)");
    if (!ref.startswith("c:@M@") || marker == llvm::StringRef::npos) {
      return "";
    }
    if (target) {
      for (const auto& attribute : target->attributes) {
        llvm::StringRef text(attribute);
        if (text.consume_front("@objc(") && text.consume_back(")")) {
          return text.str();
        }
      }
    }
    llvm::StringRef module = ref.substr(5).split('@').first;
    return module.str() + "." + ref.substr(marker + 9).str();
  }

  // JS names for SwiftGenerated members and overload ambiguity.
  void resolveNames() {
    struct Entry {
      std::string id;
      bool isProperty;
      std::string signature;
    };
    std::map<std::tuple<std::string, std::string, bool>, std::vector<Entry>>
        groups;
    for (auto& entry : _result.bySymbol) {
      Capability& capability = entry.second;
      if (capability.tier != Tier::SwiftGenerated ||
          capability.jsName.empty()) {
        continue;
      }
      const Symbol* symbol = _module.find(entry.first);
      bool isProperty = symbol->kind == SymbolKind::InstanceProperty ||
                        symbol->kind == SymbolKind::TypeProperty ||
                        symbol->kind == SymbolKind::Variable ||
                        symbol->kind == SymbolKind::EnumCase;
      bool isStatic = symbol->isStatic ||
                      symbol->kind == SymbolKind::EnumCase ||
                      symbol->kind == SymbolKind::Initializer;
      std::string signature = std::to_string(capability.parameters.size());
      for (const auto& parameter : capability.parameters) {
        signature += "," + jsKind(parameter);
      }
      groups[{symbol->parentId, capability.jsName, isStatic}].push_back(
          Entry{entry.first, isProperty, signature});
    }

    for (auto& group : groups) {
      auto& entries = group.second;
      bool hasProperty =
          std::any_of(entries.begin(), entries.end(),
                      [](const Entry& e) { return e.isProperty; });
      for (const auto& entry : entries) {
        Capability& capability = _result.bySymbol[entry.id];
        if (hasProperty && entries.size() > 1) {
          // A JS property and method cannot share a key; the property wins.
          if (!entry.isProperty) {
            capability.tier = Tier::Unsupported;
            capability.reasons = {"js-name-conflict"};
            capability.jsName.clear();
            capability.parameters.clear();
          }
          continue;
        }
        for (const auto& other : entries) {
          if (&other != &entry && other.signature == entry.signature) {
            capability.ambiguousOverload = true;
          }
        }
      }
    }
  }

  static std::string jsKind(const BridgedType& type) {
    if (type.isInout) {
      return "record";
    }
    std::string kind;
    switch (type.bridge) {
      case Bridge::Bool:
        kind = "boolean";
        break;
      case Bridge::Integer:
      case Bridge::Floating:
        kind = "number";
        break;
      case Bridge::String:
      case Bridge::EnumCase:
        kind = "string";
        break;
      case Bridge::ClassHandle:
      case Bridge::StructBox:
        kind = "object:" + type.symbolId;
        break;
      case Bridge::URL:
        // A URL parameter also accepts a string.
        kind = "string";
        break;
      case Bridge::Date:
        kind = "date";
        break;
      case Bridge::Data:
        kind = "bytes";
        break;
      case Bridge::Array:
        kind = "array";
        break;
      case Bridge::Dictionary:
      case Bridge::TaggedEnum:
        kind = "record";
        break;
      case Bridge::Closure:
        kind = "function";
        break;
      case Bridge::ObjCObject:
        kind = "objc";
        break;
      case Bridge::Protocol:
        kind = "object:" + type.symbolId;
        break;
      case Bridge::AsyncSequence:
        kind = "async-iterable";
        break;
      default:
        kind = "other";
        break;
    }
    return type.optional ? kind + "?" : kind;
  }

  // Generic types with generated instantiations, and their members'
  // template capabilities.
  void classifyTemplates() {
    for (const auto& entry : _module.symbols) {
      const Symbol& symbol = entry.second;
      const Capability* capability = _result.find(entry.first);
      if (!symbol.genericBase.empty() && isNominalType(symbol.kind) &&
          capability && capability->tier == Tier::SwiftGenerated) {
        _families.insert(symbol.genericBase);
      }
    }
    for (const auto& id : _families) {
      const Symbol* base = _module.find(id);
      if (!base) {
        continue;
      }
      _template = true;
      _templateParameters.clear();
      for (const auto& parameter : base->genericParameters) {
        _templateParameters.insert(parameter.name);
      }
      _substitutions.clear();
      for (const auto& memberId : base->memberIds) {
        const Symbol* member = _module.find(memberId);
        if (!member || isNominalType(member->kind)) {
          continue;
        }
        Capability capability;
        capability.tier = Tier::SwiftGenerated;
        capability.jsName = member->kind == SymbolKind::Initializer
                                ? "constructor"
                                : member->baseName;
        std::set<std::string> generics = genericNamesInScope(_module, *member);
        std::vector<std::string> reasons;
        for (const auto& parameter : member->parameters) {
          BridgedType bridged = bridge(parameter.type, generics, reasons);
          bridged.isInout = parameter.modifier == "inout";
          capability.parameters.push_back(std::move(bridged));
        }
        if (member->kind == SymbolKind::Initializer ||
            member->kind == SymbolKind::EnumCase) {
          capability.result = bridgeOwner(*base);
        } else if (member->valueType) {
          capability.result = bridge(*member->valueType, generics, reasons);
        } else if (member->returnType) {
          capability.result = bridge(*member->returnType, generics, reasons);
        } else {
          capability.result.bridge = Bridge::Void;
        }
        _result.templates[memberId] = std::move(capability);
      }
    }
    _template = false;
  }

  // An instantiation's generic parameters and their arguments, for `symbol`
  // and its enclosing types.
  std::vector<std::pair<std::string, TypeNode>> substitutionsOf(
      const Symbol& symbol) const {
    std::vector<std::pair<std::string, TypeNode>> result;
    for (const Symbol* current = &symbol; current;
         current = current->parentId.empty()
                       ? nullptr
                       : _module.find(current->parentId)) {
      result.insert(result.end(), current->substitutions.begin(),
                    current->substitutions.end());
    }
    return result;
  }

  const Module& _module;
  const std::map<std::string, std::string>& _rejections;
  Classification _result;
  // Those of the declaration being classified (see substitutionsOf).
  mutable std::vector<std::pair<std::string, TypeNode>> _substitutions;
  // classifyTemplates: bridging a generic type's own declarations.
  bool _template = false;
  std::set<std::string> _templateParameters;
  std::set<std::string> _families;
};

}  // namespace

std::vector<const Availability*> applicableAvailability(const Module& module,
                                                        const Symbol& symbol) {
  std::string domain = availabilityDomain(module.platform);
  std::vector<const Availability*> result;
  for (const auto& availability : symbol.availability) {
    if (availability.domain == "*" || availability.domain == domain) {
      result.push_back(&availability);
    }
  }
  return result;
}

Classification classify(const Module& module,
                        const std::map<std::string, std::string>& rejections) {
  return Classifier(module, rejections).run();
}

}  // namespace Swift
