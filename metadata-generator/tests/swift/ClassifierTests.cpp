#include <llvm/Support/FileSystem.h>
#include <llvm/Support/Program.h>

#include "Swift/CapabilityClassifier.h"
#include "Swift/CoverageReport.h"
#include "Swift/ProbeEmitter.h"
#include "Swift/ProbeVerifier.h"
#include "Swift/SwiftSource.h"
#include "TestHarness.h"
#include "TestSupport.h"

using namespace Swift;
using namespace TestSupport;

namespace {

const Classification& classification() {
  static Classification result = classify(demo());
  return result;
}

const Capability* capabilityAt(const std::string& path) {
  const Symbol* symbol = symbolAt(demo(), path);
  return symbol ? classification().find(symbol->preciseId) : nullptr;
}

void expectTier(const char* file, int line, const std::string& path, Tier tier,
                const std::string& reason = "") {
  const Capability* capability = capabilityAt(path);
  if (!capability) {
    TestHarness::fail(file, line, "no single symbol at " + path);
    return;
  }
  std::string actualReasons = llvm::join(capability->reasons, ",");
  if (capability->tier != tier || actualReasons != reason) {
    TestHarness::fail(file, line,
                      path + ": expected " + toString(tier) + "(" + reason +
                          "), got " + toString(capability->tier) + "(" +
                          actualReasons + ")");
  }
}

#define EXPECT_TIER(...) expectTier(__FILE__, __LINE__, __VA_ARGS__)

}  // namespace

TEST(ClassifyNominalTypes) {
  EXPECT_TIER("Demo", Tier::SwiftGenerated);
  EXPECT_TIER("Point", Tier::SwiftGenerated);
  EXPECT_TIER("Flavor", Tier::SwiftGenerated);
  EXPECT_TIER("Counter", Tier::SwiftGenerated);
  EXPECT_TIER("Canvas", Tier::SwiftGenerated);
  EXPECT_TIER("Greeter", Tier::TypeOnly, "protocol");
  EXPECT_TIER("Measurement", Tier::Unsupported, "enum-associated-values");
  EXPECT_TIER("ShapeError", Tier::Unsupported, "enum-associated-values");
  EXPECT_TIER("Measurement.Unit", Tier::Unsupported, "nested-type");
  EXPECT_TIER("Coordinates", Tier::TypeOnly, "type-alias");
}

TEST(ClassifyCallables) {
  EXPECT_TIER("Demo.init()", Tier::SwiftGenerated);
  EXPECT_TIER("Demo.greet(name:)", Tier::SwiftGenerated);
  EXPECT_TIER("Demo.greet(name:times:)", Tier::SwiftGenerated);
  EXPECT_TIER("Demo.version", Tier::SwiftGenerated);
  EXPECT_TIER("Point.x", Tier::SwiftGenerated);
  EXPECT_TIER("Point.init(x:y:)", Tier::SwiftGenerated);
  EXPECT_TIER("Point.description", Tier::SwiftGenerated);
  EXPECT_TIER("Flavor.vanilla", Tier::SwiftGenerated);
  EXPECT_TIER("Flavor.init(rawValue:)", Tier::SwiftGenerated);
  EXPECT_TIER("Flavor.hashValue", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.init(name:)", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.describe(_:)", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.make()", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.shared", Tier::SwiftGenerated);
  EXPECT_TIER("Ring.expand(by:)", Tier::SwiftGenerated);
  EXPECT_TIER("Loader.load(path:)", Tier::Unsupported,
              "unbridged-type:Foundation.Data");
  EXPECT_TIER("Loader.modernOnly()", Tier::SwiftGenerated);
  EXPECT_TIER("Loader.legacyFetch()", Tier::SwiftGenerated);
  EXPECT_TIER("makeDefaultPoint()", Tier::SwiftGenerated);
  EXPECT_TIER("defaultFlavor", Tier::SwiftGenerated);
  EXPECT_TIER("globalCounter", Tier::SwiftGenerated);
  EXPECT_TIER("Counter.init()", Tier::SwiftGenerated);
  EXPECT_TIER("Counter.label()", Tier::SwiftGenerated);
}

