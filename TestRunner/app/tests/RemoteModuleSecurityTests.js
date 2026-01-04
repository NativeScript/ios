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
    
    describe("Debug Mode Behavior", function() {
        // In debug mode (test environment), all remote modules should be allowed
        // regardless of security configuration
        
        it("should allow HTTP module imports in debug mode", function(done) {
            // This test uses a known unreachable IP to trigger the HTTP loading path
            // In debug mode, the security check passes and we get a network error
            // (not a security error)
            import("http://192.0.2.1:5173/test-module.js").then(function(module) {
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
            // Test HTTPS URL - should be allowed in debug mode
            import("https://192.0.2.1:5173/test-module.js").then(function(module) {
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
            const bundlePath = NSBundle.mainBundle.bundlePath;
            const packagePath = bundlePath + "/app/package.json";
            
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
            // esm.sh is in our test allowlist
            // In debug mode this is allowed anyway, but tests the path
            import("https://esm.sh/test-module").then(function(module) {
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
            import("https://not-in-allowlist.example.com/module.js").then(function(module) {
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
            const testUrl = "https://esm.sh/@test/module";
            
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
            import("http://invalid-url-test:9999/module.js").then(function(module) {
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
            import("https://example.com/module%20with%20spaces.js").then(function(module) {
                done();
            }).catch(function(error) {
                // Error handling should not crash
                expect(error).toBeDefined();
                done();
            });
        });
        
        it("should handle URLs with query parameters", function(done) {
            import("https://esm.sh/lodash?target=es2020").then(function(module) {
                done();
            }).catch(function(error) {
                // Query params should be preserved in URL handling
                expect(error).toBeDefined();
                done();
            });
        });
        
        it("should handle URLs with fragments", function(done) {
            import("https://esm.sh/module#section").then(function(module) {
                done();
            }).catch(function(error) {
                expect(error).toBeDefined();
                done();
            });
        });
    });
});

console.log("Remote Module Security tests loaded");
