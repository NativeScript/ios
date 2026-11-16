#include "Swift/SwiftTypes.h"
#include "TestHarness.h"
#include "TestSupport.h"

using namespace Swift;
using namespace TestSupport;

namespace {

TypeRef ref(std::vector<Fragment> fragments) {
  TypeRef type;
  for (const auto& fragment : fragments) {
    type.spelling += fragment.spelling;
  }
  type.fragments = std::move(fragments);
  return type;
}

Fragment id(const std::string& name, const std::string& usr = "") {
  return Fragment{"typeIdentifier", name, usr};
}

Fragment text(const std::string& spelling) {
  return Fragment{"text", spelling, ""};
}

Fragment keyword(const std::string& spelling) {
  return Fragment{"keyword", spelling, ""};
}

TypeNode parse(const TypeRef& type, std::set<std::string> generics = {},
               bool expectComplete = true) {
  bool complete = false;
  TypeNode node = parseType(type, generics, &complete);
  if (complete != expectComplete) {
    TestHarness::fail(__FILE__, __LINE__,
                      "parse of '" + type.spelling +
                          "' complete=" + std::to_string(complete));
  }
  return node;
}

using Kind = TypeNode::Kind;

}  // namespace

TEST(TypesOptionalNominal) {
  TypeNode node =
      parse(ref({id("Polygon", "s:9SwiftDemo7PolygonC"), text("?")}));
  CHECK(node.kind == Kind::Optional);
  REQUIRE(node.children.size() == 1);
  CHECK(node.children[0].kind == Kind::Nominal);
  CHECK_EQ(node.children[0].usr(), std::string("s:9SwiftDemo7PolygonC"));
  CHECK_EQ(spelling(node), std::string("Polygon?"));
}

TEST(TypesNamedGenericsNormalize) {
  TypeNode optional = parse(
      ref({id("Optional", "s:Sq"), text("<"), id("Int", "s:Si"), text(">")}));
  CHECK(optional.kind == Kind::Optional);
  TypeNode array = parse(
      ref({id("Array", "s:Sa"), text("<"), id("Int", "s:Si"), text(">")}));
  CHECK(array.kind == Kind::Array);
  TypeNode voidType = parse(ref({id("Void", "s:s4Voida")}));
  CHECK(voidType.kind == Kind::Void);
  TypeNode empty = parse(ref({text("()")}));
  CHECK(empty.kind == Kind::Void);
}

TEST(TypesCollections) {
  TypeNode dictionary = parse(ref({text("["), id("String", "s:SS"), text(" : "),
                                   id("Int", "s:Si"), text("]")}));
  CHECK(dictionary.kind == Kind::Dictionary);
  CHECK_EQ(spelling(dictionary), std::string("[String: Int]"));

  TypeNode array =
      parse(ref({text("["), id("Element"), text("]")}), {"Element"});
  CHECK(array.kind == Kind::Array);
  CHECK(array.children[0].kind == Kind::GenericParameter);
}

TEST(TypesFunctions) {
  TypeNode completion = parse(ref(
      {text("("), id("Result", "s:s6ResultO"), text("<"), id("String", "s:SS"),
       text(", "), id("ShapeError", "s:9SwiftDemo10ShapeErrorO"),
       text(">) -> "), id("Void", "s:s4Voida")}));
  CHECK(completion.kind == Kind::Function);
  REQUIRE(completion.children.size() == 1);
  CHECK_EQ(completion.children[0].components[0].arguments.size(), size_t(2));
  REQUIRE(completion.result.size() == 1);
  CHECK(completion.result[0].kind == Kind::Void);
  CHECK_EQ(spelling(completion),
           std::string("(Result<String, ShapeError>) -> Void"));

  TypeNode effects =
      parse(ref({text("("), keyword("any"), text(" "), id("SerialExecutor"),
                 text(") "), keyword("throws"), text("("), id("E"),
                 text(") -> "), id("T")}),
            {"E", "T"});
  CHECK(effects.kind == Kind::Function);
  CHECK(effects.isThrowing);
  REQUIRE(effects.thrownType.size() == 1);
  CHECK(effects.thrownType[0].kind == Kind::GenericParameter);
  CHECK(effects.children[0].kind == Kind::Existential);
  CHECK_EQ(spelling(effects),
           std::string("(any SerialExecutor) throws(E) -> T"));

  TypeNode isolated =
      parse(ref({Fragment{"attribute", "@", ""}, id("MainActor", "s:ScM"),
                 text(" ("), id("Message"), text(") "), keyword("async"),
                 text(" -> "), id("Void", "s:s4Voida")}));
  CHECK(isolated.kind == Kind::Function);
  CHECK(isolated.isAsync);
  CHECK(isolated.hasAttribute("@MainActor"));

  TypeNode optionalClosure =
      parse(ref({text("(("), id("URL"), text(", any "), id("Error"),
                 text(") -> "), id("Bool"), text(")?")}));
  CHECK(optionalClosure.kind == Kind::Optional);
  CHECK(optionalClosure.children[0].kind == Kind::Function);
  CHECK_EQ(spelling(optionalClosure),
           std::string("((URL, any Error) -> Bool)?"));
}

