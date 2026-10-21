#pragma once

#include <map>
#include <string>
#include <vector>

#include "CapabilityClassifier.h"
#include "SwiftIR.h"

namespace Swift {

struct VerifyOptions {
  // Compiler driver and leading arguments, e.g. {"xcrun", "swiftc"}.
  std::vector<std::string> compiler = {"xcrun", "swiftc"};
  std::string sdk;
  std::string target;
  // Directories holding the modules' .swiftmodule / frameworks.
  std::vector<std::string> searchPaths;
  std::vector<std::string> frameworkSearchPaths;
  // Scratch directory for probe sources and compiler logs.
  std::string workDirectory;
};

struct VerifyResult {
  Classification classification;
  // Symbol id -> first compiler error reported against its probe.
  std::map<std::string, std::string> rejections;
  int compilerRuns = 0;
  // Set when verification could not complete: the compiler failed to run, or
  // reported errors that map to no probe (e.g. the module cannot be
  // imported).
  std::string failure;
};

// Classifies `module`, type-checks probes and thunks for the result,
// demotes every symbol whose code the compiler rejects, and repeats until
// both type-check (demoting a type changes its members' classification).
VerifyResult verifyWithCompiler(const Module& module,
                                const VerifyOptions& options);

// "probe.swift:12:7: error: message" lines of `log` for `probePath`, mapped
// through `lineToSymbol`. Errors on unmapped lines go to `unmapped`.
std::map<std::string, std::string> rejectionsFromLog(
    const std::string& log, const std::string& probePath,
    const std::map<int, std::string>& lineToSymbol,
    std::vector<std::string>& unmapped);

// The same for errors in generated thunks (`thunkPath` holding `source`),
// attributed to the symbol whose `// <id>` comment precedes the line.
std::map<std::string, std::string> rejectionsFromThunkLog(
    const std::string& log, const std::string& thunkPath,
    const std::string& source, const Module& module,
    std::vector<std::string>& unmapped);

}  // namespace Swift
