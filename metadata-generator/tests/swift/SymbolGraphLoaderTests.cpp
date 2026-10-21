#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/raw_ostream.h>

#include <algorithm>
#include <cstdlib>

#include "Swift/CapabilityClassifier.h"
#include "Swift/SymbolGraphLoader.h"
#include "TestHarness.h"
#include "TestSupport.h"
#include "TypeScript/SwiftDefinitionWriter.h"

using namespace Swift;
using namespace TestSupport;

namespace {

ModuleSet loadBuffers(
    const std::vector<std::pair<std::string, std::string>>& buffers) {
  SymbolGraphLoader loader;
  for (const auto& buffer : buffers) {
    loader.addBuffer(buffer.second, buffer.first);
  }
  return loader.finish();
}

std::string graphJSON(const std::string& symbols,
                      const std::string& relationships,
                      const std::string& format = "0.6.0") {
  auto parts = llvm::StringRef(format).split('.');
  auto minorPatch = parts.second.split('.');
  return R"({"metadata":{"formatVersion":{"major":)" + parts.first.str() +
         R"(,"minor":)" + minorPatch.first.str() + R"(,"patch":)" +
         minorPatch.second.str() +
         R"(},"generator":"test"},"module":{"name":"Mini","platform":{}},"symbols":[)" +
         symbols + R"(],"relationships":[)" + relationships + "]}";
}

// `owner` is the dot-separated path of the containing type, if any.
std::string symbolJSON(const std::string& id, const std::string& kind,
                       const std::string& name, const std::string& declaration,
                       const std::string& owner = "") {
  std::string path;
  for (llvm::StringRef rest = owner; !rest.empty();) {
    auto split = rest.split('.');
    path += "\"" + split.first.str() + "\",";
    rest = split.second;
  }
  path += "\"" + name + "\"";
  return R"({"kind":{"identifier":")" + kind +
         R"("},"identifier":{"precise":")" + id + R"("},"pathComponents":[)" +
         path +
         R"(],"names":{"title":"x"},"accessLevel":"public","declarationFragments":[)" +
         declaration + "]}";
}

}  // namespace

TEST(LoadsFixtureWithoutDiagnostics) {
  CHECK_EQ(fixture().modules.size(), size_t(2));
  CHECK_EQ(diagnosticCodes(fixture().diagnostics), std::string());
  const Module& module = demo();
  CHECK_EQ(module.name, std::string("SwiftDemo"));
  CHECK_EQ(llvm::join(module.unitModules, ","), std::string("SwiftDemo,SwiftDemoKit"));
  CHECK_EQ(module.graphFiles.size(), size_t(4));
  CHECK_EQ(module.platform.operatingSystem, std::string("ios"));
  CHECK_EQ(module.platform.environment, std::string("simulator"));
}

