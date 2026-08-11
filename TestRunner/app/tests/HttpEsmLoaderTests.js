// HTTP ESM Loader Tests
// Test the dev-only HTTP ESM loader functionality for fetching modules remotely

describe("HTTP ESM Loader", function() {

    function formatError(e) {
        try {
            if (!e) return "(no error)";
            if (e instanceof Error) return e.message;
            if (typeof e === "string") return e;
            if (e && typeof e.message === "string") return e.message;
            return JSON.stringify(e);
        } catch (_) {
            return String(e);
        }
    }

    function withTimeout(promise, ms, label) {
        return new Promise(function(resolve, reject) {
            var timer = setTimeout(function() {
                reject(new Error("Timeout after " + ms + "ms" + (label ? ": " + label : "")));
            }, ms);

            promise.then(function(value) {
                clearTimeout(timer);
                resolve(value);
            }).catch(function(err) {
                clearTimeout(timer);
                reject(err);
            });
        });
    }

    function getHostOrigin() {
        try {
            var reportUrl = NSProcessInfo.processInfo.environment.objectForKey("REPORT_BASEURL");
            if (!reportUrl) return null;
            var u = new URL(String(reportUrl));
            return u.origin;
        } catch (e) {
            return null;
        }
    }
    
    describe("URL Resolution", function() {
        it("should handle relative imports", function(done) {
            import("~/tests/esm/relative/entry.mjs").then(function(module) {
                expect(module.viaDefault).toBe("relative-import-success");
                expect(module.viaNamed).toBe("relative-import-success");
                expect(module.readDependencyPayload()).toBe(true);
                done();
            }).catch(function(error) {
                fail("Relative import module should resolve: " + error.message);
                done();
            });
        });
        it("should surface helpful errors for unresolved bare specifiers", function(done) {
            import("bare-spec-example").then(function(mod) {
                // Placeholder modules export a default Proxy. Accessing a property on that proxy
                // should throw with a helpful error message containing the specifier.
                let threw = false;
                try {
                    // Trigger the proxy's get trap by accessing a property on the default export
                    // eslint-disable-next-line no-unused-expressions
                    mod && mod.default && mod.default.__touch__;
                } catch (useErr) {
                    threw = true;
                    const msg = (useErr && useErr.message) ? useErr.message : String(useErr);
                    expect(msg).toContain("bare-spec-example");
                }
                expect(threw).toBe(true);
                done();
            }).catch(function(error) {
                // Other runtimes throw on import; assert message includes the specifier name.
                const message = (error && error.message) ? error.message : String(error);
                expect(message).toContain("bare-spec-example");
                done();
            });
        });
    });
    
    describe("HTTP Fetch Integration", function() {
        
        it("should attempt HTTP fetch for dev modules", function(done) {
            // Test by trying to import a module that would trigger HTTP fetch
            // We'll create a simple test module that the dev server should serve
            
            // Test importing a simple ES module from dev server
            const testModuleSpec = "~/tests/esm/hmr/test-esm-module.mjs";
            
            // Use dynamic import to trigger the HTTP ESM loader path
            import(testModuleSpec).then(function(module) {
                // If we get here, HTTP fetch + compilation worked
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                // Expected if dev server isn't running or module doesn't exist
                // The important thing is that it attempted the HTTP path
                console.log("HTTP ESM fetch failed as expected (no dev server or test module):", error.message);
                expect(error.message).toContain("Module"); // Should be a module resolution error, not a config error
                done();
            });
        });
        
        it("should fall back to filesystem when HTTP fetch fails", function(done) {
            // Import a simple local ESM module that exists in the bundle but not on dev server
            import("~/tests/esm/fs-fallback.mjs").then(function(module) {
                // Should succeed via filesystem fallback
                expect(module).toBeDefined();
                expect(module.ok || (module.default && module.default.ok)).toBe(true);
                done();
            }).catch(function(error) {
                // If this fails, it's likely the test module path is wrong
                fail("Filesystem fallback should have succeeded: " + error.message);
                done();
            });
        });
    });
    
    describe("Module Compilation", function() {
        
        it("should compile filesystem-backed ES modules successfully", function(done) {
            import("~/tests/esm/hmr/test-esm-module.mjs").then(function(module) {
                expect(module).toBeDefined();
                expect(module.testValue).toBe("http-esm-loaded");
                expect(typeof module.default).toBe("function");
                expect(module.default()).toContain("HTTP ESM loader working");
                done();
            }).catch(function(error) {
                fail("Expected module compilation to succeed: " + error.message);
                done();
            });
        });
        
        it("should reuse compiled modules across multiple dynamic imports", function(done) {
            const spec = "~/tests/esm/hmr/test-esm-module.mjs";
            Promise.all([import(spec), import(spec)]).then(function(results) {
                const first = results[0];
                const second = results[1];
                expect(first).toBeDefined();
                expect(second).toBeDefined();
                expect(first.timestamp).toBe(second.timestamp);
                done();
            }).catch(function(error) {
                fail("Expected module reuse to succeed: " + error.message);
                done();
            });
        });
    });
    
    describe("Error Handling", function() {
        
        it("should handle non-200 HTTP responses gracefully", function(done) {
            // Try to import a module that should return 404
            import("/nonexistent-module-404.js").then(function(module) {
                fail("Should not have succeeded for 404 module");
                done();
            }).catch(function(error) {
                // Should gracefully handle HTTP errors and provide meaningful error message
                expect(error.message).toBeDefined();
                console.log("404 handling test passed:", error.message);
                done();
            });
        });
        
        describe("network timeouts", function() {
            // The async loader's NSURLSession request timeout is 10s, so the
            // rejection lands ~10s after the import — beyond jasmine's default
            // 5s spec timeout. Jasmine 2.0 has no per-spec timeout argument;
            // widen the global interval for just this describe.
            var originalTimeout;
            beforeEach(function() {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = 15000;
            });
            afterEach(function() {
                jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            });

            it("should handle network timeouts", function(done) {
                // Prefer the local XCTest-hosted HTTP server (when available) to avoid ATS restrictions
                // and make this test deterministic.
                var origin = getHostOrigin();
                // Prefer the local XCTest server's delayed endpoint (deterministic, hermetic).
                // The fallback is a closed local port (fast connection-refused), never a live
                // external/TEST-NET host whose connect timeout would stall the JS thread on CI.
                // delayMs must exceed the async loader's 10s request timeout so the
                // fetch rejects (~10s) instead of completing late but successfully.
                var spec = origin ? (origin + "/esm/timeout.mjs?delayMs=12000") : "http://127.0.0.1:59999/timeout-test.js";

                import(spec).then(function(module) {
                    fail("Should not have succeeded for unreachable server");
                    done();
                }).catch(function(error) {
                    expect(error.message).toBeDefined();
                    console.log("Timeout handling test passed:", error.message);
                    done();
                });
            });
        });
        
        it("should handle malformed URLs gracefully", function() {
            // The loader must not throw *synchronously* for a malformed http specifier.
            // import("http://") returns a promise that rejects ("HTTP fetch/compile
            // failed"); swallow it so the discarded rejection isn't surfaced by the
            // unhandled-rejection tracker (that report is unrelated to what this asserts).
            expect(function() {
                import("http://").catch(function () {});
            }).not.toThrow();
        });
    });
    
    describe("Integration with HMR", function() {

        it("should NOT attach a native import.meta.hot (hot contexts are injected by the dev server)", function(done) {
            // The runtime owns no HMR policy: `import.meta.hot` is only present
            // when the @nativescript/vite dev server injects a JS hot context
            // into the served module source. Modules loaded outside a dev
            // session (like this fixture) must see no hot object at all.
            import("~/tests/esm/hmr/test-esm-module.mjs").then(function(module) {
                expect(module.getHotContext()).toBeUndefined();
                expect(module.callInvalidateSafe()).toBe(false);
                done();
            }).catch(function(error) {
                fail("Expected to inspect import.meta.hot absence: " + error.message);
                done();
            });
        });

        it("should expose the dev-loader primitives via the ns:module builtin", function() {
            // The dev surface is ONE builtin module — `ns:module` —
            // carrying the mechanism primitives; everything else (boot,
            // hot contexts, full reload, CSS, worker teardown) is
            // @nativescript/vite JS.
            var nsModule = require("ns:module");
            expect(Object.isFrozen(nsModule)).toBe(true);
            expect(typeof nsModule.configureLoader).toBe("function");
            expect(typeof nsModule.invalidateModules).toBe("function");
            expect(typeof nsModule.getLoadedModuleUrls).toBe("function");
            expect(typeof nsModule.setDevBootComplete).toBe("function");
            // Worker teardown is userland (the dev client intercepts the
            // Worker constructor); the runtime deliberately exposes no
            // terminateAllWorkers member.
            expect(nsModule.terminateAllWorkers).toBeUndefined();
        });

        it("resolves ns:module to the same members for require and import()", function(done) {
            var nsModule = require("ns:module");
            import("ns:module").then(function(ns) {
                expect(ns.default).toBe(nsModule);
                expect(ns.invalidateModules).toBe(nsModule.invalidateModules);
                expect(ns.configureLoader).toBe(nsModule.configureLoader);
                done();
            }).catch(function(error) {
                fail("import('ns:module') rejected: " + error.message);
                done();
            });
        });
    });

    describe("URL Key Canonicalization", function () {
        it("preserves query for non-dev/public URLs", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }

            var u1 = origin + "/esm/query.mjs?v=1";
            var u2 = origin + "/esm/query.mjs?v=2";

            withTimeout(import(u1), 5000, "import " + u1)
                .then(function (m1) {
                    return withTimeout(import(u2), 5000, "import " + u2).then(function (m2) {
                        expect(m1.query).toContain("v=1");
                        expect(m2.query).toContain("v=2");
                        expect(m1.query).not.toBe(m2.query);
                        done();
                    });
                })
                .catch(function (error) {
                    fail("Expected host HTTP module imports to succeed: " + formatError(error));
                    done();
                });
        });

        it("drops t/v/import for NativeScript dev endpoints", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }

            var u1 = origin + "/ns/m/query.mjs?v=1";
            var u2 = origin + "/ns/m/query.mjs?v=2";

            withTimeout(import(u1), 5000, "import " + u1)
                .then(function (m1) {
                    return withTimeout(import(u2), 5000, "import " + u2).then(function (m2) {
                        // With cache-buster normalization, both imports should map to the same cache key.
                        // The second import should reuse the first evaluated module.
                        expect(m2.evaluatedAt).toBe(m1.evaluatedAt);
                        expect(m2.query).toBe(m1.query);
                        done();
                    });
                })
                .catch(function (error) {
                    fail("Expected dev-endpoint HTTP module imports to succeed: " + formatError(error));
                    done();
                });
        });

        it("sorts query params for NativeScript dev endpoints", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }

            var u1 = origin + "/ns/m/query.mjs?b=2&a=1";
            var u2 = origin + "/ns/m/query.mjs?a=1&b=2";

            withTimeout(import(u1), 5000, "import " + u1)
                .then(function (m1) {
                    return withTimeout(import(u2), 5000, "import " + u2).then(function (m2) {
                        expect(m2.evaluatedAt).toBe(m1.evaluatedAt);
                        expect(m2.query).toBe(m1.query);
                        done();
                    });
                })
                .catch(function (error) {
                    fail("Expected dev-endpoint HTTP module imports to succeed: " + formatError(error));
                    done();
                });
        });

        it("ignores URL fragments for cache identity", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }

            var u1 = origin + "/esm/query.mjs#one";
            var u2 = origin + "/esm/query.mjs#two";

            withTimeout(import(u1), 5000, "import " + u1)
                .then(function (m1) {
                    return withTimeout(import(u2), 5000, "import " + u2).then(function (m2) {
                        expect(m2.evaluatedAt).toBe(m1.evaluatedAt);
                        done();
                    });
                })
                .catch(function (error) {
                    fail("Expected fragment HTTP module imports to succeed: " + formatError(error));
                    done();
                });
        });
    });
});

