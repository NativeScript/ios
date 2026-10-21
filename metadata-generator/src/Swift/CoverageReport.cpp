#include "CoverageReport.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/raw_ostream.h>

#include <map>
#include <set>

namespace Swift {

namespace {

const Tier kTiers[] = {Tier::ObjCDirect,       Tier::SwiftGenerated,
                       Tier::SwiftSpecialized, Tier::TypeOnly,
                       Tier::Unsupported,      Tier::NotApplicable};

struct Counts {
  std::map<Tier, int> byTier;
  int total = 0;

  void add(Tier tier) {
    byTier[tier]++;
    total++;
  }
};

void writeCounts(llvm::json::OStream& out, const Counts& counts) {
  out.attribute("total", counts.total);
  for (Tier tier : kTiers) {
    auto it = counts.byTier.find(tier);
    out.attribute(toString(tier), it == counts.byTier.end() ? 0 : it->second);
  }
}

// A generic function's synthetic instantiation (see instantiateGenerics).
bool isFunctionInstantiation(const Symbol& symbol) {
  return !isNominalType(symbol.kind) && !symbol.substitutions.empty();
}

}  // namespace

std::string coverageJSON(const Module& module,
                         const Classification& classification,
                         int compilerRuns) {
  Counts declarations;
  Counts callable;
  std::map<std::string, Counts> byKind;
  std::map<std::string, int> reasons;

  // Instantiations count as their generic function: generated when any of
  // them is.
  std::set<std::string> instantiated;
  for (const auto& entry : module.symbols) {
    const Capability* capability = classification.find(entry.first);
    if (isFunctionInstantiation(entry.second) && capability &&
        capability->tier == Tier::SwiftGenerated) {
      instantiated.insert(entry.second.genericBase);
    }
  }
  auto tierOf = [&](const Symbol& symbol, const Capability& capability) {
    return instantiated.count(symbol.preciseId) ? Tier::SwiftGenerated
                                                : capability.tier;
  };

  for (const auto& entry : module.symbols) {
    const Symbol& symbol = entry.second;
    const Capability* capability = classification.find(entry.first);
    if (!capability || isFunctionInstantiation(symbol)) {
      continue;
    }
    Tier tier = tierOf(symbol, *capability);
    declarations.add(tier);
    byKind[toString(symbol.kind)].add(tier);
    if (isCallableKind(symbol.kind)) {
      callable.add(tier);
    }
    if (tier == Tier::Unsupported || tier == Tier::SwiftSpecialized) {
      for (const auto& reason : capability->reasons) {
        reasons[llvm::StringRef(reason).split(':').first.str()]++;
      }
    }
  }

  std::string result;
  llvm::raw_string_ostream stream(result);
  llvm::json::OStream out(stream, 2);
  out.object([&] {
    out.attribute("module", module.name);
    out.attributeObject("totals", [&] {
      out.attributeObject("declarations",
                          [&] { writeCounts(out, declarations); });
      out.attributeObject("callable", [&] { writeCounts(out, callable); });
      // Callable through any path: the Objective-C runtime or a thunk.
      out.attribute("effectiveCallable",
                    callable.byTier[Tier::ObjCDirect] +
                        callable.byTier[Tier::SwiftGenerated]);
      if (compilerRuns < 0) {
        out.attribute("compilerVerified", false);
      } else {
        out.attribute("compilerVerified", true);
        out.attribute("compilerRuns", compilerRuns);
      }
      out.attribute("compiledThunks", nullptr);
      out.attribute("runtimeTested", nullptr);
    });
    out.attributeObject("byKind", [&] {
      for (const auto& entry : byKind) {
        out.attributeObject(entry.first,
                            [&] { writeCounts(out, entry.second); });
      }
    });
    out.attributeObject("reasons", [&] {
      for (const auto& entry : reasons) {
        out.attribute(entry.first, entry.second);
      }
    });
    out.attributeArray("symbols", [&] {
      for (const auto& entry : module.symbols) {
        const Symbol& symbol = entry.second;
        const Capability* capability = classification.find(entry.first);
        if (!capability || (isFunctionInstantiation(symbol) &&
                            capability->tier != Tier::SwiftGenerated)) {
          continue;
        }
        Tier tier = tierOf(symbol, *capability);
        out.object([&] {
          out.attribute("id", symbol.preciseId);
          out.attribute("path", llvm::join(symbol.pathComponents, "."));
          out.attribute("kind", toString(symbol.kind));
          out.attribute("tier", toString(tier));
          if (tier != Tier::SwiftGenerated && !capability->reasons.empty()) {
            out.attributeArray("reasons", [&] {
              for (const auto& reason : capability->reasons) {
                out.value(reason);
              }
            });
          }
          if (!capability->jsName.empty()) {
            out.attribute("jsName", capability->jsName);
          }
          if (capability->ambiguousOverload) {
            out.attribute("ambiguousOverload", true);
          }
          if (symbol.location) {
            out.attribute("location",
                          symbol.location->uri + ":" +
                              std::to_string(symbol.location->line + 1));
          }
        });
      }
    });
  });
  stream << "\n";
  stream.flush();
  return result;
}

}  // namespace Swift