TEST(TopLevelDeclarationsInSourceOrder) {
  std::vector<std::string> names;
  for (const auto& id : demo().topLevelIds) {
    const Symbol* symbol = demo().find(id);
    if (symbol->substitutions.empty()) {
      names.push_back(symbol->name);
    }
  }
  std::vector<std::string> expected = {"Badge",
                                       "Greeter",
                                       "Demo",
                                       "Point",
                                       "Flavor",
                                       "Thermostat",
                                       "Greeting",
                                       "Scorer",
                                       "RankedScorer",
                                       "FormalGreeting",
                                       "DoublingScorer",
                                       "introduce(_:to:)",
                                       "makeGreeting(_:)",
                                       "same(_:)",
                                       "excite(_:)",
                                       "scoreAll(_:_:)",
                                       "makeScorer()",
                                       "topRank(_:)",
                                       "greetInBackground(_:)",
                                       "GreetingHolder",
                                       "WeakGreetingHolder",
                                       "GreetingRegistry",
                                       "starterWallet(for:)",
                                       "sum(of:)",
                                       "flip(_:)",
                                       "Score",
                                       "makeScore(_:_:)",
                                       "describe(_:)",
                                       "boxed(_:)",
                                       "countBox(_:)",
                                       "settle(_:)",
                                       "unbox(_:)",
                                       "firstOf(_:)",
                                       "Shape",
                                       "Polygon",
                                       "Square",
                                       "Precipitation",
                                       "ShapeError",
                                       "Measurement",
                                       "Ring",
                                       "Counter",
                                       "Canvas",
                                       "Loader",
                                       "makeDefaultPoint()",
                                       "defaultFlavor",
                                       "globalCounter",
                                       "Coordinates",
                                       "countUp(to:)",
                                       "CountdownError",
                                       "countDown(from:failingAt:)",
                                       "letters(of:)",
                                       "pages(_:)",
                                       "checkedSide(_:)",
                                       "echoInt8(_:)",
                                       "echoUInt64(_:)",
                                       "largestInt()",
                                       "shout(_:)",
                                       "Tracker",
                                       "delayedEcho(_:after:)",
                                       "makeTrackerLater(id:)",
                                       "Palette",
                                       "names(_:)",
                                       "total(_:)",
                                       "centroid(of:)",
                                       "mirrored(_:)",
                                       "wordCounts(_:)",
                                       "lengths(_:)",
                                       "trackers(_:)",
                                       "allFlavors()",
                                       "nextDay(after:)",
                                       "host(of:)",
                                       "resolve(_:against:)",
                                       "checksum(_:)",
                                       "ramp(_:)",
                                       "namesLater(_:)",
                                       "countdown(from:_:)",
                                       "greetLater(_:completion:)",
                                       "Notifier",
                                       "area(of:)",
                                       "measure(_:by:)",
                                       "measurements()",
                                       "measureLater(_:)",
                                       "onMeasure(_:)",
                                       "explain(_:)",
                                       "Formula",
                                       "simplify(_:)",
                                       "Payload",
                                       "echo(_:)",
                                       "Job",
                                       "bump(_:)",
                                       "append(_:to:)",
                                       "halve(_:)",
                                       "clear(_:)",
                                       "swapTrackers(_:_:)",
                                       "echoInt(_:)",
                                       "echoString(_:)",
                                       "Bench",
                                       "transform(_:_:)",
                                       "sortedNames(_:by:)",
                                       "firstMatch(_:where:)",
                                       "lookup(_:_:)",
                                       "computeInBackground(_:)",
                                       "largest(_:)",
                                       "repeated(_:times:)",
                                       "popCount(_:)",
                                       "zero()",
                                       "greetTwice(_:_:)",
                                       "decodeJSON(_:from:)",
                                       "firstElement(_:)",
                                       "joined(_:_:)",
                                       "compact(_:)",
                                       "holes(_:)",
                                       "knownScores(_:)",
                                       "divide(_:by:)",
                                       "swapPair(_:)",
                                       "plot(_:)",
                                       "spans()",
                                       "uniqueTags(_:)",
                                       "countUnique(_:)",
                                       "tallyLater(_:)",
                                       "ParseFailure",
                                       "parseNumber(_:)",
                                       "checkSides(_:)",
                                       "unwrap(_:)",
                                       "parseLater(_:)",
                                       "fetchItem(_:_:)",
                                       "describeError(_:)",
                                       "shoutAll(_:)",
                                       "describeValue(_:)",
                                       "greetOnce(_:_:)",
                                       "CancelLog",
                                       "waitForCancel(_:)",
                                       "Shelf",
                                       "Grid",
                                       "describe(_:)",
                                       "makeLabel(_:)",
                                       "tags(_:)",
                                       "firstSubview(of:)",
                                       "Note",
                                       "CounterView",
                                       "makeNote(_:)",
                                       "text(of:)",
                                       "noteLater(_:)",
                                       "viewTag(_:)",
                                       "midpoint(_:_:)",
                                       "inset(_:by:)",
                                       "fitting(_:)",
                                       "latitudeSpan(_:_:)",
                                       "tagOf(_:)",
                                       "Money",
                                       "Wallet",
                                       "Coin",
                                       "formatted(_:)",
                                       "Pair",
                                       "Box",
                                       "Outcome"};
  CHECK_EQ(llvm::join(names, ","), llvm::join(expected, ","));
}

TEST(NominalKinds) {
  CHECK(symbolAt(demo(), "Demo")->kind == SymbolKind::Class);
  CHECK(symbolAt(demo(), "Point")->kind == SymbolKind::Struct);
  CHECK(symbolAt(demo(), "Flavor")->kind == SymbolKind::Enum);
  CHECK(symbolAt(demo(), "Greeter")->kind == SymbolKind::Protocol);
  CHECK(symbolAt(demo(), "Counter")->kind == SymbolKind::Actor);
  CHECK(symbolAt(demo(), "Polygon")->access == AccessLevel::Open);
  CHECK(symbolAt(demo(), "Demo")->access == AccessLevel::Public);
}

TEST(ExtensionMembersJoinTheirType) {
  const Symbol* demoType = symbolAt(demo(), "Demo");
  REQUIRE(demoType);
  auto names = memberNames(demo(), *demoType);
  CHECK(contains(names, "init()"));
  CHECK(contains(names, "greet(name:)"));
  CHECK(contains(names, "greet(name:times:)"));
  CHECK(contains(names, "version"));

  const Symbol* version = symbolAt(demo(), "Demo.version");
  REQUIRE(version);
  CHECK(version->isStatic);
  CHECK_EQ(version->parentId, demoType->preciseId);
}

TEST(OverloadsKeepDistinctIdentities) {
  auto overloads = symbolsAt(demo(), "Polygon.scale(by:)");
  REQUIRE(overloads.size() == 2);
  CHECK(overloads[0]->preciseId != overloads[1]->preciseId);
  std::vector<std::string> types;
  for (const Symbol* overload : overloads) {
    REQUIRE(overload->parameters.size() == 1);
    CHECK_EQ(overload->parameters[0].label, std::string("by"));
    CHECK_EQ(overload->parameters[0].internalName, std::string("factor"));
    types.push_back(overload->parameters[0].type.spelling);
  }
  std::sort(types.begin(), types.end());
  CHECK_EQ(llvm::join(types, ","), std::string("Double,Int"));
}

