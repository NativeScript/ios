#pragma once

#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/raw_ostream.h>

#include <algorithm>
#include <cstdlib>
#include <string>
#include <vector>

#include "Swift/SymbolGraphLoader.h"
#include "TestHarness.h"

namespace TestSupport {

using namespace Swift;

inline const ModuleSet& fixture() {
  static ModuleSet set = loadSymbolGraphDirectory(SWIFT_FIXTURE_GRAPHS_DIR);
  return set;
}

inline const Module& demo() {
  static const Module empty;
  auto it = fixture().modules.find("SwiftDemo");
  return it == fixture().modules.end() ? empty : it->second;
}

inline std::vector<const Symbol*> symbolsAt(const Module& module,
                                            const std::string& path) {
  std::vector<const Symbol*> result;
  for (const auto& entry : module.symbols) {
    if (llvm::join(entry.second.pathComponents, ".") == path) {
      result.push_back(&entry.second);
    }
  }
  return result;
}

inline const Symbol* symbolAt(const Module& module, const std::string& path) {
  auto symbols = symbolsAt(module, path);
  return symbols.size() == 1 ? symbols.front() : nullptr;
}

inline std::vector<std::string> memberNames(const Module& module,
                                            const Symbol& symbol) {
  std::vector<std::string> names;
  for (const auto& id : symbol.memberIds) {
    if (const Symbol* member = module.find(id)) {
      names.push_back(member->name);
    }
  }
  return names;
}

inline bool contains(const std::vector<std::string>& values,
                     const std::string& value) {
  return std::find(values.begin(), values.end(), value) != values.end();
}

inline std::string diagnosticCodes(const std::vector<Diagnostic>& diagnostics) {
  std::vector<std::string> codes;
  for (const auto& diagnostic : diagnostics) {
    codes.push_back(diagnostic.code + "(" + diagnostic.message + ")");
  }
  return llvm::join(codes, ", ");
}

// Compares `actual` against the checked-in file at `path`.
// NS_UPDATE_SNAPSHOTS=1 rewrites the file instead.
inline void checkFile(const std::string& path, const std::string& actual) {
  if (const char* update = std::getenv("NS_UPDATE_SNAPSHOTS");
      update && *update == '1') {
    std::error_code error;
    llvm::raw_fd_ostream out(path, error, llvm::sys::fs::OF_Text);
    REQUIRE(!error);
    out << actual;
    return;
  }

  auto expected = llvm::MemoryBuffer::getFile(path, /*IsText*/ true);
  if (!expected) {
    TestHarness::fail(
        __FILE__, __LINE__,
        "missing snapshot " + path + " (run with NS_UPDATE_SNAPSHOTS=1)");
    return;
  }
  if ((*expected)->getBuffer() != actual) {
    std::string actualPath = path + ".actual";
    std::error_code error;
    llvm::raw_fd_ostream out(actualPath, error, llvm::sys::fs::OF_Text);
    out << actual;
    TestHarness::fail(__FILE__, __LINE__,
                      "snapshot mismatch: diff " + path + " " + actualPath);
  }
}

// Compares `actual` against tests/swift/snapshots/<fileName>.
inline void checkSnapshot(const std::string& fileName,
                          const std::string& actual) {
  llvm::SmallString<256> path(SWIFT_SNAPSHOT_DIR);
  llvm::sys::path::append(path, fileName);
  checkFile(path.str().str(), actual);
}

}  // namespace TestSupport
