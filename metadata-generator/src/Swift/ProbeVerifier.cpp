#include "ProbeVerifier.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/Program.h>
#include <llvm/Support/raw_ostream.h>

#include "ProbeEmitter.h"

namespace Swift {

std::map<std::string, std::string> rejectionsFromLog(
    const std::string& log, const std::string& probePath,
    const std::map<int, std::string>& lineToSymbol,
    std::vector<std::string>& unmapped) {
  std::map<std::string, std::string> rejections;
  llvm::SmallVector<llvm::StringRef, 64> lines;
  llvm::StringRef(log).split(lines, '\n');
  for (llvm::StringRef line : lines) {
    if (!line.consume_front(probePath) || !line.consume_front(":")) {
      continue;
    }
    auto lineNumber = line.split(':');
    auto column = lineNumber.second.split(':');
    llvm::StringRef message = column.second.trim();
    int number = 0;
    if (lineNumber.first.getAsInteger(10, number) ||
        !message.consume_front("error:")) {
      continue;
    }
    message = message.trim();
    auto symbol = lineToSymbol.find(number);
    if (symbol == lineToSymbol.end()) {
      unmapped.push_back(std::to_string(number) + ": " + message.str());
      continue;
    }
    rejections.emplace(symbol->second, message.str());
  }
  return rejections;
}

VerifyResult verifyWithCompiler(const Module& module,
                                const VerifyOptions& options) {
  VerifyResult result;
  if (options.compiler.empty()) {
    result.failure = "no compiler configured";
    return result;
  }
  auto program = llvm::sys::findProgramByName(options.compiler[0]);
  if (!program) {
    result.failure = "compiler '" + options.compiler[0] + "' not found";
    return result;
  }

  llvm::SmallString<256> probePath(options.workDirectory);
  llvm::sys::path::append(probePath, module.name + ".verify.swift");
  llvm::SmallString<256> logPath(options.workDirectory);
  llvm::sys::path::append(logPath, module.name + ".verify.log");
  llvm::sys::fs::create_directories(options.workDirectory);

  // Each pass demotes at least one symbol, so the loop terminates; the bound
  // only guards against a compiler that keeps reporting the same errors.
  for (int pass = 0; pass < 8; pass++) {
    result.classification = classify(module, result.rejections);
    ProbeSource probes = emitProbes(module, result.classification);
    {
      std::error_code error;
      llvm::raw_fd_ostream out(probePath, error, llvm::sys::fs::OF_Text);
      if (error) {
        result.failure = probePath.str().str() + ": " + error.message();
        return result;
      }
      out << probes.source;
    }

    std::vector<std::string> arguments(options.compiler.begin(),
                                       options.compiler.end());
    arguments.insert(arguments.end(), {"-typecheck", "-sdk", options.sdk,
                                       "-target", options.target});
    for (const auto& path : options.searchPaths) {
      arguments.insert(arguments.end(), {"-I", path});
    }
    for (const auto& path : options.frameworkSearchPaths) {
      arguments.insert(arguments.end(), {"-F", path});
    }
    arguments.push_back(probePath.str().str());
    std::vector<llvm::StringRef> argv(arguments.begin(), arguments.end());
    std::optional<llvm::StringRef> redirects[] = {
        std::nullopt, llvm::StringRef(logPath), llvm::StringRef(logPath)};
    std::string executionError;
    int status = llvm::sys::ExecuteAndWait(*program, argv, std::nullopt,
                                           redirects, 0, 0, &executionError);
    result.compilerRuns++;
    if (status < 0) {
      result.failure = "compiler did not run: " + executionError;
      return result;
    }
    if (status == 0) {
      return result;
    }

    auto log = llvm::MemoryBuffer::getFile(logPath);
    std::vector<std::string> unmapped;
    auto rejections =
        rejectionsFromLog(log ? (*log)->getBuffer().str() : "",
                          probePath.str().str(), probes.lineToSymbol, unmapped);
    if (!unmapped.empty()) {
      result.failure = "compiler errors outside any probe (see " +
                       logPath.str().str() + "): " + unmapped.front();
      return result;
    }
    size_t before = result.rejections.size();
    result.rejections.insert(rejections.begin(), rejections.end());
    if (result.rejections.size() == before) {
      result.failure = "compiler failed without reporting probe errors (see " +
                       logPath.str().str() + ")";
      return result;
    }
  }
  result.failure = "probes still fail to type-check after repeated demotion";
  return result;
}

}  // namespace Swift