TEST(ParameterLabels) {
  const Symbol* describe = symbolAt(demo(), "Polygon.describe(_:)");
  REQUIRE(describe && describe->parameters.size() == 1);
  CHECK_EQ(describe->parameters[0].label, std::string());
  CHECK_EQ(describe->parameters[0].internalName, std::string("polygon"));
  CHECK_EQ(describe->parameters[0].type.spelling, std::string("Polygon?"));
  CHECK(describe->isStatic);

  const Symbol* fetch = symbolAt(demo(), "Loader.fetch(url:)");
  REQUIRE(fetch && fetch->parameters.size() == 1);
  CHECK_EQ(fetch->parameters[0].label, std::string("url"));
  CHECK_EQ(fetch->parameters[0].internalName, std::string("url"));
  REQUIRE(fetch->parameters[0].type.fragments.size() == 1);
  CHECK_EQ(fetch->parameters[0].type.fragments[0].preciseIdentifier,
           std::string("s:10Foundation3URLV"));

  const Symbol* plus = symbolAt(demo(), "Ring.+(_:_:)");
  REQUIRE(plus && plus->parameters.size() == 2);
  CHECK(plus->kind == SymbolKind::Operator);
  CHECK(plus->isStatic);
  CHECK_EQ(plus->parameters[1].internalName, std::string("rhs"));
  CHECK_EQ(plus->returnType->spelling, std::string("Ring"));
}

TEST(Effects) {
  const Symbol* fetch = symbolAt(demo(), "Loader.fetch(url:)");
  REQUIRE(fetch);
  CHECK(fetch->isAsync);
  CHECK(fetch->isThrowing);
  CHECK_EQ(fetch->returnType->spelling, std::string("String"));

  const Symbol* load = symbolAt(demo(), "Loader.load(path:)");
  REQUIRE(load);
  CHECK(!load->isAsync);
  CHECK(load->isThrowing);

  const Symbol* wait = symbolAt(demo(), "Loader.wait(seconds:)");
  REQUIRE(wait);
  CHECK(wait->isAsync);
  CHECK(!wait->isThrowing);
  CHECK(!wait->returnType);
}

TEST(EffectsInsideClosureTypesDoNotLeak) {
  // The synthesized actor method takes an `async throws(E)` closure; only the
  // method's own effects may be recorded.
  for (const Symbol* symbol :
       symbolsAt(demo(), "Counter.withSerialExecutor(_:)")) {
    REQUIRE(symbol->parameters.size() == 1);
    CHECK(symbol->isThrowing);
    CHECK_EQ(symbol->thrownType.spelling, std::string("E"));
    CHECK_EQ(symbol->returnType->spelling, std::string("T"));
    CHECK(symbol->isSynthesized);
  }
}

TEST(Properties) {
  const Symbol* x = symbolAt(demo(), "Point.x");
  REQUIRE(x && x->valueType);
  CHECK_EQ(x->valueType->spelling, std::string("Double"));
  CHECK(x->isSettable);

  const Symbol* vertexCount = symbolAt(demo(), "Polygon.vertexCount");
  REQUIRE(vertexCount);
  CHECK(!vertexCount->isSettable);

  const Symbol* name = symbolAt(demo(), "Polygon.name");
  REQUIRE(name);
  CHECK(name->isLet);
  CHECK(!name->isSettable);

  const Symbol* shared = symbolAt(demo(), "Polygon.shared");
  REQUIRE(shared && shared->valueType);
  CHECK(shared->isStatic);
  CHECK_EQ(shared->valueType->spelling, std::string("Polygon"));

  const Symbol* area = symbolAt(demo(), "Shape.area");
  REQUIRE(area);
  CHECK(area->isProtocolRequirement);
  CHECK(!area->isSettable);

  const Symbol* globalCounter = symbolAt(demo(), "globalCounter");
  REQUIRE(globalCounter);
  CHECK(globalCounter->kind == SymbolKind::Variable);
  CHECK(globalCounter->isSettable);
}

TEST(Subscripts) {
  const Symbol* subscript = symbolAt(demo(), "Polygon.subscript(_:)");
  REQUIRE(subscript && subscript->valueType);
  CHECK(subscript->kind == SymbolKind::InstanceSubscript);
  CHECK_EQ(subscript->valueType->spelling, std::string("Point"));
  CHECK(!subscript->isSettable);
  REQUIRE(subscript->parameters.size() == 1);
  CHECK_EQ(subscript->parameters[0].label, std::string());
  CHECK_EQ(subscript->parameters[0].internalName, std::string("index"));
}

TEST(Initializers) {
  const Symbol* failable = symbolAt(demo(), "Polygon.init(name:)");
  REQUIRE(failable);
  CHECK(failable->isFailable);
  CHECK(contains(failable->modifiers, "convenience"));

  const Symbol* designated =
      symbolAt(demo(), "Polygon.init(name:vertexCount:)");
  REQUIRE(designated);
  CHECK(!designated->isFailable);
  CHECK_EQ(designated->parameters.size(), size_t(2));

  const Symbol* rawValue = symbolAt(demo(), "Flavor.init(rawValue:)");
  REQUIRE(rawValue);
  CHECK(rawValue->isFailable);
  CHECK_EQ(rawValue->parameters[0].type.spelling, std::string("Int"));
}

