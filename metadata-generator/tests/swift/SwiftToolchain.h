#pragma once

#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/Program.h>
#include <llvm/Support/raw_ostream.h>

#include <optional>
#include <string>

#include "Swift/ProbeVerifier.h"

// Helpers for tests that run the Swift compiler against the fixture module.
namespace TestSupport {

// Directory holding SwiftDemoKit.swiftmodule and SwiftDemo.swiftmodule built
// from the fixture sources, or "" when no Swift toolchain is available.
inline const std::string& fixtureModuleDirectory() {
  static std::string directory = [] {
    if (!llvm::sys::findProgramByName("xcrun")) {
      return std::string();
    }
    llvm::SmallString<128> path;
    if (llvm::sys::fs::createUniqueDirectory("swift-fixture", path)) {
      return std::string();
    }
    std::string flags =
        "-target arm64-apple-ios15.0-simulator "
        "-sdk \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" -I '" +
        path.str().str() + "' ";
    std::string command =
        "xcrun swiftc -emit-module -module-name SwiftDemoKit " + flags +
        "-emit-module-path '" + path.str().str() +
        "/SwiftDemoKit.swiftmodule' '" SWIFT_FIXTURE_DIR
        "'/Sources/SwiftDemoKit/*.swift && "
        "xcrun swiftc -emit-module -module-name SwiftDemo " + flags +
        "-emit-module-path '" + path.str().str() +
        "/SwiftDemo.swiftmodule' '" SWIFT_FIXTURE_DIR
        "'/Sources/SwiftDemo/*.swift";
    auto shell = llvm::sys::findProgramByName("sh");
    if (!shell ||
        llvm::sys::ExecuteAndWait(*shell, {*shell, "-c", command}) != 0) {
      return std::string();
    }
    return path.str().str();
  }();
  return directory;
}

inline Swift::VerifyOptions fixtureVerifyOptions() {
  Swift::VerifyOptions options;
  options.compiler = {"xcrun", "swiftc"};
  llvm::SmallString<128> sdkLog;
  llvm::sys::fs::createTemporaryFile("sdk", "txt", sdkLog);
  auto shell = llvm::sys::findProgramByName("sh");
  std::optional<llvm::StringRef> redirects[] = {
      std::nullopt, llvm::StringRef(sdkLog), std::nullopt};
  llvm::sys::ExecuteAndWait(
      *shell, {*shell, "-c", "xcrun --sdk iphonesimulator --show-sdk-path"},
      std::nullopt, redirects);
  auto sdk = llvm::MemoryBuffer::getFile(sdkLog);
  options.sdk = sdk ? (*sdk)->getBuffer().trim().str() : "";
  llvm::sys::fs::remove(sdkLog);
  options.target = "arm64-apple-ios15.0-simulator";
  options.searchPaths = {fixtureModuleDirectory()};
  llvm::SmallString<128> work;
  llvm::sys::fs::createUniqueDirectory("swift-verify", work);
  options.workDirectory = work.str().str();
  return options;
}

// Type-checks `source` against the fixture module; returns the compiler's
// output on failure and "" on success.
inline std::string typeCheckAgainstFixture(const std::string& source,
                                           const std::string& extraFlags = "") {
  llvm::SmallString<128> directory;
  if (llvm::sys::fs::createUniqueDirectory("swift-typecheck", directory)) {
    return "cannot create a temporary directory";
  }
  llvm::SmallString<128> sourcePath(directory);
  llvm::sys::path::append(sourcePath, "source.swift");
  {
    std::error_code error;
    llvm::raw_fd_ostream out(sourcePath, error, llvm::sys::fs::OF_Text);
    out << source;
  }
  llvm::SmallString<128> log(directory);
  llvm::sys::path::append(log, "swiftc.log");
  std::string command =
      "xcrun swiftc -typecheck " + extraFlags +
      " -target arm64-apple-ios15.0-simulator "
      "-sdk \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" -I '" +
      fixtureModuleDirectory() + "' '" + sourcePath.str().str() + "'";
  auto shell = llvm::sys::findProgramByName("sh");
  std::optional<llvm::StringRef> redirects[] = {
      std::nullopt, llvm::StringRef(log), llvm::StringRef(log)};
  int status = llvm::sys::ExecuteAndWait(*shell, {*shell, "-c", command},
                                         std::nullopt, redirects);
  std::string output;
  if (status != 0) {
    auto buffer = llvm::MemoryBuffer::getFile(log);
    output = buffer ? (*buffer)->getBuffer().str()
                    : "compiler failed without output";
  }
  llvm::sys::fs::remove_directories(directory);
  return output;
}

}  // namespace TestSupport
