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
    for (const auto& entry : _module.symbols) {
      if (!isNominalType(entry.second.kind)) {
        _result.bySymbol[entry.first] = classifyOther(entry.second);
      }
    }
    resolveNames();
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
      return make(Tier::TypeOnly, "protocol");
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
    if (symbol.kind == SymbolKind::Enum) {
      for (const auto& id : symbol.memberIds) {
        const Symbol* member = _module.find(id);
        if (member && member->kind == SymbolKind::EnumCase &&
            !member->parameters.empty()) {
          return make(Tier::Unsupported, "enum-associated-values");
        }
      }
    }
    return make(Tier::SwiftGenerated);
  }

  Capability classifyOther(const Symbol& symbol) const {
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
      return make(Tier::TypeOnly, "type-alias");
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
        return make(Tier::TypeOnly, "protocol-requirement");
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
      // Only payload-less enums are bridged (see classifyType).
      capability = make(Tier::SwiftGenerated);
      capability.jsName = symbol.baseName;
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
      if (parameter.modifier == "inout") {
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
    return capability;
  }

  BridgedType bridgeOwner(const Symbol& owner) const {
    BridgedType bridged;
    bridged.symbolId = owner.preciseId;
    bridged.bridge = owner.kind == SymbolKind::Struct ? Bridge::StructBox
                     : owner.kind == SymbolKind::Enum ? Bridge::EnumCase
                                                      : Bridge::ClassHandle;
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
    bridged.node = parseType(type, generics, &complete);
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
        return "generic";
      case TypeNode::Kind::Function: {
        // JS functions stand in for closures that return nothing: a Swift
        // caller cannot wait for a value from another thread's JS.
        if (node.isAsync || node.isThrowing ||
            (!node.result.empty() &&
             node.result[0].kind != TypeNode::Kind::Void)) {
          return "closure";
        }
        bridged.bridge = Bridge::Closure;
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
      case TypeNode::Kind::Existential:
      case TypeNode::Kind::Composition:
        return "existential";
      case TypeNode::Kind::Opaque:
        return "opaque-type";
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
    const Symbol* target = usr.empty() ? nullptr : _module.find(usr);
    if (target) {
      const Capability* capability = _result.find(target->preciseId);
      if (capability && capability->tier == Tier::SwiftGenerated &&
          target->kind != SymbolKind::Protocol) {
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
        kind = "record";
        break;
      case Bridge::Closure:
        kind = "function";
        break;
      default:
        kind = "other";
        break;
    }
    return type.optional ? kind + "?" : kind;
  }

  const Module& _module;
  const std::map<std::string, std::string>& _rejections;
  Classification _result;
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