TEST(EnumCases) {
  const Symbol* area = symbolAt(demo(), "Measurement.area(width:height:)");
  REQUIRE(area && area->parameters.size() == 2);
  CHECK(area->kind == SymbolKind::EnumCase);
  CHECK_EQ(area->parameters[0].label, std::string("width"));
  CHECK_EQ(area->parameters[1].type.spelling, std::string("Double"));

  const Symbol* length = symbolAt(demo(), "Measurement.length(_:)");
  REQUIRE(length && length->parameters.size() == 1);
  CHECK_EQ(length->parameters[0].label, std::string());

  const Symbol* none = symbolAt(demo(), "Measurement.none");
  REQUIRE(none);
  CHECK(none->parameters.empty());

  const Symbol* flavor = symbolAt(demo(), "Flavor");
  REQUIRE(flavor);
  auto names = memberNames(demo(), *flavor);
  CHECK(contains(names, "vanilla"));
  CHECK(contains(names, "chocolate"));
}

TEST(NestedTypes) {
  const Symbol* unit = symbolAt(demo(), "Measurement.Unit");
  const Symbol* measurement = symbolAt(demo(), "Measurement");
  REQUIRE(unit && measurement);
  CHECK(unit->kind == SymbolKind::Struct);
  CHECK_EQ(unit->parentId, measurement->preciseId);
  CHECK(!contains(demo().topLevelIds, unit->preciseId));
}

TEST(ParameterModifiersAndAttributes) {
  const Symbol* update = symbolAt(demo(), "Loader.update(_:)");
  REQUIRE(update && update->parameters.size() == 1);
  CHECK_EQ(update->parameters[0].modifier, std::string("inout"));
  CHECK_EQ(update->parameters[0].type.spelling, std::string("Point"));

  const Symbol* completion = symbolAt(demo(), "Loader.withCompletion(_:)");
  REQUIRE(completion && completion->parameters.size() == 1);
  CHECK(contains(completion->parameters[0].attributes, "@escaping"));
  CHECK_EQ(completion->parameters[0].type.spelling,
           std::string("(Result<String, ShapeError>) -> Void"));

  const Symbol* each = symbolAt(demo(), "Loader.each(_:)");
  REQUIRE(each && each->parameters.size() == 1);
  CHECK(each->parameters[0].attributes.empty());

  for (const Symbol* symbol :
       symbolsAt(demo(), "Counter.preconditionIsolated(_:file:line:)")) {
    REQUIRE(symbol->parameters.size() == 3);
    CHECK(contains(symbol->parameters[0].attributes, "@autoclosure"));
    CHECK_EQ(symbol->parameters[0].defaultValue, std::string("String()"));
    CHECK_EQ(symbol->parameters[1].defaultValue, std::string("#fileID"));
  }
}

TEST(Generics) {
  const Symbol* transform = symbolAt(demo(), "Loader.transform(_:)");
  REQUIRE(transform);
  REQUIRE(transform->genericParameters.size() == 1);
  CHECK_EQ(transform->genericParameters[0].name, std::string("T"));
  REQUIRE(transform->genericConstraints.size() == 1);
  CHECK_EQ(transform->genericConstraints[0].kind, std::string("conformance"));
  CHECK_EQ(transform->genericConstraints[0].rhs, std::string("Shape"));
  CHECK_EQ(transform->returnType->spelling, std::string("T"));
}

TEST(ActorIsolation) {
  const Symbol* canvas = symbolAt(demo(), "Canvas");
  REQUIRE(canvas);
  CHECK(contains(canvas->attributes, "@MainActor"));
  CHECK(contains(canvas->modifiers, "final"));

  const Symbol* label = symbolAt(demo(), "Counter.label()");
  REQUIRE(label);
  CHECK(contains(label->attributes, "nonisolated"));

  const Symbol* increment = symbolAt(demo(), "Counter.increment()");
  REQUIRE(increment);
  CHECK(increment->attributes.empty());
}

TEST(InheritanceConformanceAndOverrides) {
  const Symbol* square = symbolAt(demo(), "Square");
  const Symbol* polygon = symbolAt(demo(), "Polygon");
  const Symbol* shape = symbolAt(demo(), "Shape");
  const Symbol* greeter = symbolAt(demo(), "Greeter");
  REQUIRE(square && polygon && shape && greeter);
  CHECK_EQ(square->superclassId, polygon->preciseId);
  CHECK(contains(square->conformances, shape->preciseId));
  CHECK(contains(shape->conformances, greeter->preciseId));

  const Symbol* override = nullptr;
  for (const Symbol* candidate : symbolsAt(demo(), "Square.scale(by:)")) {
    override = candidate;
  }
  REQUIRE(override);
  CHECK(contains(override->modifiers, "override"));
  REQUIRE(!override->overriddenId.empty());
  const Symbol* base = demo().find(override->overriddenId);
  REQUIRE(base);
  CHECK_EQ(base->parameters[0].type.spelling, std::string("Double"));

  const Symbol* point = symbolAt(demo(), "Point");
  REQUIRE(point);
  CHECK(contains(point->conformances, "s:s23CustomStringConvertibleP"));
  CHECK_EQ(demo().externalNames.at("s:s23CustomStringConvertibleP"),
           std::string("Swift.CustomStringConvertible"));
}

