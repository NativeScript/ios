// Inform the test results runner that the runtime is up.
console.log('Application Start!');

require("./tests/Infrastructure/timers");
require("./tests/Infrastructure/simulator");

global.UNUSED = function (param) {
};

var args = NSProcessInfo.processInfo.arguments;
var logjunit = args.containsObject("-logjunit");

// Provides an output channel for jasmine JUnit test result xml.
global.__JUnitSaveResults = function (text) {
    TNSSaveResults(text);

    if (logjunit) {
        text.split('\n').forEach(function (line) {
            console.log("TKUnit: " + line);
        });
    }
};

global.__approot = NSString.stringWithString(NSBundle.mainBundle.bundlePath).stringByResolvingSymlinksInPath;

require("./tests/Infrastructure/Jasmine/jasmine-2.0.1/boot");

require("./tests/Marshalling/Primitives/Function");
require("./tests/Marshalling/Primitives/Static");
require("./tests/Marshalling/Primitives/Instance");
require("./tests/Marshalling/Primitives/Derived");
//
require("./tests/Marshalling/ObjCTypesTests");
require("./tests/Marshalling/ConstantsTests");
require("./tests/Marshalling/RecordTests");
//import "./Marshalling/VectorTests";
//import "./Marshalling/MatrixTests";
require("./tests/Marshalling/NSStringTests");
//import "./Marshalling/TypesTests";
require("./tests/Marshalling/PointerTests");
require("./tests/Marshalling/ReferenceTests");
//import "./Marshalling/FunctionPointerTests";
require("./tests/Marshalling/EnumTests");
require("./tests/Marshalling/ProtocolTests");
//
//// import "./Inheritance/ConstructorResolutionTests";
//import "./Inheritance/InheritanceTests";
//import "./Inheritance/ProtocolImplementationTests";
//import "./Inheritance/TypeScriptTests";
//
require("./tests/MethodCallsTests");
//import "./FunctionsTests";
//require("./tests/VersionDiffTests");
//require("./tests/ObjCConstructors");
//
require("./tests/MetadataTests");
//
require("./tests/ApiTests");
require("./tests/DeclarationConflicts");
//
require("./tests/Promises");
//require("./tests/Modules");
//
require("./tests/RuntimeImplementedAPIs");

// Tests common for all runtimes.
require("./tests/shared/index").runAllTests();

execute();

UIApplicationMain(0, null, null, null);
