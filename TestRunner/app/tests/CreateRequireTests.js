// `ns:module`'s createRequire / createPumpingRequire and the `node:module`
// shim that re-exports the first of them. The two flavors differ only in how
// an ES module graph is evaluated: strict refuses top-level await (Node's
// require(esm) rule), pumping drives the loop until the graph settles.
describe("createRequire", function () {
    var nsModule = require("ns:module");
    var fixtureDir = __dirname + "/esm/createrequire";

    function messageOf(fn) {
        try {
            fn();
        } catch (e) {
            return String((e && e.message) || e);
        }
        return "<no error thrown>";
    }

    describe("surface", function () {
        it("ns:module exposes both require factories", function () {
            expect(typeof nsModule.createRequire).toBe("function");
            expect(typeof nsModule.createPumpingRequire).toBe("function");
        });

        it("node:module re-exports createRequire and nothing else", function () {
            var nodeModule = require("node:module");
            expect(Object.isFrozen(nodeModule)).toBe(true);
            expect(Object.keys(nodeModule)).toEqual(["createRequire"]);
            // The pumping flavor is a NativeScript extension with no Node
            // counterpart, so it stays off the node: surface.
            expect(nodeModule.createPumpingRequire).toBeUndefined();
        });

        it("node:module is a distinct module object from ns:module", function () {
            expect(require("node:module")).not.toBe(require("ns:module"));
        });

        it("exposes createRequire through a static import of node:module", function (done) {
            import("~/tests/esm/createrequire/node-module-import.mjs").then(function (ns) {
                expect(ns.createRequireType).toBe("function");
                var target = ns.requireFrom(fixtureDir + "/anything.js", "./target.js");
                expect(target.tag).toBe("createrequire-target");
                done();
            }).catch(function (e) {
                expect("rejected: " + e).toBe("resolved");
                done();
            });
        });
    });

    describe("base resolution", function () {
        it("resolves ./ against the directory of the given file", function () {
            var req = nsModule.createRequire(fixtureDir + "/anything.js");
            expect(req("./target.js").tag).toBe("createrequire-target");
        });

        it("treats a trailing slash as the directory itself", function () {
            var req = nsModule.createRequire(fixtureDir + "/");
            expect(req("./target.js").tag).toBe("createrequire-target");
        });

        it("accepts a file URL string", function () {
            var req = nsModule.createRequire("file://" + fixtureDir + "/anything.js");
            expect(req("./target.js").tag).toBe("createrequire-target");
        });

        it("accepts a URL object", function () {
            var req = nsModule.createRequire(new URL("file://" + fixtureDir + "/anything.js"));
            expect(req("./target.js").tag).toBe("createrequire-target");
        });

        it("still resolves ~ specifiers against the app root", function () {
            var req = nsModule.createRequire(fixtureDir + "/anything.js");
            expect(req("~/tests/esm/createrequire/target.js").tag).toBe("createrequire-target");
        });
    });

    describe("argument validation", function () {
        it("rejects a non-string, non-URL argument", function () {
            expect(messageOf(function () { nsModule.createRequire(42); }))
                .toContain("must be a file URL object, file URL string, or absolute path string");
        });

        it("rejects a relative path string", function () {
            expect(messageOf(function () { nsModule.createRequire("./tests/index.js"); }))
                .toContain("must be a file URL object, file URL string, or absolute path string");
        });

        it("rejects a non-file URL scheme", function () {
            expect(messageOf(function () { nsModule.createRequire("ftp://example.com/a.js"); }))
                .toContain("must be a file URL object, file URL string, or absolute path string");
        });

        it("refuses an http base with a dev-server specific message", function () {
            var message = messageOf(function () {
                nsModule.createRequire("http://localhost:8080/main.js");
            });
            expect(message).toContain("http(s) URL");
            expect(message).toContain("import()");
        });

        it("applies the same validation to createPumpingRequire", function () {
            expect(messageOf(function () { nsModule.createPumpingRequire(42); }))
                .toContain("must be a file URL object, file URL string, or absolute path string");
        });
    });

    describe("evaluation policy", function () {
        it("refuses a top-level-await graph strictly", function () {
            var strictRequire = nsModule.createRequire(fixtureDir + "/anything.js");

            var refusal = messageOf(function () { strictRequire("./microtask-tla.mjs"); });
            expect(refusal).toContain("top-level await");
            expect(refusal).toContain("createPumpingRequire");
        });

        it("evaluates the same graph when pumping", function (done) {
            // Hop to a fresh task first: Jasmine may deliver this spec from the
            // previous spec's promise continuation, and the pump cannot drain
            // microtasks while the isolate is already inside a microtask turn.
            __ns__setTimeout(function () {
                var pumpingRequire = nsModule.createPumpingRequire(fixtureDir + "/anything.js");
                var result = "";
                try {
                    result = String(pumpingRequire("./microtask-tla.mjs").value);
                } catch (e) {
                    result = "threw: " + ((e && e.message) || e);
                }
                expect(result).toBe("ok");
                done();
            }, 0);
        });

        it("refuses to pump a top-level-await graph from inside a microtask", function (done) {
            var pumpingRequire = nsModule.createPumpingRequire(fixtureDir + "/anything.js");
            Promise.resolve().then(function () {
                expect(messageOf(function () {
                    pumpingRequire("./microtask-tla-guarded.mjs");
                })).toContain("cannot be pumped re-entrantly");
                done();
            });
        });

        it("still loads a synchronous graph from inside a microtask", function (done) {
            var pumpingRequire = nsModule.createPumpingRequire(fixtureDir + "/anything.js");
            Promise.resolve().then(function () {
                expect(pumpingRequire("./target.js").tag).toBe("createrequire-target");
                done();
            });
        });

        describe("pumping options", function () {
            it("rejects a non-object options bag", function () {
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", 42);
                }).toThrowError(TypeError, /options must be an object/);
            });

            it("rejects an unknown option key by name", function () {
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", { deadline: 1 });
                }).toThrowError(TypeError, /unknown option 'deadline'/);
            });

            it("rejects bad option values", function () {
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", { deadlineSeconds: 0 });
                }).toThrowError(TypeError, /positive finite number/);
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", { deadlineSeconds: Infinity });
                }).toThrowError(TypeError, /positive finite number/);
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", { onTimeout: "wait" });
                }).toThrowError(TypeError, /'throw' or 'return-pending'/);
                expect(function () {
                    nsModule.createPumpingRequire(fixtureDir + "/x.js", { pumpRunLoop: "yes" });
                }).toThrowError(TypeError, /must be a boolean/);
            });

            it("refuses options on the strict createRequire", function () {
                expect(function () {
                    nsModule.createRequire(fixtureDir + "/x.js", { deadlineSeconds: 1 });
                }).toThrowError(TypeError, /options are not supported on createRequire/);
            });

            // These reach the deadline, so they must run from a task context —
            // from a microtask the guard would refuse before evaluating.
            it("returns without throwing at the deadline under onTimeout return-pending",
               function (done) {
                __ns__setTimeout(function () {
                    // The graph parks on a non-nestable foreground task, so the
                    // pump can never settle it and the deadline is reached.
                    var req = nsModule.createPumpingRequire(fixtureDir + "/anything.js", {
                        deadlineSeconds: 0.25,
                        onTimeout: "return-pending",
                    });
                    var outcome = "<returned nothing>";
                    try {
                        var mod = req("./tla-return-pending.mjs");
                        outcome = typeof mod === "object" ? "returned a namespace"
                                                          : "returned " + typeof mod;
                    } catch (e) {
                        outcome = "threw: " + ((e && e.message) || e);
                    }
                    expect(outcome).toBe("returned a namespace");
                    done();
                }, 0);
            });

            it("honors a short deadlineSeconds with the default onTimeout throw", function (done) {
                __ns__setTimeout(function () {
                    var req = nsModule.createPumpingRequire(fixtureDir + "/anything.js", {
                        deadlineSeconds: 0.25,
                    });
                    var started = Date.now();
                    expect(messageOf(function () { req("./tla-deadline.mjs"); }))
                        .toContain("Top-level await timed out");
                    // The configured deadline governed, not the 60s default.
                    expect(Date.now() - started < 5000 ? "within the short deadline"
                                                       : "took too long")
                        .toBe("within the short deadline");
                    done();
                }, 0);
            });

            it("keeps the microtask guard unconditional even with pumpRunLoop", function (done) {
                var req = nsModule.createPumpingRequire(fixtureDir + "/anything.js", {
                    pumpRunLoop: true,
                });
                Promise.resolve().then(function () {
                    expect(messageOf(function () { req("./microtask-tla-guarded.mjs"); }))
                        .toContain("cannot be pumped re-entrantly");
                    done();
                });
            });
        });

        it("refuses a foreground-task top-level await through createRequire", function () {
            var req = nsModule.createRequire(__dirname + "/anything.js");
            expect(messageOf(function () { req("./esm/tla-foreground-task.mjs"); }))
                .toContain("top-level await");
        });
    });
});

// `~` marks the app root; the separator after it is optional.
describe("app-root specifiers", function () {
    it("resolves ~/path", function () {
        expect(require("~/tests/esm/createrequire/target.js").tag).toBe("createrequire-target");
    });

    it("resolves ~path without a separator", function () {
        expect(require("~tests/esm/createrequire/target.js").tag).toBe("createrequire-target");
    });
});