TEST(ProtocolRequirementsAndWitnesses) {
  const Symbol* greeter = symbolAt(demo(), "Greeter");
  REQUIRE(greeter);
  auto names = memberNames(demo(), *greeter);
  CHECK_EQ(llvm::join(names, ","), std::string("greet(name:)"));

  const Symbol* requirement = symbolAt(demo(), "Greeter.greet(name:)");
  const Symbol* witness = symbolAt(demo(), "Demo.greet(name:)");
  REQUIRE(requirement && witness);
  CHECK(requirement->isProtocolRequirement);
  CHECK(!witness->isProtocolRequirement);
  CHECK_EQ(witness->sourceOriginId, requirement->preciseId);
}

TEST(ExtensionsOfExternalTypes) {
  auto it = demo().externalTypes.find("s:SS");
  REQUIRE(it != demo().externalTypes.end());
  const ExternalType& string = it->second;
  CHECK_EQ(string.qualifiedName, std::string("Swift.String"));
  CHECK_EQ(string.extendedModule, std::string("Swift"));
  CHECK_EQ(string.typeKind, std::string("swift.struct"));
  REQUIRE(string.memberIds.size() == 1);
  const Symbol* shouted = demo().find(string.memberIds[0]);
  REQUIRE(shouted);
  CHECK_EQ(shouted->name, std::string("shouted"));
  CHECK_EQ(shouted->sourceGraph, std::string("SwiftDemo@Swift.symbols.json"));
  CHECK(!contains(demo().topLevelIds, shouted->preciseId));

  auto array = demo().externalTypes.find("s:Sa");
  REQUIRE(array != demo().externalTypes.end());
  REQUIRE(array->second.memberIds.size() == 1);
  const Symbol* centroid = demo().find(array->second.memberIds[0]);
  REQUIRE(centroid && centroid->extension);
  REQUIRE(centroid->extension->constraints.size() == 1);
  CHECK_EQ(centroid->extension->constraints[0].kind, std::string("sameType"));
  CHECK_EQ(centroid->extension->constraints[0].rhs, std::string("Point"));
}

TEST(Availability) {
  const Symbol* modern = symbolAt(demo(), "Loader.modernOnly()");
  REQUIRE(modern && modern->availability.size() == 1);
  CHECK_EQ(modern->availability[0].domain, std::string("iOS"));
  REQUIRE(modern->availability[0].introduced);
  CHECK_EQ(modern->availability[0].introduced->major, 16);

  const Symbol* legacy = symbolAt(demo(), "Loader.legacyFetch()");
  REQUIRE(legacy && legacy->availability.size() == 1);
  CHECK_EQ(legacy->availability[0].domain, std::string("*"));
  CHECK(legacy->availability[0].isUnconditionallyDeprecated);
  CHECK_EQ(legacy->availability[0].message,
           std::string("Use fetch(url:) instead"));

  const Symbol* old = symbolAt(demo(), "Loader.oldFetch()");
  REQUIRE(old && old->availability.size() == 1);
  REQUIRE(old->availability[0].deprecated);
  CHECK_EQ(old->availability[0].deprecated->major, 17);
  CHECK_EQ(old->availability[0].renamed, std::string("fetch(url:)"));
}

TEST(SynthesizedMembers) {
  const Symbol* hashValue = symbolAt(demo(), "Flavor.hashValue");
  REQUIRE(hashValue);
  CHECK(hashValue->isSynthesized);
  CHECK(!hashValue->location);
  CHECK(!hashValue->sourceOriginId.empty());

  const Symbol* greet = symbolAt(demo(), "Demo.greet(name:)");
  REQUIRE(greet);
  CHECK(!greet->isSynthesized);
}

TEST(NonPublicDeclarationsAreAbsent) {
  CHECK(symbolsAt(demo(), "Polygon.hiddenHelper()").empty());
}

TEST(TypeAliases) {
  const Symbol* alias = symbolAt(demo(), "Coordinates");
  REQUIRE(alias && alias->aliasedType);
  CHECK_EQ(alias->aliasedType->spelling,
           std::string("(latitude: Double, longitude: Double)"));
}