TEST(TypesTuplesKeepLabels) {
  TypeNode tuple =
      parse(ref({text("(latitude: "), id("Double", "s:Sd"),
                 text(", longitude: "), id("Double", "s:Sd"), text(")")}));
  CHECK(tuple.kind == Kind::Tuple);
  CHECK_EQ(llvm::join(tuple.labels, ","), std::string("latitude,longitude"));
  CHECK_EQ(spelling(tuple),
           std::string("(latitude: Double, longitude: Double)"));
}

TEST(TypesMemberAndMetatypes) {
  TypeNode member =
      parse(ref({id("AttributedString"), text("."), id("Index", "s:index")}));
  CHECK(member.kind == Kind::Nominal);
  CHECK_EQ(member.components.size(), size_t(2));
  CHECK_EQ(member.usr(), std::string("s:index"));

  TypeNode dependent = parse(ref({id("T"), text("."), id("Value")}), {"T"});
  CHECK(dependent.kind == Kind::GenericParameter);
  CHECK_EQ(spelling(dependent), std::string("T.Value"));

  TypeNode metatype = parse(ref({id("T"), text(".Type")}), {"T"});
  CHECK(metatype.kind == Kind::Metatype);
  CHECK_EQ(spelling(metatype), std::string("T.Type"));

  TypeNode nested = parse(ref({id("KeyPath"), text("<"), id("Scopes"),
                               text(", "), id("S"), text(".Type>")}),
                          {"S"});
  CHECK(nested.kind == Kind::Nominal);
  CHECK(nested.components[0].arguments[1].kind == Kind::Metatype);
}

TEST(TypesExistentialsAndCompositions) {
  TypeNode opaque = parse(ref({keyword("some"), text(" "), id("View")}));
  CHECK(opaque.kind == Kind::Opaque);

  TypeNode composition =
      parse(ref({text("any "), id("AnyKeyPath"), text(" & "), id("Sendable")}));
  CHECK(composition.kind == Kind::Existential);
  CHECK(composition.children[0].kind == Kind::Composition);
  CHECK_EQ(spelling(composition), std::string("any AnyKeyPath & Sendable"));

  TypeNode anyType = parse(ref({keyword("Any")}));
  CHECK(anyType.kind == Kind::Existential);
  CHECK_EQ(spelling(anyType), std::string("Any"));
}

TEST(TypesIsolationAttributeOnClosure) {
  TypeNode node =
      parse(ref({keyword("nonisolated"), text("(nonsending) ("), keyword("any"),
                 text(" "), id("SerialExecutor"), text(") "), keyword("async"),
                 text(" -> "), id("T")}),
            {"T"});
  CHECK(node.kind == Kind::Function);
  CHECK(node.hasAttribute("nonisolated(nonsending)"));
}

TEST(TypesParameterPacksAreIncomplete) {
  parse(ref({id("Predicate"), text("<repeat each "), id("Input"), text(">")}),
        {"Input"},
        /*expectComplete*/ false);
}

TEST(TypesEveryFixtureTypeParses) {
  for (const auto& entry : demo().symbols) {
    const Symbol& symbol = entry.second;
    std::set<std::string> generics = genericNamesInScope(demo(), symbol);
    std::vector<const TypeRef*> types;
    for (const auto& parameter : symbol.parameters) {
      types.push_back(&parameter.type);
    }
    if (symbol.returnType) {
      types.push_back(&*symbol.returnType);
    }
    if (symbol.valueType) {
      types.push_back(&*symbol.valueType);
    }
    if (symbol.aliasedType) {
      types.push_back(&*symbol.aliasedType);
    }
    for (const TypeRef* type : types) {
      bool complete = false;
      parseType(*type, generics, &complete);
      if (!complete) {
        TestHarness::fail(
            __FILE__, __LINE__,
            "incomplete parse of '" + type->spelling + "' in " + symbol.name);
      }
    }
  }
}