// Focused, deterministic coverage for the native HTTP canonical-key function.
// These run only in debug builds, where the ns:module builtin carries the
// `canonicalizeHttpUrlKey` diagnostic; in release the member is simply absent
// and they self-skip via pending(). They require no HTTP host — they pin pure
// string identity behavior.
describe("HTTP canonical key (ns:module canonicalizeHttpUrlKey)", function () {
    function getCanon() {
        return require("ns:module").canonicalizeHttpUrlKey;
    }

    function checkKey(input, expected) {
        var canon = getCanon();
        if (typeof canon !== "function") {
            pending("ns:module.canonicalizeHttpUrlKey not exposed (release build)");
            return;
        }
        expect(canon(input)).toBe(expected);
    }

    it("is exposed as a function in debug builds", function () {
        var canon = getCanon();
        if (typeof canon !== "function") {
            pending("ns:module.canonicalizeHttpUrlKey not exposed (release build)");
            return;
        }
        expect(typeof canon).toBe("function");
    });

    it("drops dev cache-busters (t/v/import) but keeps real query params", function () {
        checkKey("http://h/ns/core?p=x&t=123&v=9&import=1", "http://h/ns/core?p=x");
    });

    it("leaves public (non-dev, non-volatile) URLs untouched", function () {
        checkKey("https://cdn.example.com/lib.js?token=abc", "https://cdn.example.com/lib.js?token=abc");
    });

    it("treats module identity as literally the URL — no path-tag collapses", function () {
        // There is no path-tag vocabulary and no versioned /ns/rt|core
        // collapsing: the server emits exactly one canonical URL per module
        // and freshness is handled by eviction + the eviction-driven fetch
        // nonce, never by URL variation.
        checkKey("http://h/ns/m/foo.js", "http://h/ns/m/foo.js");
        checkKey("http://h/ns/rt", "http://h/ns/rt");
        checkKey("http://h/ns/core", "http://h/ns/core");
    });

    it("ignores URL fragments for dev endpoints", function () {
        checkKey("http://h/ns/m/foo.js#frag", "http://h/ns/m/foo.js");
    });

    it("honors a client-supplied canonicalization vocabulary via configureLoader", function () {
        var canon = getCanon();
        if (typeof canon !== "function") {
            pending("ns:module.canonicalizeHttpUrlKey not exposed (release build)");
            return;
        }
        // The vocabulary below matches the built-in fallback exactly, so this
        // spec exercises the configured code path without changing the
        // process-wide canonicalization behavior other specs rely on.
        require("ns:module").configureLoader({
            canonicalization: {
                stripParams: ["t", "v", "import"],
                forPathPrefixes: ["/ns/", "/node_modules/.vite/", "/@id/", "/@fs/"],
                preserveQueryFor: ["/@ng/component"],
            },
        });
        // Dev endpoint: configured cache-busters stripped, real params kept.
        expect(canon("http://h/ns/core?p=x&t=123&v=9&import=1")).toBe("http://h/ns/core?p=x");
        // preserveQueryFor wins even under a dev-endpoint prefix.
        expect(canon("http://h/ns/m/comp/@ng/component?c=a&t=42")).toBe("http://h/ns/m/comp/@ng/component?c=a&t=42");
        // Non-dev URLs keep their query verbatim.
        expect(canon("https://cdn.example.com/lib.js?token=abc")).toBe("https://cdn.example.com/lib.js?token=abc");
    });
});

console.log("HTTP ESM Loader tests loaded");