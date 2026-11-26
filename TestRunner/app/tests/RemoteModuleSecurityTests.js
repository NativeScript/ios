// Remote Module Security Tests
// Tests for the security gating of HTTP(S) ES module loading
//
// Security configuration is read from package.json under the "security" key:
// {
//   "security": {
//     "allowRemoteModules": true,          // Enable remote module loading in production
//     "remoteModuleAllowlist": [           // Optional: restrict to specific URL prefixes
//       "https://cdn.example.com/modules/",
//       "https://esm.sh/"
//     ]
//   }
// }
//
// Behavior:
// - Debug mode (RuntimeConfig.IsDebug = true): Remote modules always allowed
// - Production mode: Requires security.allowRemoteModules = true
// - With allowlist: Only URLs matching a prefix in remoteModuleAllowlist are allowed

describe("Remote Module Security", function() {

    // Hermetic by design: never touch live external hosts (esm.sh, TEST-NET
    // 192.0.2.1, example.com). HTTP module fetches are SYNCHRONOUS on the JS
    // thread (HttpLoader.mm: NSURLConnection sendSynchronousRequest), so a slow
    // or transitively-fanning remote import (e.g. esm.sh pulling a graph of
    // sub-modules) blocks the event loop and, accumulated, runs the whole suite
    // past its timeout on CI -> false "hang". A closed local port fails fast
    // with a connection-refused *network* error, which is exactly what every
    // debug-mode spec below asserts: the security gate lets the request through
    // (so it's NOT a security error) and the fetch then fails on the network.
    var DEAD_HTTP = "http://127.0.0.1:59999";
    var DEAD_HTTPS = "https://127.0.0.1:59999";

    describe("Debug Mode Behavior", function() {
        // In debug mode (test environment), all remote modules should be allowed
        // regardless of security configuration
        
        it("should allow HTTP module imports in debug mode", function(done) {
            // Uses a closed local port to trigger the HTTP loading path and fail
            // fast. In debug mode the security check passes and we get a network
            // error (connection refused), NOT a security error.
            import(DEAD_HTTP + "/test-module.js").then(function(module) {
                // If we somehow succeed, that's fine too
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                // Should fail with a network/timeout error, NOT a security error
                const message = error.message || String(error);
                // In debug mode, we should NOT see security-related error messages
                expect(message).not.toContain("not allowed in production");
                expect(message).not.toContain("remoteModuleAllowlist");
                done();
            });
        });
        
        it("should allow HTTPS module imports in debug mode", function(done) {
            // Test HTTPS URL - should be allowed in debug mode (closed local port -> fast network error)
            import(DEAD_HTTPS + "/test-module.js").then(function(module) {
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                const message = error.message || String(error);
                // Should NOT be a security error in debug mode
                expect(message).not.toContain("not allowed in production");
                expect(message).not.toContain("remoteModuleAllowlist");
                done();
            });
        });
    });
    
    describe("Security Configuration", function() {
        // These tests verify that the security configuration from package.json
        // is being read correctly. Since we're in debug mode, we can't test
        // the blocking behavior directly, but we can verify the config is parsed.
        
        it("should have security configuration in package.json", function() {
            // Verify the app package.json includes security config
            // This is a sanity check that our test setup is correct
            // The actual security object is read by the native runtime
            
            // We can't directly access the parsed config from JS in debug mode,
            // but we can verify the package.json file structure
            const fs = NSFileManager.defaultManager;
            const packagePath = NSBundle.mainBundle.resourcePath + "/app/package.json";
            
            const exists = fs.fileExistsAtPath(packagePath);
            expect(exists).toBe(true);
            
            if (exists) {
                const data = NSData.dataWithContentsOfFile(packagePath);
                if (data) {
                    const jsonString = NSString.alloc().initWithDataEncoding(data, NSUTF8StringEncoding);
                    const config = JSON.parse(jsonString.toString());
                    
                    // Verify security config structure
                    expect(config.security).toBeDefined();
                    expect(typeof config.security.allowRemoteModules).toBe("boolean");
                    expect(Array.isArray(config.security.remoteModuleAllowlist)).toBe(true);
                }
            }
        });
    });
    
    describe("URL Allowlist Matching", function() {
        // These tests verify URL prefix matching behavior
        // In debug mode, all URLs are allowed, but we can test that the
        // code paths for HTTP loading are exercised correctly
        
        it("should handle allowlisted URL prefixes", function(done) {
            // In debug mode the allowlist is not enforced; this just exercises the
            // remote-load path and confirms we get a network (not security) error.
            import(DEAD_HTTPS + "/test-module").then(function(module) {
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                // Network errors are expected, security errors are not
                const message = error.message || String(error);
                expect(message).not.toContain("not allowed in production");
                done();
            });
        });
        
        it("should handle non-allowlisted URLs in debug mode", function(done) {
            // This URL is NOT in the allowlist, but debug mode allows it anyway
            import(DEAD_HTTPS + "/not-allowlisted/module.js").then(function(module) {
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                // In debug mode, should NOT get a security error
                const message = error.message || String(error);
                expect(message).not.toContain("not allowed in production");
                expect(message).not.toContain("remoteModuleAllowlist");
                done();
            });
        });
    });
    
    describe("Static Import Security", function() {
        // Test that static imports also respect security settings
        // We can't easily test blocked behavior in debug mode, but we can
        // verify the code paths work
        
        it("should allow importing from allowlisted static HTTP URLs", function(done) {
            // This test verifies the ResolveModuleCallback security check path
            // is exercised for static imports
            const testUrl = DEAD_HTTPS + "/@test/module";
            
            import(testUrl).then(function(module) {
                expect(module).toBeDefined();
                done();
            }).catch(function(error) {
                // Network error expected, but not security error
                const message = error.message || String(error);
                expect(message).not.toContain("not allowed in production");
                done();
            });
        });
    });
    
    describe("Error Messages", function() {
        // Verify error message format for security-related issues
        // In debug mode we won't see these, but we can verify the error
        // handling code doesn't crash
        
        it("should provide clear errors for failed HTTP imports", function(done) {
            import(DEAD_HTTP + "/module.js").then(function(module) {
                done();
            }).catch(function(error) {
                expect(error).toBeDefined();
                expect(error.message).toBeDefined();
                // Error should mention something about the module or HTTP
                const message = error.message.toLowerCase();
                const hasRelevantInfo = message.includes("http") || 
                                        message.includes("module") || 
                                        message.includes("import") ||
                                        message.includes("failed") ||
                                        message.includes("error");
                expect(hasRelevantInfo).toBe(true);
                done();
            });
        });
    });
    
    describe("Edge Cases", function() {
        
        it("should handle empty HTTP URLs gracefully", function(done) {
            // Empty or malformed URLs should not crash
            try {
                import("http://").then(function() {
                    done();
                }).catch(function() {
                    done();
                });
            } catch (e) {
                // Synchronous throw is also acceptable
                done();
            }
        });
        
        it("should handle URLs with special characters", function(done) {
            // URLs with encoded characters should be handled properly
            import(DEAD_HTTPS + "/module%20with%20spaces.js").then(function(module) {
                done();
            }).catch(function(error) {
                // Error handling should not crash
                expect(error).toBeDefined();
                done();
            });
        });
        
        it("should handle URLs with query parameters", function(done) {
            import(DEAD_HTTPS + "/lodash?target=es2020").then(function(module) {
                done();
            }).catch(function(error) {
                // Query params should be preserved in URL handling
                expect(error).toBeDefined();
                done();
            });
        });
        
        it("should handle URLs with fragments", function(done) {
            import(DEAD_HTTPS + "/module#section").then(function(module) {
                done();
            }).catch(function(error) {
                expect(error).toBeDefined();
                done();
            });
        });
    });

    // The release allowlist rule, through the debug-only diagnostic that runs
    // it: debug builds never gate a fetch on it.
    describe("Allowlist rule (ns:module remoteUrlMatchesAllowlist)", function() {
        function matches(url, entries) {
            var fn = require("ns:module").remoteUrlMatchesAllowlist;
            if (typeof fn !== "function") {
                pending("ns:module.remoteUrlMatchesAllowlist not exposed (release build)");
                return undefined;
            }
            return fn(url, entries);
        }

        function expectRows(entry, rows) {
            rows.forEach(function (row) {
                var actual = matches(row[0], [entry]);
                if (actual === undefined) {
                    return;
                }
                expect(entry + " vs " + row[0] + ": " + actual).toBe(entry + " vs " + row[0] + ": " + row[1]);
            });
        }

        it("matches a plain entry by prefix at a component boundary", function() {
            expectRows("https://cdn.example", [
                ["https://cdn.example/x.js", true],
                ["https://cdn.example", true],
                ["https://cdn.example.evil/x.js", false],
                ["https://cdn.example@evil/x.js", false],
                ["https://cdn.example:9999/x.js", false],
            ]);
        });

        it("keeps a path-scoped entry from being escaped by dot segments", function() {
            expectRows("https://cdn.example/modules/", [
                ["https://cdn.example/modules/x.js", true],
                ["https://cdn.example/modules/../../x.js", false],
                ["https://cdn.example/modules/%2e%2e/x.js", false],
                ["https://cdn.example/other/../modules/x.js", true],
            ]);
        });

        it("treats an entry with and without a trailing slash by the boundary rule", function() {
            expectRows("https://cdn.example/modules", [
                ["https://cdn.example/modules/x.js", true],
                ["https://cdn.example/modules?v=1", true],
                ["https://cdn.example/modulesx/y.js", false],
            ]);
            expectRows("https://cdn.example/modules/", [
                ["https://cdn.example/modules", false],
                ["https://cdn.example/modulesx/y.js", false],
            ]);
        });

        it("compares the host as written", function() {
            expectRows("https://CDN.example/modules/", [
                ["https://CDN.example/modules/x.js", true],
                ["https://cdn.example/modules/x.js", false],
            ]);
            expectRows("HTTPS://cdn.example/modules/", [
                ["https://cdn.example/modules/x.js", true],
            ]);
        });

        it("spells an entry's path the way fetched URLs are spelled", function() {
            expectRows("https://cdn.example/mödule/", [
                ["https://cdn.example/mödule/x.js", true],
                ["https://cdn.example/m%C3%B6dule/x.js", true],
            ]);
        });

        it("keeps an entry that is not a parseable http(s) URL verbatim", function() {
            expectRows("https://[fe80::1%25en0]/", [
                ["https://[fe80::1%25en0]/x.js", true],
            ]);
            expectRows("cdn.example/", [
                ["https://cdn.example/x.js", false],
            ]);
        });

        it("rejects arguments that are not a URL string and an array of strings", function() {
            var fn = require("ns:module").remoteUrlMatchesAllowlist;
            if (typeof fn !== "function") {
                pending("ns:module.remoteUrlMatchesAllowlist not exposed (release build)");
                return;
            }
            [[], ["https://h/x.js"], ["https://h/x.js", "https://h/"], [1, []],
             ["https://h/x.js", [1]]].forEach(function (args) {
                expect(function () { fn.apply(null, args); })
                    .toThrowError(TypeError,
                                  "remoteUrlMatchesAllowlist expects a URL string and an array of strings");
            });
        });
    });
});

console.log("Remote Module Security tests loaded");
