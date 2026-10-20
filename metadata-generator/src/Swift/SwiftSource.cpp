#include "SwiftSource.h"

#include <llvm/ADT/StringExtras.h>

#include <cstring>
#include <set>
#include <tuple>

#include "SwiftSurface.h"

namespace Swift {

std::string declaringModuleName(const Module& module, const Symbol& symbol) {
  if (!symbol.declaringModule.empty()) {
    return symbol.declaringModule;
  }
  return symbol.module.empty() ? module.name : symbol.module;
}

std::string qualifiedTypeName(const Module& module, const Symbol& symbol) {
  std::string name = declaringModuleName(module, symbol) + "." +
                     llvm::join(symbol.pathComponents, ".");
  if (!symbol.typeArguments.empty()) {
    std::vector<std::string> arguments;
    for (const auto& argument : symbol.typeArguments) {
      arguments.push_back(swiftTypeText(argument, module));
    }
    name += "<" + llvm::join(arguments, ", ") + ">";
  }
  return name;
}

namespace {

TypeNode qualify(const TypeNode& node, const Module& module) {
  TypeNode result = node;
  for (auto& child : result.children) {
    child = qualify(child, module);
  }
  for (auto& child : result.result) {
    child = qualify(child, module);
  }
  for (auto& child : result.thrownType) {
    child = qualify(child, module);
  }
  for (auto& component : result.components) {
    for (auto& argument : component.arguments) {
      argument = qualify(argument, module);
    }
  }
  if (result.kind == TypeNode::Kind::Nominal) {
    const Symbol* symbol = module.find(result.usr());
    if (symbol && isNominalType(symbol->kind)) {
      std::vector<TypeNode::Component> components;
      components.push_back(
          TypeNode::Component{declaringModuleName(module, *symbol), "", {}});
      for (const auto& name : symbol->pathComponents) {
        components.push_back(TypeNode::Component{name, "", {}});
      }
      components.back().usr = symbol->preciseId;
      components.back().arguments = result.components.back().arguments;
      if (components.back().arguments.empty()) {
        // A reference to an instantiation by its id.
        for (const auto& argument : symbol->typeArguments) {
          components.back().arguments.push_back(qualify(argument, module));
        }
      }
      result.components = std::move(components);
    }
  }
  return result;
}

std::string ownerTypeText(const Module& module, const Symbol& owner) {
  return (owner.kind == SymbolKind::Protocol ? "any " : "") +
         qualifiedTypeName(module, owner);
}

std::string typeText(const BridgedType& bridged, const Module& module) {
  if (bridged.bridge == Bridge::Void) {
    return "Void";
  }
  return swiftTypeText(bridged.node, module);
}

bool isAfter(const Version& a, const Version& b) {
  return std::tie(a.major, a.minor, a.patch) >
         std::tie(b.major, b.minor, b.patch);
}

std::string platformName(const Module& module) {
  const std::string& os = module.platform.operatingSystem;
  if (os == "ios") {
    return module.platform.environment == "macabi" ? "macCatalyst" : "iOS";
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
  return os;
}

}  // namespace

std::string swiftTypeText(const TypeNode& node, const Module& module) {
  return spelling(qualify(node, module));
}

std::string swiftIdentifier(const std::string& name) {
  return "`" + name + "`";
}

std::string availabilityCondition(const Module& module, const Symbol& symbol) {
  // Members inherit their enclosing types' availability.
  const Version* introduced = nullptr;
  for (const Symbol* current = &symbol; current;
       current = current->parentId.empty() ? nullptr
                                           : module.find(current->parentId)) {
    for (const Availability* availability :
         applicableAvailability(module, *current)) {
      if (availability->introduced &&
          (!introduced || isAfter(*availability->introduced, *introduced))) {
        introduced = &*availability->introduced;
      }
    }
  }
  if (!introduced || (module.platform.minimumVersion &&
                      !isAfter(*introduced, *module.platform.minimumVersion))) {
    return "";
  }
  return platformName(module) + " " + std::to_string(introduced->major) + "." +
         std::to_string(introduced->minor) +
         (introduced->patch ? "." + std::to_string(introduced->patch) : "") +
         ", *";
}

namespace {

// Symbol graphs do not say which module declares an Objective-C class; its
// prefix usually does. A wrong guess fails compiler verification.
const char* frameworkOfObjCClass(llvm::StringRef name) {
  static const std::pair<const char*, const char*> prefixes[] = {
      {"UI", "UIKit"},
      {"NSManaged", "CoreData"},
      {"NSPersistent", "CoreData"},
      {"NSFetch", "CoreData"},
      {"NSEntity", "CoreData"},
      {"NS", "Foundation"},
      {"CL", "CoreLocation"},
      {"AV", "AVFoundation"},
      {"MK", "MapKit"},
      {"CA", "QuartzCore"},
      {"WK", "WebKit"},
      {"PH", "Photos"},
      {"CN", "Contacts"},
      {"EK", "EventKit"},
      {"HK", "HealthKit"},
      {"GK", "GameKit"},
      {"SCN", "SceneKit"},
      {"SK", "SpriteKit"},
      {"MTL", "Metal"},
      {"MTK", "MetalKit"},
      {"AR", "ARKit"},
      {"CB", "CoreBluetooth"},
      {"CM", "CoreMotion"},
      {"CK", "CloudKit"},
      {"PK", "PassKit"},
      {"SF", "SafariServices"},
      {"UN", "UserNotifications"},
      {"VN", "Vision"},
      {"ML", "CoreML"},
      {"WC", "WatchConnectivity"},
  };
  const char* best = nullptr;
  size_t length = 0;
  for (const auto& prefix : prefixes) {
    size_t size = strlen(prefix.first);
    if (size > length && name.startswith(prefix.first) && name.size() > size &&
        name[size] >= 'A' && name[size] <= 'Z') {
      best = prefix.second;
      length = size;
    }
  }
  return best;
}

void collectObjCClasses(const BridgedType& type, std::set<std::string>& out) {
  if (type.bridge == Bridge::ObjCObject &&
      type.objcClass.find('.') == std::string::npos) {
    out.insert(type.objcClass);
  }
  for (const auto& element : type.elements) {
    collectObjCClasses(element, out);
  }
}

}  // namespace

std::string swiftImports(const Module& module,
                         const Classification& classification) {
  std::set<std::string> overlays;
  std::set<std::string> classes;
  for (const auto& entry : module.symbols) {
    const Capability* capability = classification.find(entry.first);
    if (!capability || capability->tier != Tier::SwiftGenerated) {
      continue;
    }
    if (!entry.second.declaringModule.empty()) {
      overlays.insert(entry.second.declaringModule);
    }
    for (const auto& parameter : capability->parameters) {
      collectObjCClasses(parameter, classes);
    }
    collectObjCClasses(capability->result, classes);
  }
  std::set<std::string> frameworks;
  for (const auto& entry : module.symbols) {
    const Capability* capability = classification.find(entry.first);
    if (capability && capability->tier == Tier::SwiftGenerated &&
        entry.second.kind == SymbolKind::Struct &&
        isSwiftUIView(entry.second)) {
      // hostingController() (SwiftSurface).
      frameworks.insert("SwiftUI");
      frameworks.insert("UIKit");
    }
  }
  for (const auto& name : classes) {
    const char* framework = frameworkOfObjCClass(name);
    if (framework && llvm::StringRef(framework) != "Foundation" &&
        !overlays.count(framework)) {
      frameworks.insert(framework);
    }
  }
  std::string out;
  for (const auto& name : module.swiftModules()) {
    out += "import " + name + "\n";
  }
  for (const auto& overlay : overlays) {
    out += "import " + overlay + "\n";
  }
  for (const auto& framework : frameworks) {
    out +=
        "#if canImport(" + framework + ")\nimport " + framework + "\n#endif\n";
  }
  return out;
}

Invocation describeInvocation(const Module& module, const Symbol& symbol,
                              const Capability& capability) {
  Invocation invocation;
  const Symbol* owner =
      symbol.parentId.empty() ? nullptr : module.find(symbol.parentId);
  invocation.owner = owner ? ownerTypeText(module, *owner)
                           : declaringModuleName(module, symbol);
  invocation.member = symbol.baseName;
  invocation.isThrowing = symbol.isThrowing;
  invocation.isAsync = capability.isAsync;
  invocation.isMainActor = capability.isMainActor && !capability.isAsync;
  invocation.isSettable = capability.isSettable;

  for (size_t i = 0; i < symbol.parameters.size(); i++) {
    invocation.labels.push_back(symbol.parameters[i].label);
    std::string type = i < capability.parameters.size()
                           ? typeText(capability.parameters[i], module)
                           : "";
    bool isInout =
        i < capability.parameters.size() && capability.parameters[i].isInout;
    if (i < capability.parameters.size() && capability.parameters[i].escaping) {
      type = "@escaping " + type;
    }
    invocation.parameterTypes.push_back(isInout ? "inout " + type : type);
    invocation.inoutParameters.push_back(isInout);
  }

  bool valueOwner = owner && (owner->kind == SymbolKind::Struct ||
                              owner->kind == SymbolKind::Enum);
  bool mutating = std::find(symbol.modifiers.begin(), symbol.modifiers.end(),
                            "mutating") != symbol.modifiers.end();

  switch (symbol.kind) {
    case SymbolKind::Initializer:
      invocation.form = Invocation::Form::Construct;
      invocation.resultType = invocation.owner + (symbol.isFailable ? "?" : "");
      break;
    case SymbolKind::InstanceMethod:
      invocation.form = Invocation::Form::InstanceMethod;
      invocation.needsReceiver = true;
      invocation.receiverIsInout = valueOwner && mutating;
      break;
    case SymbolKind::TypeMethod:
      invocation.form = Invocation::Form::StaticMethod;
      break;
    case SymbolKind::Function:
      invocation.form = Invocation::Form::Function;
      break;
    case SymbolKind::InstanceProperty:
      invocation.form = Invocation::Form::InstanceProperty;
      invocation.needsReceiver = true;
      invocation.receiverIsInout = valueOwner && symbol.isSettable;
      break;
    case SymbolKind::TypeProperty:
      invocation.form = Invocation::Form::StaticProperty;
      break;
    case SymbolKind::Variable:
      invocation.form = Invocation::Form::Variable;
      break;
    case SymbolKind::EnumCase:
      invocation.form = Invocation::Form::EnumCase;
      invocation.resultType = invocation.owner;
      break;
    default:
      break;
  }
  if (invocation.resultType.empty()) {
    invocation.resultType = typeText(capability.result, module);
  }

  invocation.availability = availabilityCondition(module, symbol);
  return invocation;
}

std::string invocationExpression(const Invocation& invocation,
                                 const std::string& receiver,
                                 const std::vector<std::string>& arguments) {
  std::string argumentList;
  for (size_t i = 0; i < arguments.size(); i++) {
    if (i > 0) {
      argumentList += ", ";
    }
    const std::string& label =
        i < invocation.labels.size() ? invocation.labels[i] : "";
    std::string argument =
        (i < invocation.inoutParameters.size() && invocation.inoutParameters[i]
             ? "&"
             : "") +
        arguments[i];
    argumentList += label.empty() ? argument : label + ": " + argument;
  }

  std::string expression;
  std::string member = swiftIdentifier(invocation.member);
  switch (invocation.form) {
    case Invocation::Form::Construct:
      expression = invocation.owner + "(" + argumentList + ")";
      break;
    case Invocation::Form::InstanceMethod:
      expression = receiver + "." + member + "(" + argumentList + ")";
      break;
    case Invocation::Form::StaticMethod:
    case Invocation::Form::Function:
      expression = invocation.owner + "." + member + "(" + argumentList + ")";
      break;
    case Invocation::Form::InstanceProperty:
      expression = receiver + "." + member;
      break;
    case Invocation::Form::StaticProperty:
    case Invocation::Form::Variable:
      expression = invocation.owner + "." + member;
      break;
    case Invocation::Form::EnumCase:
      expression = invocation.owner + "." + member +
                   (arguments.empty() ? "" : "(" + argumentList + ")");
      break;
  }
  std::string effects = std::string(invocation.isThrowing ? "try " : "") +
                        (invocation.isAsync ? "await " : "");
  return effects + expression;
}

std::string assignmentStatement(const Invocation& invocation,
                                const std::string& receiver,
                                const std::string& value) {
  std::string target = invocation.form == Invocation::Form::InstanceProperty
                           ? receiver
                           : invocation.owner;
  return target + "." + swiftIdentifier(invocation.member) + " = " + value;
}

}  // namespace Swift