TEST(GenericFunctionInstantiations) {
  auto standIns = [](const std::string& path) {
    const Symbol* generic = symbolAt(demo(), path);
    std::vector<std::string> result;
    if (!generic) {
      return std::vector<std::string>{"missing"};
    }
    for (const auto& entry : demo().symbols) {
      if (entry.second.genericBase != generic->preciseId) {
        continue;
      }
      std::vector<std::string> parts;
      for (const auto& substitution : entry.second.substitutions) {
        parts.push_back(substitution.first + "=" + spelling(substitution.second));
      }
      result.push_back(llvm::join(parts, ","));
    }
    std::sort(result.begin(), result.end());
    return result;
  };
  using List = std::vector<std::string>;
  CHECK(standIns("largest(_:)") == List({"T=Double", "T=String"}));
  CHECK(standIns("repeated(_:times:)") == List({"T=Bool", "T=Double", "T=String"}));
  CHECK(standIns("popCount(_:)") == List({"I=Int"}));
  // One stand-in: the result alone decides it.
  CHECK(standIns("zero()") == List({"N=Double"}));
  CHECK(standIns("greetTwice(_:_:)") == List({"G=any Greeting"}));
  CHECK(standIns("viewTag(_:)") == List({"V=UIView"}));
  CHECK(standIns("Loader.first(of:)") == List({"Element=Bool", "Element=Double", "Element=String"}));
  // The arguments of the unit's Box and Pair instantiations.
  CHECK(standIns("unbox(_:)").size() == 2);
  CHECK(standIns("firstOf(_:)").size() == 4);
  // `some P` parameters.
  CHECK(standIns("shoutAll(_:)") == List({"some StringProtocol=String"}));
  CHECK(standIns("describeValue(_:)") ==
        List({"some CustomStringConvertible=Bool",
              "some CustomStringConvertible=Double",
              "some CustomStringConvertible=String"}));
  CHECK(standIns("greetOnce(_:_:)") == List({"some Greeting=any Greeting"}));
  CHECK(standIns("tagOf(_:)") == List({"some UIView=UIView"}));
  CHECK(standIns("decodeJSON(_:from:)").empty());
  CHECK(standIns("firstElement(_:)").empty());
  // 3 x 3 combinations.
  CHECK(standIns("joined(_:_:)").empty());
}

TEST(IRSnapshot) { checkSnapshot("SwiftDemo.ir.json", dumpModuleJSON(demo())); }

TEST(TypeScriptSnapshot) {
  Classification classification = classify(demo());
  for (const auto& name : demo().swiftModules()) {
    TypeScript::SwiftDefinitionWriter writer(demo(), classification, name);
    checkSnapshot("swift!" + name + ".d.ts", writer.write());
  }
}

TEST(LoadOrderDoesNotChangeTheIR) {
  std::vector<Diagnostic> diagnostics;
  auto files =
      SymbolGraphLoader::findGraphFiles(SWIFT_FIXTURE_GRAPHS_DIR, diagnostics);
  REQUIRE(files.size() == 4);

  SymbolGraphLoader reversed;
  for (auto it = files.rbegin(); it != files.rend(); ++it) {
    reversed.addFile(*it, llvm::sys::path::filename(*it).str());
  }
  ModuleSet set = reversed.finish();
  REQUIRE(set.modules.count("SwiftDemo"));
  Module unit = mergeUnit(set, "SwiftDemo");
  instantiateGenerics(unit);
  CHECK(dumpModuleJSON(unit) == dumpModuleJSON(demo()));
}

TEST(InvalidJSONIsAnError) {
  ModuleSet set = loadBuffers({{"broken.symbols.json", "{\"metadata\": "}});
  CHECK(set.hasErrors());
  CHECK(set.modules.empty());
  REQUIRE(set.diagnostics.size() == 1);
  CHECK_EQ(set.diagnostics[0].code, std::string("invalid-json"));
  CHECK_EQ(set.diagnostics[0].file, std::string("broken.symbols.json"));
}

TEST(UnsupportedFormatMajorIsRejected) {
  ModuleSet set =
      loadBuffers({{"future.symbols.json", graphJSON("", "", "1.0.0")}});
  CHECK(set.hasErrors());
  CHECK(set.modules.empty());
  CHECK_EQ(set.diagnostics[0].code, std::string("unsupported-format-version"));
}

TEST(NewerFormatMinorLoadsWithWarning) {
  ModuleSet set =
      loadBuffers({{"newer.symbols.json", graphJSON("", "", "0.9.0")}});
  CHECK(!set.hasErrors());
  CHECK_EQ(set.modules.count("Mini"), size_t(1));
  REQUIRE(set.diagnostics.size() == 1);
  CHECK_EQ(set.diagnostics[0].code, std::string("newer-format-version"));
}

TEST(UnknownKindsAreReportedAndKept) {
  std::string symbol =
      symbolJSON("s:4Mini1xv", "swift.newfangled", "x",
                 R"({"kind":"keyword","spelling":"newfangled"})");
  ModuleSet set = loadBuffers({{"mini.symbols.json", graphJSON(symbol, "")}});
  REQUIRE(set.modules.count("Mini"));
  const Symbol* x = set.modules.at("Mini").find("s:4Mini1xv");
  REQUIRE(x);
  CHECK(x->kind == SymbolKind::Unknown);
  CHECK_EQ(x->kindIdentifier, std::string("swift.newfangled"));
  bool reported = false;
  for (const auto& diagnostic : set.diagnostics) {
    reported |= diagnostic.code == "unknown-symbol-kind" &&
                diagnostic.symbolId == "s:4Mini1xv";
  }
  CHECK(reported);
}

