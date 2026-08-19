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
        
        it("settles a local dynamic import issued from a background thread", function(done) {
            var bgQueue = dispatch_get_global_queue(qos_class_t.QOS_CLASS_DEFAULT, 0);
            dispatch_async(bgQueue, function() {
                import("~/tests/esm/graph/bg-solo.mjs").then(function(module) {
                    expect(module.name).toBe("bg-solo");
                    done();
                }).catch(function(error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });
        });

        describe("from a background thread over HTTP", function() {
            var originalTimeout;
            beforeEach(function() {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = 60000;
            });
            afterEach(function() {
                jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            });

            it("settles an HTTP dynamic import issued from a background thread", function(done) {
                var origin = getHostOrigin();
                if (!origin) {
                    done();
                    return;
                }
                // Completion delivery must not depend on the calling thread
                // having a runloop of its own. Live-network neighbors
                // (blackhole-host specs) can slow connection setup, so allow
                // one retry and a generous budget like the other live-network
                // specs here. Each attempt uses a distinct URL so an errored
                // registry entry cannot poison the retry.
                var bgQueue = dispatch_get_global_queue(qos_class_t.QOS_CLASS_DEFAULT, 0);
                dispatch_async(bgQueue, function() {
                    function attempt(remaining) {
                        return withTimeout(import(origin + "/esm/query.mjs?v=bg" + remaining), 25000, "bg http import").catch(function(error) {
                            if (remaining > 0) {
                                return attempt(remaining - 1);
                            }
                            throw error;
                        });
                    }
                    attempt(1).then(function(module) {
                        expect(module).toBeDefined();
                        expect(module.query).toContain("v=bg");
                        done();
                    }).catch(function(error) {
                        expect("rejected: " + formatError(error)).toBe("resolved");
                        done();
                    });
                });
            });
        });

        it("evaluates a disk diamond graph in spec order, each module once", function(done) {
            import("~/tests/esm/graph/diamond-entry.mjs").then(function(module) {
                expect(module.order).toEqual(["shared", "left", "right", "entry"]);
                expect(module.names).toEqual(["left", "right"]);
                done();
            }).catch(function(error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        // A local root whose graph reaches an HTTP leaf. Discovery is
        // scheme-agnostic, so the walk compiles the whole closure up front and
        // the resolver never takes a blocking synchronous fetch.
        describe("mixed local/http graphs", function () {
            function configureLeaves(origin) {
                // configureLoader takes a whole import map, so the entries
                // live under the standard "imports" key.
                require("ns:module").configureLoader({
                    importMap: {
                        imports: {
                            "ns-test-leaf-a": origin + "/esm/graph-leaf.mjs?k=a",
                            "ns-test-leaf-b": origin + "/esm/graph-leaf.mjs?k=b",
                        },
                    },
                });
            }

            afterEach(function () {
                require("ns:module").configureLoader({ importMap: { imports: {} } });
            });

            it("resolves a local->local->http graph through require()", function () {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    return;
                }
                configureLeaves(origin);

                var req = require("ns:module").createRequire(__dirname + "/anything.js");
                var mod = req("./esm/mixed/a-entry.mjs");
                expect(mod.leaf).toBe("a");
                // Spec evaluation order, deepest first — the walk changes only
                // when modules are compiled, never when they run.
                expect(mod.order).toEqual(["leaf", "mid", "entry"]);
            });

            it("resolves a local->local->http graph through import()", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                configureLeaves(origin);

                import("~/tests/esm/mixed/b-entry.mjs").then(function (mod) {
                    expect(mod.leaf).toBe("b");
                    expect(mod.order).toEqual(["leaf", "mid", "entry"]);
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });
        });

        // The import map is process-wide, so every spec here installs its own
        // and restores the empty map afterwards.
        describe("import map", function () {
            var nsModule = require("ns:module");

            function setMap(map) {
                nsModule.configureLoader({ importMap: map });
            }

            afterEach(function () {
                setMap({ imports: {} });
            });

            it("rejects an unknown top-level section by name", function () {
                expect(function () {
                    setMap({ imports: {}, integrity: {} });
                }).toThrowError(TypeError, /unsupported import-map section 'integrity'/);
            });

            it("rejects a trailing-slash key whose target does not end in '/'", function () {
                expect(function () {
                    setMap({ imports: { "pkg/": "http://example.com/pkg" } });
                }).toThrowError(TypeError, /must end with '\/'/);
            });

            it("rejects a trailing-slash key inside a scope map too", function () {
                expect(function () {
                    setMap({ scopes: { "/a/": { "pkg/": "http://example.com/pkg" } } });
                }).toThrowError(TypeError, /must end with '\/'/);
            });

            it("rejects a null or non-string target", function () {
                expect(function () {
                    setMap({ imports: { "pkg": null } });
                }).toThrowError(TypeError, /must be a string/);
                expect(function () {
                    setMap({ imports: { "pkg": 42 } });
                }).toThrowError(TypeError, /must be a string/);
            });

            it("rejects a non-object scope map", function () {
                expect(function () {
                    setMap({ scopes: { "/a/": "not-an-object" } });
                }).toThrowError(TypeError, /must be an object/);
            });

            it("keeps the previous map when an update is rejected", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                setMap({ imports: { "ns-survivor": origin + "/esm/graph-leaf.mjs?k=surv" } });

                expect(function () {
                    nsModule.configureLoader({ importMap: "{ this is not json" });
                }).toThrowError(TypeError, /valid JSON/);

                // The rejected update changed nothing, so the module installed
                // by the previous map still resolves.
                import("~/tests/esm/scoped/survivor.mjs").then(function (mod) {
                    expect(mod.leaf).toBe("surv");
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });

            // The vocabulary is per-isolate; a worker gets a copy taken on the
            // parent's thread as it spawns.
            it("gives a worker spawned after configureLoader the parent's map", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                setMap({ imports: { "ns-worker-leaf": origin + "/esm/graph-leaf.mjs?k=wa" } });

                var worker = new Worker("./importMapWorker.js");
                worker.onmessage = function (msg) {
                    expect(msg.data.ok ? "resolved" : "failed: " + msg.data.error).toBe("resolved");
                    expect(msg.data.name).toBe("wa");
                    worker.terminate();
                    done();
                };
                worker.postMessage("ns-worker-leaf");
            });

            it("leaves a running worker on the map it was spawned with", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                setMap({ imports: { "ns-worker-leaf": origin + "/esm/graph-leaf.mjs?k=wb" } });

                var worker = new Worker("./importMapWorker.js");
                worker.onmessage = function (msg) {
                    expect(msg.data.ok ? "resolved" : "failed: " + msg.data.error).toBe("resolved");
                    // The worker still sees the map captured at its spawn, not
                    // the one installed after it started.
                    expect(msg.data.name).toBe("wb");
                    worker.terminate();
                    done();
                };

                // Reconfigure the parent only after the worker exists, then ask
                // it to resolve. The parent's own isolate does see the update.
                setMap({ imports: { "ns-worker-leaf": origin + "/esm/graph-leaf.mjs?k=wc" } });
                worker.postMessage("ns-worker-leaf");
            });

            it("resolves through the scope cascade for every referrer", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var insideScope = __dirname + "/esm/scoped/inside/";
                var deepScope = __dirname + "/esm/scoped/inside/deep/";
                var scopes = {};
                scopes[insideScope] = { "ns-scoped-leaf": origin + "/esm/graph-leaf.mjs?k=in" };
                scopes[deepScope] = { "ns-scoped-leaf": origin + "/esm/graph-leaf.mjs?k=deep" };
                setMap({
                    imports: {
                        "ns-scoped-leaf": origin + "/esm/graph-leaf.mjs?k=top",
                        "ns-scoped-fallthrough": origin + "/esm/graph-leaf.mjs?k=fall",
                    },
                    scopes: scopes,
                });

                Promise.all([
                    import("~/tests/esm/scoped/inside/mid.mjs"),
                    import("~/tests/esm/scoped/inside/deep/mid.mjs"),
                    import("~/tests/esm/scoped/outside/mid.mjs"),
                ]).then(function (mods) {
                    // A scope wins over the top-level entry for a referrer inside it.
                    expect(mods[0].leaf).toBe("in");
                    // ...and a specifier the scope does not define falls through.
                    expect(mods[0].fallthrough).toBe("fall");
                    // Two scopes match; the more specific one wins.
                    expect(mods[1].leaf).toBe("deep");
                    // No scope matches this referrer.
                    expect(mods[2].leaf).toBe("top");
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });
        });

        // Module scripts are strict about MIME on the web, and so is the
        // loader: the response policy lives in one classifier shared by the
        // synchronous fallback and the graph walk.
        describe("module MIME gate", function () {
            function rejectionOf(url, callback) {
                import(url).then(function () {
                    callback("<resolved>");
                }).catch(function (error) {
                    callback(String((error && error.message) || error));
                });
            }

            it("rejects an SPA fallback that answers with text/html", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var url = origin + "/esm/html-fallback.mjs";
                rejectionOf(url, function (message) {
                    // The DX win: the cause is the MIME type, not a syntax
                    // error from HTML reaching the JS parser.
                    expect(message.indexOf("text/html") >= 0 ? "names the MIME" : message)
                        .toBe("names the MIME");
                    expect(message.indexOf(url) >= 0 ? "names the URL" : message)
                        .toBe("names the URL");
                    expect(message.indexOf("Unexpected token") >= 0 ? message : "no parse error")
                        .toBe("no parse error");
                    done();
                });
            });

            it("rejects a response that carries no MIME type", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var url = origin + "/esm/no-mime.mjs";
                rejectionOf(url, function (message) {
                    expect(message.indexOf("no MIME type") >= 0 ? "names the missing MIME" : message)
                        .toBe("names the missing MIME");
                    expect(message.indexOf(url) >= 0 ? "names the URL" : message)
                        .toBe("names the URL");
                    done();
                });
            });

            it("still serves an empty 200 with a JS MIME as the empty module", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                // Type-only modules transform to zero runtime code; dev servers
                // serve them as empty 200s and they must stay valid.
                import(origin + "/esm/empty.mjs").then(function (mod) {
                    expect(typeof mod).toBe("object");
                    expect(Object.keys(mod)).toEqual([]);
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });

            it("routes a served JSON module through the JSON path, with stable identity",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var url = origin + "/esm/data.json";
                import(url).then(function (first) {
                    expect(first.default.kind).toBe("json-module");
                    expect(first.default.n).toBe(41);
                    return import(url).then(function (second) {
                        expect(second).toBe(first);
                        expect(second.default).toBe(first.default);
                        done();
                    });
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });

            // Re-importing from inside the first import's own resolution is
            // the case that exposed stale waiter routing: the reaction runs
            // while the first settle is still unwinding, so the loader must
            // already have cleared the state that would park this import on a
            // waiter list nothing will flush.
            it("settles a re-entrant re-import issued from the first import's handler",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var url = origin + "/esm/data.json?reentrant=1";
                var settled = "never settled";
                import(url).then(function (first) {
                    import(url).then(function (second) {
                        settled = second === first ? "same namespace" : "different namespace";
                    }, function (error) {
                        settled = "re-import rejected: " + ((error && error.message) || error);
                    });
                }, function (error) {
                    settled = "first import rejected: " + ((error && error.message) || error);
                });
                __ns__setTimeout(function () {
                    expect(settled).toBe("same namespace");
                    done();
                }, 1500);
            });
        });

        it("links and evaluates cyclic disk imports", function(done) {
            import("~/tests/esm/graph/cycle-a.mjs").then(function(module) {
                expect(module.aValue).toBe("a");
                expect(module.roundTrip).toBe("b-saw-a");
                expect(module.describeB()).toBe("a-saw-b");
                done();
            }).catch(function(error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("gives nested disk modules a correct import.meta", function(done) {
            import("~/tests/esm/relative/meta.mjs").then(function(module) {
                expect(typeof module.metaUrl).toBe("string");
                expect(module.metaUrl.indexOf("file://")).toBe(0);
                expect(module.metaUrl).toContain("tests/esm/relative/meta.mjs");
                expect(typeof module.metaDirname).toBe("string");
                expect(module.metaDirname).toContain("tests/esm/relative");
                expect(module.metaDirname).not.toContain("meta.mjs");
                done();
            }).catch(function(error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("returns one module identity for repeated JSON imports", function(done) {
            var spec = "~/tests/esm/identity.json";
            Promise.all([import(spec), import(spec)]).then(function(results) {
                expect(results[0]).toBe(results[1]);
                expect(results[0].default.name).toBe("esm-identity-fixture");
                expect(results[0].default.value).toBe(42);
                return import(spec).then(function(third) {
                    expect(third).toBe(results[0]);
                    expect(third.default).toBe(results[0].default);
                    done();
                });
            }).catch(function(error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
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
        
        it("surfaces the real compile error for a served module with a syntax error", function(done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }

            var url = origin + "/esm/syntax-error.mjs";
            withTimeout(import(url), 5000, "import " + url)
                .then(function() {
                    expect("resolved").toBe("rejected");
                    done();
                })
                .catch(function(error) {
                    // The parse error itself, not a generic "compile failed" /
                    // instantiation failure that names no cause.
                    var message = String((error && error.message) || error);
                    expect(message.indexOf("Unexpected token") >= 0 ? "names the parse error" : message)
                        .toBe("names the parse error");
                    expect(message.indexOf("syntax-error.mjs") >= 0 ? "names the module" : message)
                        .toBe("names the module");
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
            // The loader should ignore malformed http specifiers
            expect(function() {
                import("http://");
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
            expect(typeof nsModule.createRequire).toBe("function");
            expect(typeof nsModule.createPumpingRequire).toBe("function");
            // Boot state is derived by the runtime (the pump is armed only
            // while an entry module evaluates); there is no client signal.
            expect(nsModule.setDevBootComplete).toBeUndefined();
            // Worker teardown is userland (the dev client intercepts the
            // Worker constructor); the runtime deliberately exposes no
            // terminateAllWorkers member.
            expect(nsModule.terminateAllWorkers).toBeUndefined();
        });

        // The export set is public API, declared in types/ns-module.d.ts and
        // docs/ns-builtin-modules.md — all three must change together.
        // `canonicalizeHttpUrlKey` is a debug-only diagnostic (absent from the
        // .d.ts and from release builds), so the expected set varies by build.
        it("exposes exactly the declared surface", function () {
            var nsModule = require("ns:module");
            var expected = ["configureLoader", "createPumpingRequire", "createRequire",
                            "getLoadedModuleUrls", "invalidateModules"];
            if (typeof nsModule.canonicalizeHttpUrlKey === "function") {
                expected.push("canonicalizeHttpUrlKey");
            }
            expect(Object.keys(nsModule).sort()).toEqual(expected.sort());
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

        // Collapsing cache-busters onto one registry key needs a vocabulary;
        // the runtime ships none, so these specs install one. Canonicalization
        // config is process-wide, hence the restore. (Jasmine 2.0.1 has no
        // beforeAll/afterAll.)
        describe("with a dev-endpoint vocabulary configured", function () {
            beforeEach(function () {
                require("ns:module").configureLoader({
                    canonicalization: {
                        stripParams: ["t", "v", "import"],
                        forPathPrefixes: ["/ns/"],
                        preserveQueryFor: [],
                    },
                });
            });

            afterEach(function () {
                require("ns:module").configureLoader({
                    canonicalization: { stripParams: [], forPathPrefixes: [], preserveQueryFor: [] },
                });
            });

            it("drops the configured cache-busters for dev endpoints", function (done) {
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
                            // Both URLs map to one cache key, so the second
                            // import reuses the first evaluated module.
                            expect(m2.evaluatedAt).toBe(m1.evaluatedAt);
                            expect(m2.query).toBe(m1.query);
                            done();
                        });
                    })
                    .catch(function (error) {
                        expect("rejected: " + formatError(error)).toBe("resolved");
                        done();
                    });
            });

            it("sorts query params for dev endpoints", function (done) {
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
                        expect("rejected: " + formatError(error)).toBe("resolved");
                        done();
                    });
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

    // Unconfigured, the runtime knows no client vocabulary: it strips the
    // fragment and nothing else. Which params are cache-busters and which
    // paths are dev endpoints arrives through configureLoader.
    describe("unconfigured (mechanical only)", function () {
        it("keeps every query param, cache-buster-looking or not", function () {
            checkKey("http://h/ns/core?p=x&t=123&v=9&import=1",
                     "http://h/ns/core?p=x&t=123&v=9&import=1");
        });

        it("leaves public URLs untouched", function () {
            checkKey("https://cdn.example.com/lib.js?token=abc",
                     "https://cdn.example.com/lib.js?token=abc");
        });

        it("treats module identity as literally the URL — no path-tag collapses", function () {
            checkKey("http://h/ns/m/foo.js", "http://h/ns/m/foo.js");
            checkKey("http://h/ns/rt", "http://h/ns/rt");
            checkKey("http://h/ns/core", "http://h/ns/core");
        });

        it("still drops the fragment", function () {
            checkKey("http://h/ns/m/foo.js#frag", "http://h/ns/m/foo.js");
            checkKey("https://cdn.example.com/lib.js?token=abc#frag",
                     "https://cdn.example.com/lib.js?token=abc");
        });
    });

    // Canonicalization config is process-wide, so each spec here installs its
    // vocabulary and restores the unconfigured state afterwards. (Jasmine
    // 2.0.1 has no beforeAll/afterAll.)
    describe("with a client-supplied vocabulary", function () {
        beforeEach(function () {
            var nsModule = require("ns:module");
            if (typeof nsModule.canonicalizeHttpUrlKey !== "function") {
                return;
            }
            nsModule.configureLoader({
                canonicalization: {
                    stripParams: ["t", "v", "import"],
                    forPathPrefixes: ["/dev/"],
                    preserveQueryFor: ["/dev/metadata"],
                },
            });
        });

        afterEach(function () {
            var nsModule = require("ns:module");
            if (typeof nsModule.canonicalizeHttpUrlKey !== "function") {
                return;
            }
            nsModule.configureLoader({
                canonicalization: { stripParams: [], forPathPrefixes: [], preserveQueryFor: [] },
            });
        });

        it("strips the configured cache-busters under a configured prefix", function () {
            checkKey("http://h/dev/core?p=x&t=123&v=9&import=1", "http://h/dev/core?p=x");
        });

        it("lets preserveQueryFor win under a configured prefix", function () {
            checkKey("http://h/dev/metadata?c=a&t=42", "http://h/dev/metadata?c=a&t=42");
        });

        it("leaves paths outside the configured prefixes alone", function () {
            checkKey("http://h/ns/core?p=x&t=123", "http://h/ns/core?p=x&t=123");
            checkKey("https://cdn.example.com/lib.js?token=abc",
                     "https://cdn.example.com/lib.js?token=abc");
        });
    });
});

// A bare `@` is not a specifier the runtime knows: it resolves through the
// normal path and fails, naming itself, instead of being swallowed into a
// fabricated empty module.
describe("invalid module specifiers", function () {
    it("rejects a dynamic import of '@' with an error naming the specifier", function (done) {
        import("@").then(function () {
            expect("resolved").toBe("rejected");
            done();
        }).catch(function (e) {
            var message = String((e && e.message) || e);
            expect(message.indexOf("@") >= 0 ? "names the specifier" : message)
                .toBe("names the specifier");
            done();
        });
    });
});

console.log("HTTP ESM Loader tests loaded");