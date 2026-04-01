var config = require("./config");
var manifest = require("./generated-manifest.json");
var test262ReporterInstalled = false;

function stringifyFailure(error) {
    if (!error) {
        return "Unknown Test262 failure";
    }

    if (typeof error === "string") {
        return error;
    }

    return error.stack || error.message || String(error);
}

function failSpec(done, error) {
    expect(stringifyFailure(error)).toBeUndefined();
    done();
}

function installTest262Reporter() {
    if (test262ReporterInstalled || !global.jasmine || typeof global.jasmine.getEnv !== "function") {
        return;
    }

    test262ReporterInstalled = true;

    var total = 0;
    var failed = 0;
    var skipped = 0;
    var suitePrefix = config.suiteName + " ";

    global.jasmine.getEnv().addReporter({
        specDone: function (spec) {
            if (!spec || typeof spec.fullName !== "string" || spec.fullName.indexOf(suitePrefix) !== 0) {
                return;
            }

            total++;

            if (spec.status === "failed") {
                failed++;
            } else if (spec.status === "pending") {
                skipped++;
            }
        },
        jasmineDone: function () {
            if (!total) {
                console.log("TEST262: 0 specs, 0 failures, 0 skipped, 0 passed.");
                return;
            }

            var passed = total - failed - skipped;
            console.log(
                "TEST262: " + total + " specs, " + failed + " failures, " + skipped + " skipped, " + passed + " passed."
            );
        }
    });
}

function runTest262Case(testCase, done) {
    var worker = new Worker("./tests/Test262/RunnerWorker.js");
    var timeout = null;
    var finished = false;

    function finalize(callback) {
        if (finished) {
            return;
        }

        finished = true;

        if (timeout !== null) {
            clearTimeout(timeout);
        }

        try {
            worker.terminate();
        } catch (e) {
        }

        callback();
    }

    timeout = setTimeout(function () {
        finalize(function () {
            failSpec(done, "Timed out after " + (testCase.timeoutMs || config.timeoutMs) + "ms");
        });
    }, testCase.timeoutMs || config.timeoutMs);

    worker.onerror = function (error) {
        finalize(function () {
            failSpec(done, error);
        });

        return true;
    };

    worker.onmessage = function (message) {
        var result = message.data || {};

        if (result.status === "passed") {
            finalize(function () {
                done();
            });
            return;
        }

        finalize(function () {
            failSpec(done, result.error || "Unknown Test262 failure");
        });
    };

    worker.postMessage({
        bundleSubmodulePath: config.bundleSubmodulePath,
        relativePath: testCase.relativePath,
        mode: testCase.mode,
        async: !!testCase.async,
        includes: testCase.includes || [],
        negative: testCase.negative || null
    });
}

if (!config.enabled) {
    module.exports = {};
    return;
}

installTest262Reporter();

describe(config.suiteName, function () {
    var originalTimeout;

    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = config.timeoutMs + 1000;
    });

    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    if (!manifest.tests || !manifest.tests.length) {
        it("has no generated manifest entries", function () {
            pending("Test262 manifest is empty: " + (manifest.reason || "unknown reason"));
        });
        return;
    }

    manifest.tests.forEach(function (testCase) {
        it(testCase.id, function (done) {
            runTest262Case(testCase, done);
        });
    });
});