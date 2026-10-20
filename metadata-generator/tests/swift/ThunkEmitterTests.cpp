#include "Swift/CapabilityClassifier.h"
#include "Swift/ThunkEmitter.h"
#include "SwiftToolchain.h"
#include "TestHarness.h"
#include "TestSupport.h"
#include "TypeScript/SwiftDefinitionWriter.h"

using namespace Swift;
using namespace TestSupport;

namespace {

const ThunkSource& thunks() {
  static ThunkSource source = emitThunks(demo(), classify(demo()));
  return source;
}

bool registers(const std::string& line) {
  return thunks().source.find(line) != std::string::npos;
}

}  // namespace

// TestRunner compiles this checked-in copy (TestFixtures/SwiftDemo/Interop),
// so it must be exactly what the generator emits.
TEST(ThunkSourceMatchesFixtureInterop) {
  checkFile(SWIFT_FIXTURE_DIR "/Interop/SwiftDemo+NativeScript.swift",
            thunks().source);
}

TEST(ThunksTypeCheck) {
  if (fixtureModuleDirectory().empty()) {
    std::cout << "  (skipped: no Swift toolchain)" << std::endl;
    return;
  }
  std::string errors =
      typeCheckAgainstFixture(thunks().source, "-parse-as-library");
  if (!errors.empty()) {
    TestHarness::fail(__FILE__, __LINE__,
                      "thunks failed to type-check:\n" + errors);
  }
}

TEST(ThunkRegistration) {
  CHECK(thunks().registerSymbols ==
        (std::vector<std::string>{"ns_swift_register_SwiftDemo",
                                  "ns_swift_register_SwiftDemoKit"}));
  CHECK_EQ(thunks().fingerprint.size(), size_t(16));
  CHECK(thunks().thunkCount > 0);
  CHECK(registers("registerModule(registrar, 11, \"SwiftDemo\", \"" +
                  thunks().fingerprint + "\", __nsRelease)"));
  // Cases of a tagged enum register their associated values' codes.
  CHECK(registers("\"tooManySides\", \"tooManySides(count:limit:)\", \"i64,i64>t"));
  CHECK(registers("\"area\", \"area(of:)\", \"t"));
  // Objective-C classes travel by runtime name; their framework is imported.
  CHECK(registers("\"firstSubview\", \"firstSubview(of:)\", \"@UIView>@UIView?\""));
  CHECK(registers("\"makeNote\", \"makeNote(_:)\", \"s>@SwiftDemo.Note\""));
  CHECK(thunks().source.find("#if canImport(UIKit)\nimport UIKit\n#endif") != std::string::npos);
  // SwiftUI views are hosted on the main actor (flag 16).
  CHECK(registers("\"hostingController\", \"hostingController()\", \">@UIViewController\""));
  // Protocol values; requirements carry the requirement flag (32).
  CHECK(registers("\"introduce\", \"introduce(_:to:)\", \"p"));
  CHECK(thunks().source.find("private final class __NSAdapter") != std::string::npos);
  // Inout parameters are marked; the thunk writes their final value back.
  CHECK(registers("\"append\", \"append(_:to:)\", \"s,&[s]>v\""));
  CHECK(registers("\"swapTrackers\", \"swapTrackers(_:_:)\", \"&o"));
  CHECK(thunks().source.find("rt.writeBack(1) { rt.returnArray(a1)") != std::string::npos);
  // Closure parameters list the closure's own parameter codes.
  CHECK(registers("\"countdown\", \"countdown(from:_:)\", \"i64,(i64,b)>v\""));
  CHECK(registers("\"greetLater\", \"greetLater(_:completion:)\", \"s?,(s?)>v\""));
  // Instance method with labels; signature (String, Int) -> String.
  CHECK(registers("\"greet\", \"greet(name:times:)\", \"s,i64>s\""));
  // Failable initializer of a class returns an optional object.
  CHECK(registers("\"constructor\", \"init(name:)\", \"s>o"));
  // Ambiguous overloads carry the flag (4) and stay distinct by signature.
  CHECK(registers(", 1, 4, \"SwiftDemo\", \"scale\", \"scale(by:)\", \"f64>v\""));
  CHECK(registers(", 1, 4, \"SwiftDemo\", \"scale\", \"scale(by:)\", \"i64>v\""));
  // Enum cases register without a thunk.
  CHECK(registers("\"vanilla\", \"vanilla\", \">e"));
  // A case named `none` maps to the enum's case, not Optional.none.
  CHECK(registers("case \"none\": return SwiftDemo.Precipitation.`none`"));
  // Settable stored property registers a setter.
  CHECK(registers("\"x\", \"x\", \">f64\", __nsThunk"));
}