TEST(DanglingRelationshipsAreReported) {
  ModuleSet set = loadBuffers(
      {{"mini.symbols.json",
        graphJSON(
            "",
            R"({"kind":"memberOf","source":"s:missing","target":"s:alsoMissing"})")}});
  REQUIRE(set.diagnostics.size() == 1);
  CHECK_EQ(set.diagnostics[0].code, std::string("dangling-relationship"));
  CHECK(!set.hasErrors());
}

TEST(ConflictingDuplicateSymbolsAreReported) {
  std::string first = symbolJSON(
      "s:4Mini1fyyF", "swift.func", "f()",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"f"},{"kind":"text","spelling":"()"})json");
  std::string second = symbolJSON(
      "s:4Mini1fyyF", "swift.func", "f()",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"f"},{"kind":"text","spelling":"() async"})json");
  ModuleSet set = loadBuffers({{"a.symbols.json", graphJSON(first, "")},
                               {"b.symbols.json", graphJSON(second, "")}});
  REQUIRE(set.modules.count("Mini"));
  CHECK_EQ(set.modules.at("Mini").symbols.size(), size_t(1));
  CHECK_EQ(set.modules.at("Mini").find("s:4Mini1fyyF")->sourceGraph,
           std::string("a.symbols.json"));
  REQUIRE(set.diagnostics.size() == 1);
  CHECK_EQ(set.diagnostics[0].code, std::string("duplicate-symbol"));

  ModuleSet identical = loadBuffers({{"a.symbols.json", graphJSON(first, "")},
                                     {"b.symbols.json", graphJSON(first, "")}});
  CHECK(identical.diagnostics.empty());
}

TEST(AsyncImportVariantsAreBothKept) {
  // Swift imports an Objective-C completion-handler method twice under one
  // USR: as written and as an `async` variant.
  std::string usr = "c:objc(cs)Mini(im)loadWithCompletion:";
  std::string type = symbolJSON(
      "c:objc(cs)Mini", "swift.class", "Mini",
      R"json({"kind":"keyword","spelling":"class"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"Mini"})json");
  std::string callback = symbolJSON(
      usr, "swift.method", "load(completion:)",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"load"},{"kind":"text","spelling":"("},{"kind":"externalParam","spelling":"completion"},{"kind":"text","spelling":": "},{"kind":"attribute","spelling":"@escaping"},{"kind":"text","spelling":" () -> "},{"kind":"typeIdentifier","spelling":"Void"},{"kind":"text","spelling":")"})json",
      "Mini");
  std::string async = symbolJSON(
      usr, "swift.method", "load()",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"load"},{"kind":"text","spelling":"() "},{"kind":"keyword","spelling":"async"})json",
      "Mini");
  std::string relationship = R"({"kind":"memberOf","source":")" + usr +
                             R"(","target":"c:objc(cs)Mini"})";

  for (bool asyncFirst : {false, true}) {
    std::string symbols =
        type + "," +
        (asyncFirst ? async + "," + callback : callback + "," + async);
    ModuleSet set =
        loadBuffers({{"mini.symbols.json", graphJSON(symbols, relationship)}});
    CHECK_EQ(diagnosticCodes(set.diagnostics), std::string());
    REQUIRE(set.modules.count("Mini"));
    const Module& module = set.modules.at("Mini");
    const Symbol* original = module.find(usr);
    const Symbol* variant = module.find(usr + "#async");
    REQUIRE(original && variant);
    CHECK(!original->isAsync);
    CHECK(variant->isAsync);
    CHECK_EQ(variant->usr, usr);
    CHECK_EQ(variant->name, std::string("load()"));
    CHECK_EQ(memberNames(module, *module.find("c:objc(cs)Mini")).size(),
             size_t(2));
  }
}

