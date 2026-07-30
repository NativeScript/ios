// Inform the test results runner that the runtime is up.
console.log('Application Start!');

require("../Infrastructure/timers");
require("../Infrastructure/simulator");
global.utf8 = require("../Infrastructure/utf8")

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
    if (!reportUrl) {
        return;
    }

    // The results host (TestRunnerTests.swift) waits on this single POST; if it
    // is lost the whole run times out. Retry hard, and cap the per-request
    // timeout so all attempts fit well inside the host's wait budget.
    var maxAttempts = 10;
    var retryDelayMs = 5000;

    var sessionConfig = NSURLSessionConfiguration.defaultSessionConfiguration;
    sessionConfig.timeoutIntervalForRequest = 30;
    var session = NSURLSession.sessionWithConfigurationDelegateDelegateQueue(sessionConfig, null, NSOperationQueue.mainQueue);

    function post(url, body, onFailure) {
        var urlRequest = NSMutableURLRequest.requestWithURL(NSURL.URLWithString(url));
        urlRequest.HTTPMethod = "POST";
        urlRequest.setValueForHTTPHeaderField("Content-Type", "application/xml");
        urlRequest.HTTPBody = NSString.stringWithString(body).dataUsingEncoding(4);
        var dataTask = session.dataTaskWithRequestCompletionHandler(urlRequest, (data, response, error) => {
            if (error) {
                onFailure("error: " + error.localizedDescription);
            } else if (!response || response.statusCode < 200 || response.statusCode >= 300) {
                onFailure("status: " + (response ? response.statusCode : "none"));
            }
        });
        dataTask.resume();
    }

    function attemptReport(attempt) {
        post(reportUrl, text, function (reason) {
            console.log("junit report POST failed (attempt " + attempt + "/" + maxAttempts + ", " + reason + ")");
            if (attempt < maxAttempts) {
                setTimeout(function () {
                    attemptReport(attempt + 1);
                }, retryDelayMs);
            } else {
                // Best-effort sentinel so the host can fail immediately with a
                // delivery diagnostic instead of waiting out its full timeout.
                post(reportUrl + "/delivery_failed",
                    "junit report delivery failed after " + maxAttempts + " attempts; last failure " + reason,
                    function () { });
            }
        });
    }

    attemptReport(1);
};

global.__approot = NSString.stringWithString(NSBundle.mainBundle.bundlePath).stringByResolvingSymlinksInPath;

require("../Infrastructure/Jasmine/jasmine-2.0.1/boot");

require("./Marshalling/Primitives/Function");
require("./Marshalling/Primitives/Static");
require("./Marshalling/Primitives/Instance");
require("./Marshalling/Primitives/Derived");
//
require("./Marshalling/ObjCTypesTests");
require("./Marshalling/ConstantsTests");
require("./Marshalling/RecordTests");
require("./Marshalling/VectorTests");
require("./Marshalling/MatrixTests");
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
require("./GCFinalizerTests");
require("./DeclarationConflicts");
//
require("./Promises");
require("./Modules");
//
require("./RuntimeImplementedAPIs");

require("./Timers");

require("./URL");
require("./URLSearchParams");
require("./URLPattern");

// HTTP ESM Loader tests
require("./HttpEsmLoaderTests");

// Remote Module Security tests
require("./RemoteModuleSecurityTests");

// Node built-in and optional module resolution tests (ESM)
require("./NodeBuiltinsAndOptionalModulesTests.mjs");

// Exception handling tests
require("./ExceptionHandlingTests");

// WHATWG error events (error/unhandledrejection/rejectionhandled, reportError)
require("./ErrorEventsTests");

// interop.escapeException + JS<->native boundary hardening (Phase 3)
require("./EscapeExceptionTests");

// Tests common for all runtimes (git submodule of NativeScript/common-runtime-tests-app).
require("../shared/index").runAllTests();

// (Optional) Custom testing for various optional sdk's and frameworks
// These can be turned on manually to verify if needed anytime
//require("./sdks/MusicKit");

execute();

UIApplicationMain(0, null, null, null);
