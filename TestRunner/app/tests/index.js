// Inform the test results runner that the runtime is up.
console.log('Application Start!');

// The report delivery deadline (REPORT_DEADLINE_SECONDS) counts from launch.
var appStartMs = Date.now();

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
    // is lost the whole run times out. Retry hard, but stop early enough that a
    // final delivery_failed sentinel can still reach the host before its wait
    // budget (which also covers the suite itself) expires.
    var maxAttempts = 10;
    var retryDelayMs = 5000;
    var requestTimeoutS = 30;
    var deadlineSeconds = parseInt(NSProcessInfo.processInfo.environment.objectForKey("REPORT_DEADLINE_SECONDS"), 10) || 540;
    var deadlineMs = appStartMs + deadlineSeconds * 1000;

    var sessionConfig = NSURLSessionConfiguration.defaultSessionConfiguration;
    sessionConfig.timeoutIntervalForRequest = requestTimeoutS;
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

    // Best-effort sentinel so the host can fail immediately with a delivery
    // diagnostic instead of waiting out its full timeout.
    function sendDeliveryFailed(attempts, reason) {
        post(reportUrl + "/delivery_failed",
            "junit report delivery failed after " + attempts + " attempts; last failure " + reason,
            function () { });
    }

    function attemptReport(attempt) {
        post(reportUrl, text, function (reason) {
            console.log("junit report POST failed (attempt " + attempt + "/" + maxAttempts + ", " + reason + ")");
            if (attempt >= maxAttempts) {
                sendDeliveryFailed(attempt, reason);
                return;
            }
            setTimeout(function () {
                // Deadline is checked when the timer fires, not when it is
                // scheduled: under load timers run late, and a retry started
                // past this window would eat the sentinel's slot.
                var worstCaseRetryMs = 2 * requestTimeoutS * 1000;
                if (Date.now() + worstCaseRetryMs <= deadlineMs) {
                    attemptReport(attempt + 1);
                } else {
                    sendDeliveryFailed(attempt, reason);
                }
            }, retryDelayMs);
        });
    }

    // The first attempt intentionally has no deadline guard: even past the
    // deadline a one-shot report is still the most valuable outcome, and a
    // late fulfill is harmless to the host.
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

// Runtime builtins keep working when app code replaces the intrinsics they use
require("./PrimordialsTests");
require("./InspectTests");

// The ns:/node: builtin modules
require("./NsUtilTests");

// Tests common for all runtimes (git submodule of NativeScript/common-runtime-tests-app).
require("../shared/index").runAllTests();

// (Optional) Custom testing for various optional sdk's and frameworks
// These can be turned on manually to verify if needed anytime
//require("./sdks/MusicKit");

execute();

UIApplicationMain(0, null, null, null);
