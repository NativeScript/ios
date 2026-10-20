#include <llvm/ADT/StringExtras.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/raw_ostream.h>

#include <algorithm>
#include <cstdlib>

#include "Swift/SymbolGraphLoader.h"
#include "TestHarness.h"
#include "TypeScript/SwiftDefinitionWriter.h"

using namespace Swift;

namespace {

const ModuleSet& fixture() {
  static ModuleSet set = loadSymbolGraphDirectory(SWIFT_FIXTURE_GRAPHS_DIR);
  return set;
}

const Module& demo() {
  static const Module empty;
  auto it = fixture().modules.find("SwiftDemo");
  return it == fixture().modules.end() ? empty : it->second;
}

std::vector<const Symbol*> symbolsAt(const Module& module,
                                     const std::string& path) {
  std::vector<const Symbol*> result;
  for (const auto& entry : module.symbols) {
    if (llvm::join(entry.second.pathComponents, ".") == path) {
      result.push_back(&entry.second);
    }
  }
  return result;
}

const Symbol* symbolAt(const Module& module, const std::string& path) {
  auto symbols = symbolsAt(module, path);
  return symbols.size() == 1 ? symbols.front() : nullptr;
}

std::vector<std::string> memberNames(const Module& module,
                                     const Symbol& symbol) {
  std::vector<std::string> names;
  for (const auto& id : symbol.memberIds) {
    if (const Symbol* member = module.find(id)) {
      names.push_back(member->name);
    }
  }
  return names;
}

bool contains(const std::vector<std::string>& values,
              const std::string& value) {
  return std::find(values.begin(), values.end(), value) != values.end();
}

std::string diagnosticCodes(const std::vector<Diagnostic>& diagnostics) {
  std::vector<std::string> codes;
  for (const auto& diagnostic : diagnostics) {
    codes.push_back(diagnostic.code + "(" + diagnostic.message + ")");
  }
  return llvm::join(codes, ", ");
}

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

std::string symbolJSON(const std::string& id, const std::string& kind,
                       const std::string& path,
                       const std::string& declaration) {
  return R"({"kind":{"identifier":")" + kind +
         R"("},"identifier":{"precise":")" + id + R"("},"pathComponents":[")" +
         path +
         R"("],"names":{"title":"x"},"accessLevel":"public","declarationFragments":[)" +
         declaration + "]}";
}

// Compares `actual` against a checked-in snapshot. NS_UPDATE_SNAPSHOTS=1
// rewrites the snapshot instead.
void checkSnapshot(const std::string& fileName, const std::string& actual) {
  llvm::SmallString<256> snapshotPath(SWIFT_SNAPSHOT_DIR);
  llvm::sys::path::append(snapshotPath, fileName);

  if (const char* update = std::getenv("NS_UPDATE_SNAPSHOTS");
      update && *update == '1') {
    std::error_code error;
    llvm::raw_fd_ostream out(snapshotPath, error, llvm::sys::fs::OF_Text);
    REQUIRE(!error);
    out << actual;
    return;
  }

  auto expected = llvm::MemoryBuffer::getFile(snapshotPath, /*IsText*/ true);
  if (!expected) {
    TestHarness::fail(__FILE__, __LINE__,
                      "missing snapshot " + snapshotPath.str().str() +
                          " (run with NS_UPDATE_SNAPSHOTS=1)");
    return;
  }
  if ((*expected)->getBuffer() != actual) {
    llvm::SmallString<256> actualPath(snapshotPath);
    actualPath += ".actual";
    std::error_code error;
    llvm::raw_fd_ostream out(actualPath, error, llvm::sys::fs::OF_Text);
    out << actual;
    TestHarness::fail(__FILE__, __LINE__,
                      "snapshot mismatch: diff " + snapshotPath.str().str() +
                          " " + actualPath.str().str());
  }
}

}  // namespace

TEST(LoadsFixtureWithoutDiagnostics) {
  CHECK_EQ(fixture().modules.size(), size_t(1));
  CHECK_EQ(diagnosticCodes(fixture().diagnostics), std::string());
  const Module& module = demo();
  CHECK_EQ(module.name, std::string("SwiftDemo"));
  CHECK_EQ(module.graphFiles.size(), size_t(2));
  CHECK_EQ(module.platform.operatingSystem, std::string("ios"));
  CHECK_EQ(module.platform.environment, std::string("simulator"));
}

TEST(TopLevelDeclarationsInSourceOrder) {
  std::vector<std::string> names;
  for (const auto& id : demo().topLevelIds) {
    names.push_back(demo().find(id)->name);
  }
  std::vector<std::string> expected = {"Greeter",       "Demo",
                                       "Point",         "Flavor",
                                       "Shape",         "Polygon",
                                       "Square",        "ShapeError",
                                       "Measurement",   "Ring",
                                       "Counter",       "Canvas",
                                       "Loader",        "makeDefaultPoint()",
                                       "defaultFlavor", "globalCounter",
                                       "Coordinates"};
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

TEST(IRSnapshot) { checkSnapshot("SwiftDemo.ir.json", dumpModuleJSON(demo())); }

TEST(TypeScriptSnapshot) {
  TypeScript::SwiftDefinitionWriter writer(demo());
  checkSnapshot("swift!SwiftDemo.d.ts", writer.write());
}

TEST(LoadOrderDoesNotChangeTheIR) {
  std::vector<Diagnostic> diagnostics;
  auto files =
      SymbolGraphLoader::findGraphFiles(SWIFT_FIXTURE_GRAPHS_DIR, diagnostics);
  REQUIRE(files.size() == 2);

  SymbolGraphLoader reversed;
  for (auto it = files.rbegin(); it != files.rend(); ++it) {
    reversed.addFile(*it, llvm::sys::path::filename(*it).str());
  }
  ModuleSet set = reversed.finish();
  REQUIRE(set.modules.count("SwiftDemo"));
  CHECK(dumpModuleJSON(set.modules.at("SwiftDemo")) == dumpModuleJSON(demo()));
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

int main(int argc, char** argv) {
  return TestHarness::runAll(argc > 1 ? argv[1] : "");
}
