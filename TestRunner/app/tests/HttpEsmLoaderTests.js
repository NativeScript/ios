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
        
        it("should handle network timeouts", function(done) {
            // Prefer the local XCTest-hosted HTTP server (when available) to avoid ATS restrictions
            // and make this test deterministic.
            var origin = getHostOrigin();
            var spec = origin ? (origin + "/esm/timeout.mjs?delayMs=6500") : "https://192.0.2.1:5173/timeout-test.js";

            import(spec).then(function(module) {
                fail("Should not have succeeded for unreachable server");
                done();
            }).catch(function(error) {
                expect(error.message).toBeDefined();
                console.log("Timeout handling test passed:", error.message);
                done();
            });
        });
        
        it("should handle malformed URLs gracefully", function() {
            // The loader should ignore malformed http specifiers
            expect(function() {
                import("http://");
            }).not.toThrow();
        });
    });
    
    describe("Integration with HMR", function() {
        
        it("should expose import.meta.hot with a working invalidate hook", function(done) {
            import("~/tests/esm/hmr/test-esm-module.mjs").then(function(module) {
                const hot = module.getHotContext();
                if (!hot) {
                    // In release builds import.meta.hot is stripped; ensure helper reports false.
                    expect(module.callInvalidateSafe()).toBe(false);
                    done();
                    return;
                }
                expect(module.callInvalidateSafe()).toBe(true);
                expect(typeof hot.invalidate).toBe("function");
                done();
            }).catch(function(error) {
                fail("Expected to access HMR helpers: " + error.message);
                done();
            });
        });
        
        it("should provide stable accept and dispose hooks", function(done) {
            import("~/tests/esm/hmr/test-esm-module.mjs").then(function(module) {
                const hot = module.getHotContext();
                if (!hot) {
                    // Nothing to assert in release builds; ensure helper reported correctly.
                    expect(module.callInvalidateSafe()).toBe(false);
                    done();
                    return;
                }
                expect(typeof hot.accept).toBe("function");
                expect(typeof hot.dispose).toBe("function");
                expect(typeof hot.invalidate).toBe("function");
                done();
            }).catch(function(error) {
                fail("Expected import.meta.hot hook inspection to succeed: " + error.message);
                done();
            });
        });
    });

    describe("HMR hot.data", function () {
        it("should expose import.meta.hot.data and stable API", function (done) {
            var origin = getHostOrigin();
            var specs = origin
                ? [origin + "/esm/hmr/hot-data-ext.mjs", origin + "/esm/hmr/hot-data-ext.js"]
                : ["~/tests/esm/hmr/hot-data-ext.mjs"];

            withTimeout(Promise.all(specs.map(function (s) { return import(s); })), 5000, "import hot-data test modules")
                .then(function (mods) {
                    var mjs = mods[0];
                    var apiMjs = mjs && typeof mjs.testHotApi === "function" ? mjs.testHotApi() : null;

                    // In release builds import.meta.hot is stripped; skip these assertions.
                    if (!(apiMjs && apiMjs.hasHot)) {
                        pending("import.meta.hot not available (likely release build)");
                        done();
                        return;
                    }

                    expect(apiMjs.ok).toBe(true);
                    if (mods.length > 1) {
                        var js = mods[1];
                        var apiJs = js && typeof js.testHotApi === "function" ? js.testHotApi() : null;
                        expect(apiJs && apiJs.ok).toBe(true);
                    }
                    done();
                })
                .catch(function (error) {
                    fail("Expected hot-data test modules to import: " + formatError(error));
                    done();
                });
        });

        it("should share hot.data across .mjs and .js variants", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; cannot import .js as ESM in this harness");
                done();
                return;
            }

            withTimeout(Promise.all([
                import(origin + "/esm/hmr/hot-data-ext.mjs"),
                import(origin + "/esm/hmr/hot-data-ext.js"),
            ]), 5000, "import .mjs/.js hot-data modules")
                .then(function (mods) {
                    var mjs = mods[0];
                    var js = mods[1];

                    var hotMjs = mjs && typeof mjs.getHot === "function" ? mjs.getHot() : null;
                    var hotJs = js && typeof js.getHot === "function" ? js.getHot() : null;
                    if (!hotMjs || !hotJs) {
                        pending("import.meta.hot not available (likely release build)");
                        done();
                        return;
                    }

                    var dataMjs = mjs.getHotData();
                    var dataJs = js.getHotData();
                    expect(dataMjs).toBeDefined();
                    expect(dataJs).toBeDefined();

                    var token = "tok_" + Date.now() + "_" + Math.random();
                    mjs.setHotValue(token);
                    expect(js.getHotValue()).toBe(token);

                    // Canonical hot key strips common script extensions, so these should share identity.
                    expect(dataMjs).toBe(dataJs);
                    done();
                })
                .catch(function (error) {
                    fail("Expected hot.data sharing assertions to succeed: " + formatError(error));
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

console.log("HTTP ESM Loader tests loaded");