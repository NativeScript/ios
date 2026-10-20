#pragma once

#include <llvm/ADT/StringRef.h>

#include <string>
#include <vector>

#include "SwiftIR.h"

namespace Swift {

// Reads Swift symbol graph files (`swiftc -emit-symbol-graph` /
// `swift symbolgraph-extract`) into the Swift IR.
//
// A module's declarations can span several graph files: `M.symbols.json`
// holds M's own declarations, `M@Other.symbols.json` holds M's extensions of
// types declared in module Other. Files are grouped by the module name inside
// the graph, not by file name.
class SymbolGraphLoader {
 public:
  // Newest symbol graph format this loader has been validated against.
  // Newer minor versions load with a warning; other major versions are
  // rejected.
  static constexpr int kSupportedFormatMajor = 0;
  static constexpr int kNewestKnownFormatMinor = 6;

  // Graph files under `directory` (recursive), sorted for deterministic
  // loading.
  static std::vector<std::string> findGraphFiles(
      const std::string& directory, std::vector<Diagnostic>& diagnostics);

  void addFile(const std::string& path, const std::string& displayName);
  void addBuffer(llvm::StringRef json, const std::string& displayName);

  // Resolves relationships across all added graphs. The loader is spent
  // afterwards.
  ModuleSet finish();

 private:
  void insertSymbol(Module& module, Symbol symbol,
                    const std::string& displayName);

  std::map<std::string, Module> _modules;
  std::vector<Diagnostic> _diagnostics;
};

// Convenience: find, load and resolve every graph under `directory`.
ModuleSet loadSymbolGraphDirectory(const std::string& directory);

// Every graph under each of `directories`, as one set.
ModuleSet loadSymbolGraphDirectories(
    const std::vector<std::string>& directories);

// Merges the modules of `set` into one generation unit named `name`, so
// declarations can name each other's types and extend them. Symbols keep
// their own module (Symbol::module); a module's extensions of another
// module's types become members of those types. `reexports` maps a module
// that is an implementation detail of another (SwiftUICore -> SwiftUI) to
// the module code imports and names it through; its symbols join that one.
Module mergeUnit(ModuleSet& set, const std::string& name,
                 const std::map<std::string, std::string>& reexports = {});

}  // namespace Swift
