// Boots jasmine-core for the TestRunner app. The "Stage Test Runner Dependencies"
// build phase copies jasmine-core from the repo's node_modules into ./vendor.
var jasmineCore = require("./vendor/jasmine-core/jasmine");
var JUnitXmlReporter = require("./jasmine-reporters/junit_reporter").JUnitXmlReporter;
var TerminalReporter = require("./jasmine-reporters/terminal_reporter").TerminalReporter;

jasmineCore.installGlobals(global);

var env = jasmine.getEnv();

// Quarantined specs — skipped at the harness level (no submodule edit), matched
// by substring against the spec's full name. See TestRunnerTests/QUARANTINED_TESTS.md
// for the rationale and how to re-enable each entry.
var QUARANTINED_SPEC_SUBSTRINGS = [];

env.configure({
    // Suites carry state from one spec to the next (the shared Workers suite
    // counts live runtimes across its specs), so they run in declaration order.
    random: false,
    specFilter: function (spec) {
        var fullName = spec.getFullName();
        for (var i = 0; i < QUARANTINED_SPEC_SUBSTRINGS.length; i++) {
            if (fullName.indexOf(QUARANTINED_SPEC_SUBSTRINGS[i]) !== -1) {
                return false;
            }
        }
        return true;
    }
});

// jasmine-core's pretty-printer falls back to value.toString() for tagged objects
// it does not recognize, which throws for null-prototype ones such as module
// namespaces. toBe() builds its message even when it passes, so without this an
// expect(namespace).toBe(sameNamespace) throws.
beforeEach(function () {
    jasmine.addCustomObjectFormatter(function (value) {
        if (value !== null && typeof value === "object" && typeof value.toString !== "function") {
            var tag = Object.prototype.toString.call(value);
            if (tag !== "[object Object]") {
                return tag;
            }
        }
        return undefined;
    });
});

env.addReporter(new TerminalReporter({
    verbosity: 2
}));
env.addReporter(new JUnitXmlReporter());

// Progress beacon: fire-and-forget GET of each SUITE name to the XCTest host's
// /progress endpoint. When the run hangs (no JUnit report is ever POSTed), this
// lets the Swift harness name the suite that was running when the JS thread
// stalled. Async via NSURLSession so it never blocks the JS thread; best-effort.
//
// SUITE-level only (not specStarted): a per-spec beacon opens hundreds of
// connections per run, more than CI's tighter fd limits allow the test server,
// while suites number in the dozens and still pinpoint a hang to its suite.
(function installProgressBeacon() {
    try {
        var reportUrl = NSProcessInfo.processInfo.environment.objectForKey("REPORT_BASEURL");
        if (!reportUrl) { return; }
        var origin = new URL(String(reportUrl)).origin;
        var beacon = function (name) {
            try {
                var url = origin + "/progress?spec=" + encodeURIComponent(name || "");
                var req = NSMutableURLRequest.requestWithURL(NSURL.URLWithString(url));
                req.HTTPMethod = "GET";
                req.timeoutInterval = 2.0;
                NSURLSession.sharedSession.dataTaskWithRequestCompletionHandler(req, function () {}).resume();
            } catch (e) { /* best-effort */ }
        };
        env.addReporter({
            suiteStarted: function (r) { beacon("[suite] " + (r && r.fullName ? r.fullName : "")); }
        });
    } catch (e) { /* best-effort */ }
}());

exports.execute = function () {
    env.execute().catch(function (e) {
        // No JUnit report follows; the XCTest host reports the run as hung.
        console.log("Jasmine could not run the suite: " + ((e && e.stack) || e));
    });
};