TEST(ClassifyRejections) {
  EXPECT_TIER("Greeter.greet(name:)", Tier::TypeOnly, "protocol-requirement");
  EXPECT_TIER("Loader.fetch(url:)", Tier::Unsupported, "async");
  EXPECT_TIER("Loader.wait(seconds:)", Tier::Unsupported, "async");
  EXPECT_TIER("Loader.transform(_:)", Tier::SwiftSpecialized, "generic");
  EXPECT_TIER("Loader.first(of:)", Tier::SwiftSpecialized, "generic");
  EXPECT_TIER("Loader.withCompletion(_:)", Tier::Unsupported, "closure");
  EXPECT_TIER("Loader.each(_:)", Tier::Unsupported, "closure");
  EXPECT_TIER("Loader.update(_:)", Tier::Unsupported, "inout-parameter");
  EXPECT_TIER("Loader.lookup(table:key:)", Tier::Unsupported, "collection");
  EXPECT_TIER("Counter.increment()", Tier::Unsupported, "actor-isolated");
  EXPECT_TIER("Counter.value", Tier::Unsupported, "actor-isolated");
  EXPECT_TIER("Canvas.init()", Tier::Unsupported, "main-actor");
  EXPECT_TIER("Canvas.draw(_:)", Tier::Unsupported, "main-actor");
  EXPECT_TIER("Ring.+(_:_:)", Tier::Unsupported, "operator");
  EXPECT_TIER("Polygon.subscript(_:)", Tier::Unsupported, "subscript");
  EXPECT_TIER("String.shouted", Tier::Unsupported, "external-type-extension");
  EXPECT_TIER("Measurement.isNone", Tier::Unsupported, "owner-not-bridged");
  EXPECT_TIER("Flavor.hash(into:)", Tier::Unsupported, "inout-parameter");
}

TEST(ClassifyBridges) {
  const Capability* describe = capabilityAt("Polygon.describe(_:)");
  REQUIRE(describe && describe->parameters.size() == 1);
  CHECK(describe->parameters[0].bridge == Bridge::ClassHandle);
  CHECK(describe->parameters[0].optional);
  CHECK(describe->result.bridge == Bridge::String);

  const Capability* rawValue = capabilityAt("Flavor.init(rawValue:)");
  REQUIRE(rawValue);
  CHECK(rawValue->result.bridge == Bridge::EnumCase);
  CHECK(rawValue->result.optional);
  CHECK(rawValue->parameters[0].bridge == Bridge::Integer);

  const Capability* point = capabilityAt("makeDefaultPoint()");
  REQUIRE(point);
  CHECK(point->result.bridge == Bridge::StructBox);
  CHECK(point->result.symbolId == symbolAt(demo(), "Point")->preciseId);
}

TEST(ClassifyJsNamesAndOverloads) {
  for (const Symbol* overload : symbolsAt(demo(), "Polygon.scale(by:)")) {
    const Capability* capability = classification().find(overload->preciseId);
    REQUIRE(capability);
    CHECK_EQ(capability->jsName, std::string("scale"));
    // Double and Int are both JS numbers.
    CHECK(capability->ambiguousOverload);
  }
  CHECK(!capabilityAt("Polygon.scale(x:y:)")->ambiguousOverload);
  CHECK(!capabilityAt("Demo.greet(name:)")->ambiguousOverload);
  CHECK_EQ(capabilityAt("Demo.greet(name:times:)")->jsName,
           std::string("greet"));
  CHECK_EQ(capabilityAt("Polygon.init(name:vertexCount:)")->jsName,
           std::string("constructor"));
  CHECK(!capabilityAt("Polygon.init(name:vertexCount:)")->ambiguousOverload);
}

TEST(InvocationAvailability) {
  const Symbol* modern = symbolAt(demo(), "Loader.modernOnly()");
  REQUIRE(modern);
  Invocation invocation = describeInvocation(
      demo(), *modern, *classification().find(modern->preciseId));
  CHECK_EQ(invocation.availability, std::string("iOS 16.0, *"));

  const Symbol* old = symbolAt(demo(), "Loader.oldFetch()");
  REQUIRE(old);
  Invocation unguarded =
      describeInvocation(demo(), *old, *classification().find(old->preciseId));
  CHECK_EQ(unguarded.availability, std::string());
}

TEST(CoverageSnapshot) {
  checkSnapshot("SwiftDemo.coverage.json",
                coverageJSON(demo(), classification()));
}

TEST(ProbeSnapshot) {
  checkSnapshot("SwiftDemo.probe.swift",
                emitProbes(demo(), classification()).source);
}

