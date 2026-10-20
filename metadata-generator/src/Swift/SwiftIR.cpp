#include "SwiftIR.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/raw_ostream.h>

namespace Swift {

const char* toString(SymbolKind kind) {
  switch (kind) {
    case SymbolKind::Class:
      return "class";
    case SymbolKind::Actor:
      return "actor";
    case SymbolKind::Struct:
      return "struct";
    case SymbolKind::Enum:
      return "enum";
    case SymbolKind::Protocol:
      return "protocol";
    case SymbolKind::EnumCase:
      return "enumCase";
    case SymbolKind::Initializer:
      return "initializer";
    case SymbolKind::Deinitializer:
      return "deinitializer";
    case SymbolKind::InstanceMethod:
      return "instanceMethod";
    case SymbolKind::TypeMethod:
      return "typeMethod";
    case SymbolKind::Operator:
      return "operator";
    case SymbolKind::InstanceProperty:
      return "instanceProperty";
    case SymbolKind::TypeProperty:
      return "typeProperty";
    case SymbolKind::InstanceSubscript:
      return "instanceSubscript";
    case SymbolKind::TypeSubscript:
      return "typeSubscript";
    case SymbolKind::Function:
      return "function";
    case SymbolKind::Variable:
      return "variable";
    case SymbolKind::TypeAlias:
      return "typeAlias";
    case SymbolKind::AssociatedType:
      return "associatedType";
    case SymbolKind::Macro:
      return "macro";
    case SymbolKind::Extension:
      return "extension";
    case SymbolKind::Unknown:
      return "unknown";
  }
  return "unknown";
}

bool isNominalType(SymbolKind kind) {
  switch (kind) {
    case SymbolKind::Class:
    case SymbolKind::Actor:
    case SymbolKind::Struct:
    case SymbolKind::Enum:
    case SymbolKind::Protocol:
      return true;
    default:
      return false;
  }
}

const char* toString(AccessLevel level) {
  switch (level) {
    case AccessLevel::Private:
      return "private";
    case AccessLevel::FilePrivate:
      return "fileprivate";
    case AccessLevel::Internal:
      return "internal";
    case AccessLevel::Package:
      return "package";
    case AccessLevel::Public:
      return "public";
    case AccessLevel::Open:
      return "open";
    case AccessLevel::Unknown:
      return "unknown";
  }
  return "unknown";
}

const Symbol* Module::find(const std::string& preciseId) const {
  auto it = symbols.find(preciseId);
  return it == symbols.end() ? nullptr : &it->second;
}

bool ModuleSet::hasErrors() const {
  for (const auto& diagnostic : diagnostics) {
    if (diagnostic.severity == Severity::Error) {
      return true;
    }
  }
  return false;
}

namespace {

using llvm::json::OStream;

std::string versionString(const Version& version) {
  return std::to_string(version.major) + "." + std::to_string(version.minor) +
         "." + std::to_string(version.patch);
}

void writeStringArray(OStream& out, llvm::StringRef key,
                      const std::vector<std::string>& values) {
  if (values.empty()) {
    return;
  }
  out.attributeArray(key, [&] {
    for (const auto& value : values) {
      out.value(value);
    }
  });
}

void writeNonEmpty(OStream& out, llvm::StringRef key,
                   const std::string& value) {
  if (!value.empty()) {
    out.attribute(key, value);
  }
}

void writeFlag(OStream& out, llvm::StringRef key, bool value) {
  if (value) {
    out.attribute(key, true);
  }
}

void writeTypeRef(OStream& out, llvm::StringRef key, const TypeRef& type) {
  out.attributeObject(key, [&] {
    out.attribute("spelling", type.spelling);
    std::vector<std::string> references;
    for (const auto& fragment : type.fragments) {
      if (!fragment.preciseIdentifier.empty()) {
        references.push_back(fragment.preciseIdentifier);
      }
    }
    writeStringArray(out, "references", references);
  });
}

void writeConstraints(OStream& out, llvm::StringRef key,
                      const std::vector<GenericConstraint>& constraints) {
  if (constraints.empty()) {
    return;
  }
  out.attributeArray(key, [&] {
    for (const auto& constraint : constraints) {
      out.object([&] {
        out.attribute("kind", constraint.kind);
        out.attribute("lhs", constraint.lhs);
        out.attribute("rhs", constraint.rhs);
        writeNonEmpty(out, "rhsPrecise", constraint.rhsPrecise);
      });
    }
  });
}

void writeSymbol(OStream& out, const Symbol& symbol) {
  out.object([&] {
    out.attribute("id", symbol.preciseId);
    out.attribute("kind", toString(symbol.kind));
    out.attribute("path", llvm::join(symbol.pathComponents, "."));
    out.attribute("name", symbol.name);
    out.attribute("access", toString(symbol.access));
    out.attribute("declaration", symbol.declarationText);
    writeStringArray(out, "attributes", symbol.attributes);
    writeStringArray(out, "modifiers", symbol.modifiers);
    writeFlag(out, "static", symbol.isStatic);
    writeFlag(out, "synthesized", symbol.isSynthesized);
    writeFlag(out, "protocolRequirement", symbol.isProtocolRequirement);
    writeFlag(out, "optionalRequirement", symbol.isOptionalRequirement);

    if (!symbol.parameters.empty()) {
      out.attributeArray("parameters", [&] {
        for (const auto& parameter : symbol.parameters) {
          out.object([&] {
            writeNonEmpty(out, "label", parameter.label);
            writeNonEmpty(out, "internalName", parameter.internalName);
            writeTypeRef(out, "type", parameter.type);
            writeNonEmpty(out, "modifier", parameter.modifier);
            writeStringArray(out, "attributes", parameter.attributes);
            writeNonEmpty(out, "default", parameter.defaultValue);
            writeFlag(out, "variadic", parameter.isVariadic);
          });
        }
      });
    }
    if (symbol.returnType) {
      writeTypeRef(out, "returns", *symbol.returnType);
    }
    writeFlag(out, "async", symbol.isAsync);
    writeFlag(out, "throws", symbol.isThrowing);
    writeFlag(out, "rethrows", symbol.isRethrowing);
    if (!symbol.thrownType.empty()) {
      writeTypeRef(out, "thrownType", symbol.thrownType);
    }
    writeFlag(out, "failable", symbol.isFailable);
    writeFlag(out, "implicitlyUnwrappedFailable",
              symbol.isImplicitlyUnwrappedFailable);
    if (symbol.valueType) {
      writeTypeRef(out, "valueType", *symbol.valueType);
      out.attribute("settable", symbol.isSettable);
      writeFlag(out, "let", symbol.isLet);
    }
    if (symbol.aliasedType) {
      writeTypeRef(out, "aliasedType", *symbol.aliasedType);
    }

    if (!symbol.genericParameters.empty()) {
      out.attributeArray("genericParameters", [&] {
        for (const auto& parameter : symbol.genericParameters) {
          out.object([&] {
            out.attribute("name", parameter.name);
            out.attribute("depth", parameter.depth);
            out.attribute("index", parameter.index);
          });
        }
      });
    }
    writeConstraints(out, "genericConstraints", symbol.genericConstraints);

    if (symbol.extension) {
      out.attributeObject("extension", [&] {
        out.attribute("extendedModule", symbol.extension->extendedModule);
        writeNonEmpty(out, "typeKind", symbol.extension->typeKind);
        writeConstraints(out, "constraints", symbol.extension->constraints);
      });
    }

    if (!symbol.availability.empty()) {
      out.attributeArray("availability", [&] {
        for (const auto& availability : symbol.availability) {
          out.object([&] {
            out.attribute("domain", availability.domain);
            if (availability.introduced) {
              out.attribute("introduced",
                            versionString(*availability.introduced));
            }
            if (availability.deprecated) {
              out.attribute("deprecated",
                            versionString(*availability.deprecated));
            }
            if (availability.obsoleted) {
              out.attribute("obsoleted",
                            versionString(*availability.obsoleted));
            }
            writeNonEmpty(out, "message", availability.message);
            writeNonEmpty(out, "renamed", availability.renamed);
            writeFlag(out, "unconditionallyDeprecated",
                      availability.isUnconditionallyDeprecated);
            writeFlag(out, "unconditionallyUnavailable",
                      availability.isUnconditionallyUnavailable);
          });
        }
      });
    }

    if (symbol.location) {
      out.attribute("location", symbol.location->uri + ":" +
                                    std::to_string(symbol.location->line) +
                                    ":" +
                                    std::to_string(symbol.location->character));
    }
    out.attribute("graph", symbol.sourceGraph);

    writeNonEmpty(out, "parent", symbol.parentId);
    writeStringArray(out, "members", symbol.memberIds);
    writeStringArray(out, "conformances", symbol.conformances);
    writeNonEmpty(out, "superclass", symbol.superclassId);
    writeNonEmpty(out, "overrides", symbol.overriddenId);
    writeNonEmpty(out, "sourceOrigin", symbol.sourceOriginId);
    writeStringArray(out, "defaultImplementationOf",
                     symbol.defaultImplementationOf);
  });
}

}  // namespace

std::string dumpModuleJSON(const Module& module) {
  std::string result;
  llvm::raw_string_ostream stream(result);
  OStream out(stream, 2);
  out.object([&] {
    out.attribute("module", module.name);
    out.attribute("formatVersion", versionString(module.formatVersion));
    out.attributeObject("platform", [&] {
      writeNonEmpty(out, "architecture", module.platform.architecture);
      writeNonEmpty(out, "vendor", module.platform.vendor);
      writeNonEmpty(out, "operatingSystem", module.platform.operatingSystem);
      writeNonEmpty(out, "environment", module.platform.environment);
      if (module.platform.minimumVersion) {
        out.attribute("minimumVersion",
                      versionString(*module.platform.minimumVersion));
      }
    });
    writeStringArray(out, "graphFiles", module.graphFiles);
    writeStringArray(out, "topLevel", module.topLevelIds);

    out.attributeArray("externalTypes", [&] {
      for (const auto& entry : module.externalTypes) {
        const auto& external = entry.second;
        out.object([&] {
          out.attribute("id", external.preciseId);
          out.attribute("qualifiedName", external.qualifiedName);
          writeNonEmpty(out, "extendedModule", external.extendedModule);
          writeNonEmpty(out, "typeKind", external.typeKind);
          writeStringArray(out, "members", external.memberIds);
          writeStringArray(out, "conformances", external.conformances);
        });
      }
    });

    out.attributeObject("externalNames", [&] {
      for (const auto& entry : module.externalNames) {
        out.attribute(entry.first, entry.second);
      }
    });

    out.attributeArray("symbols", [&] {
      for (const auto& entry : module.symbols) {
        writeSymbol(out, entry.second);
      }
    });
  });
  stream << "\n";
  stream.flush();
  return result;
}

}  // namespace Swift
