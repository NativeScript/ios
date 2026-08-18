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