namespace {

// Directory holding SwiftDemo.swiftmodule built from the fixture sources, or
// "" when no Swift toolchain is available.
const std::string& fixtureModuleDirectory() {
  static std::string directory = [] {
    if (!llvm::sys::findProgramByName("xcrun")) {
      return std::string();
    }
    llvm::SmallString<128> path;
    if (llvm::sys::fs::createUniqueDirectory("swift-fixture", path)) {
      return std::string();
    }
    std::string command =
        "xcrun swiftc -emit-module -module-name SwiftDemo "
        "-target arm64-apple-ios15.0-simulator "
        "-sdk \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" "
        "-emit-module-path '" +
        path.str().str() +
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

VerifyOptions fixtureVerifyOptions() {
  VerifyOptions options;
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

}  // namespace

TEST(VerifierParsesDiagnostics) {
  std::string log =
      "/tmp/p.swift:12:7: error: value of type 'X' has no member 'y'\n"
      "/tmp/p.swift:12:9: error: second error on the same probe\n"
      "/tmp/p.swift:13:1: warning: ignored\n"
      "/tmp/other.swift:4:1: error: not ours\n"
      "/tmp/p.swift:99:1: error: outside probes\n";
  std::map<int, std::string> lines = {{12, "s:sym"}, {13, "s:sym"}};
  std::vector<std::string> unmapped;
  auto rejections = rejectionsFromLog(log, "/tmp/p.swift", lines, unmapped);
  REQUIRE(rejections.size() == 1);
  CHECK_EQ(rejections.at("s:sym"),
           std::string("value of type 'X' has no member 'y'"));
  REQUIRE(unmapped.size() == 1);
  CHECK_EQ(unmapped[0], std::string("99: outside probes"));
}

TEST(VerifierAcceptsFixture) {
  if (fixtureModuleDirectory().empty()) {
    std::cout << "  (skipped: no Swift toolchain)" << std::endl;
    return;
  }
  VerifyOptions options = fixtureVerifyOptions();
  VerifyResult result = verifyWithCompiler(demo(), options);
  llvm::sys::fs::remove_directories(options.workDirectory);
  CHECK_EQ(result.failure, std::string());
  CHECK_EQ(result.compilerRuns, 1);
  CHECK(result.rejections.empty());
}

TEST(VerifierDemotesWhatTheCompilerRejects) {
  if (fixtureModuleDirectory().empty()) {
    std::cout << "  (skipped: no Swift toolchain)" << std::endl;
    return;
  }
  // An IR that disagrees with the compiler: greet(name:) takes a String, not
  // an Int.
  Module wrong = demo();
  Symbol* greet = nullptr;
  for (auto& entry : wrong.symbols) {
    if (llvm::join(entry.second.pathComponents, ".") == "Demo.greet(name:)") {
      greet = &entry.second;
    }
  }
  REQUIRE(greet && greet->parameters.size() == 1);
  greet->parameters[0].type =
      TypeRef{"Int", {Fragment{"typeIdentifier", "Int", "s:Si"}}};

  VerifyOptions options = fixtureVerifyOptions();
  VerifyResult result = verifyWithCompiler(wrong, options);
  llvm::sys::fs::remove_directories(options.workDirectory);
  CHECK_EQ(result.failure, std::string());
  CHECK_EQ(result.compilerRuns, 2);
  REQUIRE(result.rejections.size() == 1);
  CHECK(result.rejections.count(greet->preciseId));
  const Capability* demoted = result.classification.find(greet->preciseId);
  REQUIRE(demoted);
  CHECK(demoted->tier == Tier::Unsupported);
  CHECK(
      llvm::StringRef(demoted->reasons.at(0)).startswith("compiler-rejected:"));

  const Symbol* other = symbolAt(demo(), "Demo.greet(name:times:)");
  CHECK(result.classification.find(other->preciseId)->tier ==
        Tier::SwiftGenerated);
}

// Builds the fixture module and type-checks the probes against it.
TEST(ProbesTypeCheck) {
  auto shell = llvm::sys::findProgramByName("sh");
  auto xcrun = llvm::sys::findProgramByName("xcrun");
  if (!shell || !xcrun) {
    std::cout << "  (skipped: xcrun not found)" << std::endl;
    return;
  }

  llvm::SmallString<128> directory;
  REQUIRE(!llvm::sys::fs::createUniqueDirectory("swift-probes", directory));
  llvm::SmallString<128> probePath(directory);
  llvm::sys::path::append(probePath, "probe.swift");
  {
    std::error_code error;
    llvm::raw_fd_ostream out(probePath, error, llvm::sys::fs::OF_Text);
    REQUIRE(!error);
    out << emitProbes(demo(), classification()).source;
  }

  std::string dir = directory.str().str();
  std::string command =
      "set -e; SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); "
      "TARGET=arm64-apple-ios15.0-simulator; "
      "xcrun swiftc -emit-module -module-name SwiftDemo -target $TARGET -sdk "
      "\"$SDK\" "
      "-emit-module-path '" +
      dir +
      "/SwiftDemo.swiftmodule' '" SWIFT_FIXTURE_DIR
      "'/Sources/SwiftDemo/*.swift; "
      "xcrun swiftc -typecheck -I '" +
      dir + "' -target $TARGET -sdk \"$SDK\" '" + probePath.str().str() + "'";
  llvm::SmallString<128> log(directory);
  llvm::sys::path::append(log, "swiftc.log");
  std::optional<llvm::StringRef> redirects[] = {
      std::nullopt, llvm::StringRef(log), llvm::StringRef(log)};
  int status = llvm::sys::ExecuteAndWait(*shell, {*shell, "-c", command},
                                         std::nullopt, redirects);
  if (status != 0) {
    auto output = llvm::MemoryBuffer::getFile(log);
    TestHarness::fail(
        __FILE__, __LINE__,
        "probes failed to type-check:\n" +
            (output ? (*output)->getBuffer().str() : std::string("(no log)")));
  }
  llvm::sys::fs::remove_directories(directory);
}
