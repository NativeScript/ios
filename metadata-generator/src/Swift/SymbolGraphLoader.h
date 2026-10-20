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
  std::map<std::string, Module> _modules;
  std::vector<Diagnostic> _diagnostics;
};

// Convenience: find, load and resolve every graph under `directory`.
ModuleSet loadSymbolGraphDirectory(const std::string& directory);

}  // namespace Swift
