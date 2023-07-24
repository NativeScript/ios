// Inform the test results runner that the runtime is up.
console.log('Application Start!');

require("./Infrastructure/timers");
require("./Infrastructure/simulator");
global.utf8 = require("./Infrastructure/utf8")

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

    var reportUrl = NSProcessInfo.processInfo.environment.objectForKey("REPORT_BASEURL");
    if (reportUrl) {
        var urlRequest = NSMutableURLRequest.requestWithURL(NSURL.URLWithString(reportUrl));
        urlRequest.HTTPMethod = "POST";
        urlRequest.setValueForHTTPHeaderField("Content-Type", "application/xml");
        urlRequest.HTTPBody = NSString.stringWithString(text).dataUsingEncoding(4);
        var sessionConfig = NSURLSessionConfiguration.defaultSessionConfiguration;
        var queue = NSOperationQueue.mainQueue;
        var session = NSURLSession.sessionWithConfigurationDelegateDelegateQueue(sessionConfig, null, queue);
        var dataTask = session.dataTaskWithRequestCompletionHandler(urlRequest, (data, response, error) => { });
        dataTask.resume();
    }
};

global.__approot = NSString.stringWithString(NSBundle.mainBundle.bundlePath).stringByResolvingSymlinksInPath;

require("./Infrastructure/Jasmine/jasmine-2.0.1/boot");

require("./Marshalling/Primitives/Function");
require("./Marshalling/Primitives/Static");
require("./Marshalling/Primitives/Instance");
require("./Marshalling/Primitives/Derived");
//
require("./Marshalling/ObjCTypesTests");
require("./Marshalling/ConstantsTests");
require("./Marshalling/RecordTests");
require("./Marshalling/VectorTests");
// todo: figure out why this test is failing with a EXC_BAD_ACCESS on TNSRecords.m matrix initialization
// require("./Marshalling/MatrixTests");
require("./Marshalling/NSStringTests");
//import "./Marshalling/TypesTests";
require("./Marshalling/PointerTests");
require("./Marshalling/ReferenceTests");
require("./Marshalling/FunctionPointerTests");
require("./Marshalling/EnumTests");
require("./Marshalling/ProtocolTests");
//
// import "./Inheritance/ConstructorResolutionTests";
require("./Inheritance/InheritanceTests");
require("./Inheritance/ProtocolImplementationTests");
require("./Inheritance/TypeScriptTests");
//
require("./MethodCallsTests");
//import "./FunctionsTests";
require("./VersionDiffTests");
require("./ObjCConstructors");
//
require("./MetadataTests");
//
require("./ApiTests");
require("./DeclarationConflicts");
//
require("./Promises");
require("./Modules");
//
require("./RuntimeImplementedAPIs");

require("./Timers");

// Tests common for all runtimes.
require("./shared/index").runAllTests();

// (Optional) Custom testing for various optional sdk's and frameworks
// These can be turned on manually to verify if needed anytime
//require("./sdks/MusicKit");

execute();

UIApplicationMain(0, null, null, null);
