#include <llvm/Support/FileSystem.h>
#include <llvm/Support/Program.h>

#include "Swift/CapabilityClassifier.h"
#include "Swift/CoverageReport.h"
#include "Swift/ProbeEmitter.h"
#include "Swift/ProbeVerifier.h"
#include "Swift/SwiftSource.h"
#include "SwiftToolchain.h"
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
  EXPECT_TIER("Measurement.Unit", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.Style", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.Metrics", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.Metrics.init(perimeter:)", Tier::SwiftGenerated);
  EXPECT_TIER("Polygon.style", Tier::SwiftGenerated);
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
  EXPECT_TIER("Loader.load(path:)", Tier::SwiftGenerated);
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
  EXPECT_TIER("Loader.fetch(url:)", Tier::SwiftGenerated);
  EXPECT_TIER("Loader.transform(_:)", Tier::SwiftSpecialized, "generic");
  EXPECT_TIER("Loader.first(of:)", Tier::SwiftSpecialized, "generic");
  EXPECT_TIER("Loader.withCompletion(_:)", Tier::Unsupported, "closure");
  EXPECT_TIER("Loader.each(_:)", Tier::Unsupported, "closure");
  EXPECT_TIER("Loader.update(_:)", Tier::Unsupported, "inout-parameter");
  EXPECT_TIER("Loader.lookup(table:key:)", Tier::SwiftGenerated);
  EXPECT_TIER("Canvas.draw(_:)", Tier::Unsupported, "existential");
  EXPECT_TIER("Ring.+(_:_:)", Tier::Unsupported, "operator");
  EXPECT_TIER("Polygon.subscript(_:)", Tier::Unsupported, "subscript");
  EXPECT_TIER("String.shouted", Tier::Unsupported, "external-type-extension");
  EXPECT_TIER("Measurement.isNone", Tier::Unsupported, "owner-not-bridged");
  EXPECT_TIER("Flavor.hash(into:)", Tier::Unsupported, "inout-parameter");
}

TEST(ClassifyIsolationAndAsync) {
  auto flags = [](const std::string& path) {
    const Capability* capability = capabilityAt(path);
    if (!capability || capability->tier != Tier::SwiftGenerated) {
      return std::string("not generated");
    }
    return std::string(capability->isAsync ? "async" : "sync") +
           (capability->isMainActor ? ",main" : "") +
           (capability->isSettable ? ",settable" : "");
  };
  CHECK_EQ(flags("Loader.wait(seconds:)"), std::string("async"));
  CHECK_EQ(flags("delayedEcho(_:after:)"), std::string("async"));
  CHECK_EQ(flags("makeTrackerLater(id:)"), std::string("async"));
  // Actor members are awaited from outside, and never assignable.
  CHECK_EQ(flags("Counter.increment()"), std::string("async"));
  CHECK_EQ(flags("Counter.value"), std::string("async"));
  CHECK_EQ(flags("Counter.step"), std::string("async"));
  CHECK_EQ(flags("Counter.label()"), std::string("sync"));
  CHECK_EQ(flags("Counter.init()"), std::string("sync"));
  // Main-actor members run on the main thread; async ones hop there.
  CHECK_EQ(flags("Palette.init()"), std::string("sync,main"));
  CHECK_EQ(flags("Palette.stroke()"), std::string("sync,main"));
  CHECK_EQ(flags("Palette.strokes"), std::string("sync,main"));
  CHECK_EQ(flags("Palette.strokeLater()"), std::string("async,main"));
  CHECK_EQ(flags("Canvas.init()"), std::string("sync,main"));
}

TEST(ClassifyCollectionsAndFoundation) {
  const Capability* grid = capabilityAt("mirrored(_:)");
  REQUIRE(grid && grid->tier == Tier::SwiftGenerated);
  CHECK(grid->result.bridge == Bridge::Array);
  REQUIRE(grid->result.elements.size() == 1);
  CHECK(grid->result.elements[0].bridge == Bridge::Array);
  CHECK(grid->result.elements[0].elements.at(0).bridge == Bridge::Integer);

  const Capability* counts = capabilityAt("wordCounts(_:)");
  REQUIRE(counts && counts->tier == Tier::SwiftGenerated);
  CHECK(counts->result.bridge == Bridge::Dictionary);

  CHECK(capabilityAt("nextDay(after:)")->result.bridge == Bridge::Date);
  CHECK(capabilityAt("resolve(_:against:)")->parameters[1].bridge ==
        Bridge::URL);
  CHECK(capabilityAt("ramp(_:)")->result.bridge == Bridge::Data);
  CHECK(capabilityAt("trackers(_:)")->result.elements.at(0).bridge ==
        Bridge::ClassHandle);
  CHECK(capabilityAt("allFlavors()")->result.elements.at(0).bridge ==
        Bridge::EnumCase);
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

TEST(VerifierAttributesThunkErrors) {
  const std::string greet = symbolAt(demo(), "Demo.greet(name:)")->preciseId;
  const std::string flavor = symbolAt(demo(), "Flavor")->preciseId;
  std::string source =
      "import Foundation\n"  // 1
      "// " +
      greet +
      "\n"                        // 2
      "private func thunk() {\n"  // 3
      "}\n"                       // 4
      "// " +
      greet +
      " (setter)\n"  // 5
      "// " +
      flavor +
      "\n"                           // 6
      "private func helper() {}\n";  // 7
  std::string log =
      "/t.swift:3:1: error: in the thunk\n"
      "/t.swift:7:1: error: in the enum helper\n"
      "/t.swift:1:1: error: before any symbol\n";
  std::vector<std::string> unmapped;
  auto rejections =
      rejectionsFromThunkLog(log, "/t.swift", source, demo(), unmapped);
  CHECK_EQ(rejections.size(), size_t(2));
  CHECK_EQ(rejections[greet], std::string("in the thunk"));
  CHECK_EQ(rejections[flavor], std::string("in the enum helper"));
  CHECK_EQ(unmapped.size(), size_t(1));
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

// Type-checks the probes against the separately compiled fixture module.
TEST(ProbesTypeCheck) {
  if (fixtureModuleDirectory().empty()) {
    std::cout << "  (skipped: no Swift toolchain)" << std::endl;
    return;
  }
  std::string errors =
      typeCheckAgainstFixture(emitProbes(demo(), classification()).source);
  if (!errors.empty()) {
    TestHarness::fail(__FILE__, __LINE__,
                      "probes failed to type-check:\n" + errors);
  }
}