TEST(SubclassRedeclarationsAreKeyedByOwner) {
  // NSMutableArray redeclares NSArray's subscript (adding a setter) under the
  // same USR.
  std::string usr = "c:objc(cs)NSArray(im)objectAtIndexedSubscript:";
  auto type = [](const std::string& name) {
    return symbolJSON(
        "c:objc(cs)" + name, "swift.class", name,
        R"json({"kind":"keyword","spelling":"class"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":")json" +
            name + R"json("})json");
  };
  auto subscript = [&](const std::string& owner, const std::string& accessors) {
    return symbolJSON(
        usr, "swift.subscript", "subscript(_:)",
        R"json({"kind":"keyword","spelling":"subscript"},{"kind":"text","spelling":"("},{"kind":"internalParam","spelling":"idx"},{"kind":"text","spelling":": "},{"kind":"typeIdentifier","spelling":"Int"},{"kind":"text","spelling":") -> "},{"kind":"keyword","spelling":"Any"},{"kind":"text","spelling":" { "},)json" +
            accessors + R"json({"kind":"text","spelling":" }"})json",
        owner);
  };
  std::string base =
      subscript("NSArray", R"json({"kind":"keyword","spelling":"get"},)json");
  std::string mutableVariant = subscript(
      "NSMutableArray",
      R"json({"kind":"keyword","spelling":"get"},{"kind":"text","spelling":" "},{"kind":"keyword","spelling":"set"},)json");
  std::string relationships =
      R"({"kind":"memberOf","source":")" + usr +
      R"(","target":"c:objc(cs)NSArray"},{"kind":"memberOf","source":")" + usr +
      R"(","target":"c:objc(cs)NSMutableArray"})";

  for (bool mutableFirst : {false, true}) {
    std::string symbols = type("NSArray") + "," + type("NSMutableArray") + "," +
                          (mutableFirst ? mutableVariant + "," + base
                                        : base + "," + mutableVariant);
    ModuleSet set =
        loadBuffers({{"mini.symbols.json", graphJSON(symbols, relationships)}});
    CHECK_EQ(diagnosticCodes(set.diagnostics), std::string());
    REQUIRE(set.modules.count("Mini"));
    const Module& module = set.modules.at("Mini");
    const Symbol* plain = module.find(usr);
    const Symbol* owned = module.find(usr + "#NSMutableArray");
    REQUIRE(plain && owned);
    CHECK(!plain->isSettable);
    CHECK(owned->isSettable);
    CHECK_EQ(plain->parentId, std::string("c:objc(cs)NSArray"));
    CHECK_EQ(owned->parentId, std::string("c:objc(cs)NSMutableArray"));
    CHECK_EQ(module.find("c:objc(cs)NSArray")->memberIds.size(), size_t(1));
    CHECK_EQ(module.find("c:objc(cs)NSMutableArray")->memberIds.size(),
             size_t(1));
  }
}

TEST(ExternalConformancesAreRecorded) {
  std::string relationship =
      R"({"kind":"conformsTo","source":"s:Sa","target":"s:4Mini1PP"},)"
      R"({"kind":"memberOf","source":"s:4Mini1fyyF","target":"s:Sa","targetFallback":"Swift.Array"})";
  std::string member = symbolJSON(
      "s:4Mini1fyyF", "swift.method", "f()",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"f"},{"kind":"text","spelling":"()"})json");
  ModuleSet set =
      loadBuffers({{"mini.symbols.json", graphJSON(member, relationship)}});
  CHECK_EQ(diagnosticCodes(set.diagnostics), std::string());
  REQUIRE(set.modules.count("Mini"));
  const auto& externals = set.modules.at("Mini").externalTypes;
  REQUIRE(externals.count("s:Sa"));
  CHECK_EQ(externals.at("s:Sa").qualifiedName, std::string("Swift.Array"));
  CHECK_EQ(llvm::join(externals.at("s:Sa").conformances, ","),
           std::string("s:4Mini1PP"));
}

TEST(SkimmerHandlesStringsAndNesting) {
  // Braces, brackets and escaped quotes inside strings must not affect the
  // structural scan.
  std::string symbol = symbolJSON(
      "s:4Mini1fyyF", "swift.func", "f()",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"f"},{"kind":"text","spelling":"()"})json");
  symbol.insert(
      symbol.size() - 1,
      R"json(,"docComment":{"lines":[{"text":"a } ] { [ \"quoted\" \\"}]})json");
  ModuleSet set = loadBuffers({{"mini.symbols.json", graphJSON(symbol, "")}});
  CHECK_EQ(diagnosticCodes(set.diagnostics), std::string());
  REQUIRE(set.modules.count("Mini"));
  const Symbol* f = set.modules.at("Mini").find("s:4Mini1fyyF");
  REQUIRE(f);
  CHECK_EQ(f->docComment, std::string("a } ] { [ \"quoted\" \\"));

  ModuleSet trailing =
      loadBuffers({{"mini.symbols.json", graphJSON(symbol, "") + " {}"}});
  CHECK(trailing.hasErrors());
  CHECK_EQ(trailing.diagnostics[0].code, std::string("invalid-json"));
}

TEST(LabelMismatchesAreReported) {
  // Name claims a labeled argument the declaration does not have.
  std::string symbol = symbolJSON(
      "s:4Mini1fyySiF", "swift.func", "f(value:)",
      R"json({"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"f"},{"kind":"text","spelling":"("},{"kind":"externalParam","spelling":"_"},{"kind":"text","spelling":" "},{"kind":"internalParam","spelling":"value"},{"kind":"text","spelling":": "},{"kind":"typeIdentifier","spelling":"Int"},{"kind":"text","spelling":")"})json");
  ModuleSet set = loadBuffers({{"mini.symbols.json", graphJSON(symbol, "")}});
  REQUIRE(set.diagnostics.size() == 1);
  CHECK_EQ(set.diagnostics[0].code, std::string("parameter-label-mismatch"));
}

TEST(MissingDirectoryIsAnError) {
  ModuleSet set =
      loadSymbolGraphDirectory(SWIFT_FIXTURE_GRAPHS_DIR "/does-not-exist");
  CHECK(set.hasErrors());
  CHECK_EQ(set.diagnostics[0].code, std::string("missing-directory"));
}