TEST(ThunkFingerprintTracksSurface) {
  Classification classification = classify(demo());
  ThunkSource original = emitThunks(demo(), classification);
  // Demoting one member changes the registered surface.
  std::map<std::string, std::string> rejections = {
      {symbolAt(demo(), "Demo.greet(name:)")->preciseId, "test"}};
  ThunkSource reduced = emitThunks(demo(), classify(demo(), rejections));
  CHECK(original.fingerprint != reduced.fingerprint);
  CHECK_EQ(emitThunks(demo(), classification).fingerprint,
           original.fingerprint);
}

// The generated declarations, with the runtime's types/ns-swift.d.ts, accept
// the documented usage and reject what the runtime rejects. Needs a `tsc`
// on PATH or in NS_TSC; skipped otherwise.
TEST(TypeScriptUsageCompiles) {
  std::string tsc;
  if (const char* configured = std::getenv("NS_TSC");
      configured && *configured) {
    tsc = configured;
  } else if (auto found = llvm::sys::findProgramByName("tsc")) {
    tsc = *found;
  } else {
    std::cout << "  (skipped: no tsc; set NS_TSC)" << std::endl;
    return;
  }

  llvm::SmallString<128> directory;
  REQUIRE(!llvm::sys::fs::createUniqueDirectory("swift-tsc", directory));
  auto write = [&](const std::string& name, const std::string& content) {
    llvm::SmallString<128> path(directory);
    llvm::sys::path::append(path, name);
    std::error_code error;
    llvm::raw_fd_ostream out(path, error, llvm::sys::fs::OF_Text);
    out << content;
    return path.str().str();
  };
  Classification classification = classify(demo());
  for (const auto& name : demo().swiftModules()) {
    write("swift-" + name + ".d.ts",
          TypeScript::SwiftDefinitionWriter(demo(), classification, name).write());
  }
  auto usage =
      llvm::MemoryBuffer::getFile(SWIFT_TEST_DIR "/typescript/usage.ts");
  REQUIRE(usage);
  std::string usagePath =
      write("usage.ts", "/// <reference path=\"" SWIFT_TYPES_DIR
                        "/index.d.ts\" />\n"
                        "/// <reference path=\"" SWIFT_TEST_DIR
                        "/typescript/objc-globals.d.ts\" />\n"
                        "/// <reference path=\"./swift-SwiftDemo.d.ts\" />\n"
                        "/// <reference path=\"./swift-SwiftDemoKit.d.ts\" />\n" +
                            (*usage)->getBuffer().str());

  llvm::SmallString<128> log(directory);
  llvm::sys::path::append(log, "tsc.log");
  std::string command = "'" + tsc +
                        "' --noEmit --strict --target es2022 --module esnext "
                        "--moduleResolution bundler --lib es2022 '" +
                        usagePath + "'";
  auto shell = llvm::sys::findProgramByName("sh");
  std::optional<llvm::StringRef> redirects[] = {
      std::nullopt, llvm::StringRef(log), llvm::StringRef(log)};
  int status = llvm::sys::ExecuteAndWait(*shell, {*shell, "-c", command},
                                         std::nullopt, redirects);
  if (status != 0) {
    auto output = llvm::MemoryBuffer::getFile(log);
    TestHarness::fail(
        __FILE__, __LINE__,
        "tsc rejected the declarations:\n" +
            (output ? (*output)->getBuffer().str() : std::string()));
  }
  llvm::sys::fs::remove_directories(directory);
}
