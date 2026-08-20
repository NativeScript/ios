// Regression specs for the loader defects catalogued in NativeScript/ios#443,
// found by the Android parity port's function-by-function review. Each spec
// pins one behaviour that was wrong, in the terms an app can observe.
describe("loader hardening", function () {
    var fixtures = __dirname + "/loaderhardening";

    function messageOf(fn) {
        try {
            fn();
        } catch (e) {
            return String((e && e.message) || e);
        }
        return "<no error thrown>";
    }

    // The CommonJS cache was keyed by the specifier with its extension removed,
    // so two files differing only by extension shared one entry and whichever
    // loaded first answered for both.
    describe("CommonJS cache key", function () {
        it("keeps modules whose specifiers differ only by extension apart", function () {
            var req = require("ns:module").createRequire(fixtures + "/");
            var js = req("./config.js");
            var json = req("./config.json");

            expect(js.from).toBe("js");
            expect(json.from).toBe("json");
        });

        it("still returns one module for two spellings of the same file", function () {
            var req = require("ns:module").createRequire(fixtures + "/");
            // './config' resolves to config.js, so both must be the same object:
            // deduplication moved to the resolved path, it did not disappear.
            expect(req("./config")).toBe(req("./config.js"));
        });
    });

    // require() used to catch the module's error and throw a fresh generic
    // Error carrying the original only as text, so the class and any property
    // the caller matched on were destroyed.
    describe("require failure identity", function () {
        it("rethrows the module's own error unchanged", function () {
            var req = require("ns:module").createRequire(fixtures + "/");
            var caught = null;
            try {
                req("./throwsTyped.js");
            } catch (e) {
                caught = e;
            }

            expect(caught).not.toBe(null);
            expect(caught instanceof TypeError).toBe(true);
            expect(caught.message).toBe("typed-module-failure");
            // A property the module set survives, which is what "identity" buys.
            expect(caught.marker).toBe("original-identity");
        });
    });

    // A query or fragment is URL syntax. import() already stripped it; a static
    // import from a local referrer did not, and probed for a file whose name
    // literally contained the query.
    describe("query-suffixed specifiers", function () {
        it("resolves a static import that carries a cache-busting query", function (done) {
            import("~/tests/loaderhardening/queryImporter.mjs").then(function (mod) {
                expect(mod.value).toBe("query-leaf");
                done();
            }).catch(function (e) {
                expect("rejected: " + String((e && e.message) || e)).toBe("resolved");
                done();
            });
        });

        it("resolves a dynamic import that carries one too", function (done) {
            import("~/tests/loaderhardening/queryLeaf.mjs?v=2").then(function (mod) {
                expect(mod.leaf).toBe("query-leaf");
                done();
            }).catch(function (e) {
                expect("rejected: " + String((e && e.message) || e)).toBe("resolved");
                done();
            });
        });
    });

    // Resolving a dynamic import reads `then` off the module namespace. In a
    // cycle that export can still be in its temporal dead zone, so the read
    // throws — and the runtime asserted on the failure, aborting the process
    // from ordinary user code.
    describe("namespace resolution in a cycle", function () {
        it("settles instead of aborting when the namespace has a TDZ 'then'", function (done) {
            import("~/tests/loaderhardening/tdzThenB.mjs").then(function (mod) {
                return mod.pending;
            }).then(function (outcome) {
                // Either outcome is acceptable — the point is that the process
                // survived to report one, and that a rejection carries a real
                // Error rather than an abort.
                expect(typeof outcome).toBe("string");
                expect(outcome.indexOf("resolved:") === 0 || outcome.indexOf("rejected:") === 0)
                    .toBe(true);
                done();
            }).catch(function (e) {
                // A rejection here is also a pass: it means the failure was
                // reported rather than asserted on.
                expect(e instanceof Error).toBe(true);
                done();
            });
        });
    });

    // configureLoader's deadline is validated in ns-module.js; the native
    // binding re-validates so the boundary holds on its own.
    describe("pumping deadline", function () {
        it("rejects a non-finite deadline", function () {
            var nsModule = require("ns:module");
            expect(messageOf(function () {
                nsModule.createPumpingRequire(fixtures + "/", { deadlineSeconds: NaN });
            })).toContain("positive finite number");
            expect(messageOf(function () {
                nsModule.createPumpingRequire(fixtures + "/", { deadlineSeconds: Infinity });
            })).toContain("positive finite number");
        });
    });
});

console.log("Loader hardening tests loaded");
