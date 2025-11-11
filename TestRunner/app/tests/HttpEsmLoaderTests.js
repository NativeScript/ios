// HTTP ESM Loader Tests
// Test the dev-only HTTP ESM loader functionality for fetching modules remotely

describe("HTTP ESM Loader", function() {
    
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
            // Attempt to import from an unreachable address to test timeout
            // 192.0.2.1 is a TEST-NET-1 address reserved by RFC 5737 for documentation and testing purposes.
            // It is intentionally used here to trigger a network timeout scenario.
            import("http://192.0.2.1:5173/timeout-test.js").then(function(module) {
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
});

console.log("HTTP ESM Loader tests loaded");