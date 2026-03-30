function serializeError(error) {
    if (!error) {
        return "Unknown error";
    }

    if (typeof error === "string") {
        return error;
    }

    var parts = [];
    if (error.name) {
        parts.push(error.name);
    }
    if (error.message) {
        parts.push(error.message);
    }

    var summary = parts.join(": ");
    if (error.stack) {
        summary += "\n" + error.stack;
    }

    return summary || String(error);
}

function readTextFile(path) {
    var data = NSData.dataWithContentsOfFile(path);
    if (!data) {
        throw new Error("Unable to read file: " + path);
    }

    var text = NSString.alloc().initWithDataEncoding(data, NSUTF8StringEncoding);
    if (!text) {
        throw new Error("Unable to decode UTF-8 file: " + path);
    }

    return text.toString();
}

function withSourceURL(source, path) {
    return source + "\n//# sourceURL=" + path.replace(/\\/g, "/");
}

function evalGlobal(source, path) {
    var globalEval = (0, eval);
    return globalEval(withSourceURL(source, path));
}

function compileScript(source, path) {
    return Function(withSourceURL(source, path));
}

function importModule(specifier) {
    return Function("specifier", "return import(specifier);")(specifier);
}

function expectedErrorMatches(error, negative) {
    if (!negative || !negative.type) {
        return true;
    }

    if (!error) {
        return false;
    }

    if (error.name === negative.type || (error.constructor && error.constructor.name === negative.type)) {
        return true;
    }

    var errorText = "";
    if (error.message) {
        errorText += error.message;
    }
    if (error.stack) {
        errorText += "\n" + error.stack;
    }

    return errorText.indexOf(negative.type + ":") !== -1 || errorText.indexOf(negative.type) !== -1;
}

function makePrelude() {
    globalThis.$262 = {
        global: globalThis
    };

    globalThis.print = function () {
    };

    globalThis.reportCompare = function (expected, actual, message) {
        if (expected !== actual) {
            throw new Error(message || ("Expected " + expected + " but received " + actual));
        }
    };
}

function loadHarness(test262Root, includes) {
    includes.forEach(function (includeName) {
        var harnessPath = test262Root + "/harness/" + includeName;
        evalGlobal(readTextFile(harnessPath), harnessPath);
    });
}

function isModuleMode(payload) {
    return payload && payload.mode === "module";
}

function getTest262ModuleSpecifier(payload) {
    return "/tests/" + payload.bundleSubmodulePath + "/test/" + payload.relativePath;
}

function runModuleCase(payload, test262Root, completeWithPass, completeWithFailure) {
    globalThis.__test262ForceModule = true;
    globalThis.__test262ModuleRoot = test262Root + "/test";

    importModule(getTest262ModuleSpecifier(payload)).then(function () {
        if (payload.negative) {
            completeWithFailure(new Error("Expected module failure but evaluation succeeded"));
            return;
        }

        if (!payload.async) {
            completeWithPass();
        }
    }, function (error) {
        if (payload.negative && expectedErrorMatches(error, payload.negative)) {
            completeWithPass();
            return;
        }

        completeWithFailure(error);
    });
}

function postPass() {
    postMessage({ status: "passed" });
}

function postFailure(error) {
    postMessage({
        status: "failed",
        error: serializeError(error)
    });
}

function runCase(payload) {
    var settled = false;
    var test262Root = NSBundle.mainBundle.bundlePath + "/app/tests/" + payload.bundleSubmodulePath;
    var testPath = test262Root + "/test/" + payload.relativePath;
    var source = readTextFile(testPath);
    var wrappedSource = payload.mode === "strict" ? "\"use strict\";\n" + source : source;

    function completeWithPass() {
        if (settled) {
            return;
        }

        settled = true;
        postPass();
    }

    function completeWithFailure(error) {
        if (settled) {
            return;
        }

        settled = true;
        postFailure(error);
    }

    makePrelude();

    if (payload.async) {
        globalThis.$DONE = function (error) {
            if (error === undefined || error === null) {
                completeWithPass();
                return;
            }

            completeWithFailure(error);
        };
    }

    loadHarness(test262Root, payload.includes || []);

    if (isModuleMode(payload)) {
        runModuleCase(payload, test262Root, completeWithPass, completeWithFailure);
        return;
    }

    if (payload.negative && payload.negative.phase === "parse") {
        try {
            compileScript(wrappedSource, testPath);
        } catch (error) {
            if (expectedErrorMatches(error, payload.negative)) {
                completeWithPass();
                return;
            }

            completeWithFailure(error);
            return;
        }

        completeWithFailure(new Error("Expected parse failure but compilation succeeded"));
        return;
    }

    try {
        evalGlobal(wrappedSource, testPath);
    } catch (error) {
        if (payload.negative) {
            if (expectedErrorMatches(error, payload.negative)) {
                completeWithPass();
                return;
            }

            completeWithFailure(error);
            return;
        }

        completeWithFailure(error);
        return;
    }

    if (payload.negative) {
        completeWithFailure(new Error("Expected runtime failure but test completed successfully"));
        return;
    }

    if (!payload.async) {
        completeWithPass();
    }
}

onmessage = function (message) {
    try {
        runCase(message.data);
    } catch (error) {
        postFailure(error);
    }
};