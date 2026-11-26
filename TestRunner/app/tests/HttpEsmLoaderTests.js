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

        // The module-fetch budget is build-dependent: 30s per request attempt
        // in debug runtimes, 5s in release (HttpLoader.mm). A module whose
        // response lands between the two — the measured 5–9s dev-server
        // cold-transform latency — resolves in debug and still rejects in
        // release. `canonicalizeHttpUrlKey` is a debug-only diagnostic export,
        // so its presence identifies the build.
        describe("fetch budget", function () {
            var isDebugBuild =
                typeof require("ns:module").canonicalizeHttpUrlKey === "function";
            var originalTimeout;
            beforeEach(function () {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = 30000;
            });
            afterEach(function () {
                jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            });

            function statsCount(origin, target) {
                return import(origin + "/esm/request-stats.json?target=" +
                              encodeURIComponent(target))
                    .then(function (m) {
                        return m.default.count;
                    });
            }

            it("resolves a slow HTTP module inside the budget on its first request",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var target = "/esm/slow/leaf.mjs?k=direct&delayMs=7000";
                import(origin + target).then(function (mod) {
                    if (!isDebugBuild) {
                        fail("a 7s response must not resolve within the 5s release budget");
                        done();
                        return;
                    }
                    expect(mod.value).toBe(42);
                    statsCount(origin, target).then(function (count) {
                        // One request: no transport retry and no synchronous
                        // fallback fetch — both issue a second request.
                        expect(count).toBe(1);
                        done();
                    }).catch(function (error) {
                        expect("stats rejected: " + formatError(error)).toBe("stats resolved");
                        done();
                    });
                }).catch(function (error) {
                    // Release: the 5s budget (and, on this allowlist, the
                    // security gate) reject a 7s response — the budget must
                    // not silently relax there.
                    expect(isDebugBuild ? "rejected: " + formatError(error) : "rejected")
                        .toBe("rejected");
                    done();
                });
            });

            it("resolves a slow HTTP re-export chain on one request per module",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                if (!isDebugBuild) {
                    pending("release budget rejects the 7s parent — covered by the direct spec");
                    done();
                    return;
                }
                // The parent spends 7s transforming, then the walk discovers
                // its re-exported child. Under the old 5s budget the parent's
                // subtree was never discovered and every edge fell back to
                // the blocking sync loader.
                var parentTarget = "/esm/slow/parent.mjs?k=chain&delayMs=7000";
                var childTarget = "/esm/slow/child.mjs?from=chain";
                import(origin + parentTarget).then(function (mod) {
                    expect(mod.value).toBe(42);
                    expect(mod.parent).toBe("chain");
                    Promise.all([statsCount(origin, parentTarget),
                                 statsCount(origin, childTarget)]).then(function (counts) {
                        expect(counts).toEqual([1, 1]);
                        done();
                    }).catch(function (error) {
                        expect("stats rejected: " + formatError(error)).toBe("stats resolved");
                        done();
                    });
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });

            it("waits for a slow HTTP leaf during a pumped require()", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                if (!isDebugBuild) {
                    pending("release budget rejects the 7s leaf — covered by the direct spec");
                    done();
                    return;
                }
                var leafTarget = "/esm/slow/req-leaf.mjs?k=req&delayMs=7000";
                var nsModule = require("ns:module");
                nsModule.configureLoader({
                    importMap: {
                        imports: { "ns-slow-leaf": origin + leafTarget },
                    },
                });
                try {
                    var req = nsModule.createRequire(__dirname + "/anything.js");
                    // Blocks the JS thread for the walk's ~7s fetch; the
                    // re-export boundary at slow-mid.mjs keeps the leaf's
                    // transitive edge inside the pumped graph.
                    var mod = req("./esm/mixed/slow-entry.mjs");
                    expect(mod.leaf).toBe(42);
                } finally {
                    nsModule.configureLoader({ importMap: { imports: {} } });
                }
                statsCount(origin, leafTarget).then(function (count) {
                    expect(count).toBe(1);
                    done();
                }).catch(function (error) {
                    expect("stats rejected: " + formatError(error)).toBe("stats resolved");
                    done();
                });
            });
        });

        describe("worker teardown", function () {
            var originalTimeout;
            beforeEach(function () {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = 30000;
            });
            afterEach(function () {
                jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            });

            it("survives HTTP module fetches that land after their worker terminated",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var workerDelayMs = 2000;
                var workerCount = 5;
                var remaining = workerCount;

                // Delayed past every worker response, so by the time it
                // settles all of them have arrived at their torn-down loaders.
                function importOnMain() {
                    import(origin + "/esm/slow/leaf.mjs?k=wt-main&delayMs=" + (workerDelayMs + 1000))
                        .then(function (mod) {
                            expect(mod.value).toBe(42);
                            done();
                        }).catch(function (error) {
                            expect("rejected: " + formatError(error)).toBe("resolved");
                            done();
                        });
                }

                function settle(worker) {
                    worker.terminate();
                    if (--remaining === 0) {
                        importOnMain();
                    }
                }

                for (var i = 0; i < workerCount; i++) {
                    (function (worker, k) {
                        worker.onmessage = function () {
                            settle(worker);
                        };
                        worker.onerror = function (error) {
                            fail("worker " + k + " errored: " + formatError(error));
                            settle(worker);
                        };
                        worker.postMessage(origin + "/esm/slow/leaf.mjs?k=" + k +
                                           "&delayMs=" + workerDelayMs);
                    })(new Worker("./httpImportTerminateWorker.js"), "wt" + i);
                }
            });
        });

        // Bodies of 32 KiB or more compile off the JS thread. Every module
        // here comes from ModuleTestServer's /esm/big.mjs generator, has its
        // own `k` (modules evaluate once per process) and asserts `bytes` so
        // it is above that threshold by construction.
        describe("large modules", function () {
            var STREAMING_THRESHOLD = 32 * 1024;
            var LINES = 1500;
            var originalTimeout;
            beforeEach(function () {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = 30000;
            });
            afterEach(function () {
                jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            });

            function bigQuery(k, lines, extra) {
                return "k=" + k + "&lines=" + lines + (extra || "");
            }

            function bigUrl(origin, k, lines, extra) {
                return origin + "/esm/big.mjs?" + bigQuery(k, lines, extra);
            }

            function expectWholeBody(mod, k, lines) {
                var total = 0;
                for (var i = 0; i < lines; i++) {
                    total += (i * 3 + i) % 1000;
                }
                expect(mod.id).toBe(k);
                expect(mod.count).toBe(lines);
                expect(mod.total).toBe(total);
                expect(mod.bytes).toBeGreaterThan(STREAMING_THRESHOLD);
                expect(globalThis.__nsBigModuleEvaluations[k]).toBe(1);
            }

            function rejectionOf(url) {
                return import(url).then(function () {
                    return "resolved";
                }, function (error) {
                    return formatError(error);
                });
            }

            // The rejection names the module and the error position; strip the
            // URL so a small and a large module's texts compare equal.
            function withoutUrl(message, url) {
                return message.split(url).join("<url>");
            }

            function failWith(done) {
                return function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                };
            }

            it("evaluates one loaded with import()", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                import(bigUrl(origin, "big-dynamic", LINES)).then(function (mod) {
                    expectWholeBody(mod, "big-dynamic", LINES);
                    done();
                }).catch(failWith(done));
            });

            it("evaluates one reached through a static import", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var child = encodeURIComponent(bigQuery("big-static", LINES));
                import(origin + "/esm/big-parent.mjs?k=big-static-parent&child=" + child)
                    .then(function (mod) {
                        expect(mod.parent).toBe("big-static-parent");
                        expectWholeBody(mod.child, "big-static", LINES);
                        done();
                    }).catch(failWith(done));
            });

            it("evaluates one reached during a pumped require()", function () {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    return;
                }
                var nsModule = require("ns:module");
                nsModule.configureLoader({
                    importMap: {
                        imports: { "ns-big-leaf": bigUrl(origin, "big-require", LINES) },
                    },
                });
                try {
                    var req = nsModule.createRequire(__dirname + "/anything.js");
                    var mod = req("./esm/mixed/big-entry.mjs");
                    expectWholeBody(mod.leaf, "big-require", LINES);
                } finally {
                    nsModule.configureLoader({ importMap: { imports: {} } });
                }
            });

            it("evaluates non-ASCII string literals to the right values", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                import(bigUrl(origin, "big-unicode", LINES, "&unicode=1")).then(function (mod) {
                    expectWholeBody(mod, "big-unicode", LINES);
                    var joinedLength = 0;
                    for (var i = 0; i < LINES; i++) {
                        joinedLength += ("café 日本語 😀 " + i).length;
                    }
                    expect(mod.first).toBe("café 日本語 😀 0");
                    expect(mod.last).toBe("café 日本語 😀 " + (LINES - 1));
                    expect(mod.joinedLength).toBe(joinedLength);
                    done();
                }).catch(failWith(done));
            });

            it("rejects a syntax error with the text a small module produces", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var smallUrl = bigUrl(origin, "small-syntax", 0, "&error=1");
                var largeUrl = bigUrl(origin, "big-syntax", LINES, "&error=1");
                Promise.all([rejectionOf(smallUrl), rejectionOf(largeUrl)]).then(function (texts) {
                    var position = /\(line (\d+):(\d+)\)/;
                    var small = withoutUrl(texts[0], smallUrl);
                    var large = withoutUrl(texts[1], largeUrl);
                    expect(small).toContain("SyntaxError");
                    // The error sits on the line after the filler declarations.
                    expect(small.match(position)[1]).toBe("3");
                    expect(large.match(position)[1]).toBe(String(LINES + 3));
                    expect(large.replace(position, "")).toBe(small.replace(position, ""));
                    expect(large.match(position)[2]).toBe(small.match(position)[2]);
                    done();
                }).catch(failWith(done));
            });

            it("rejects pathologically deep nesting like a small module does", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                // 20 KB of brackets: below the threshold on its own, above it
                // with the filler declarations.
                var smallUrl = bigUrl(origin, "small-deep", 0, "&nest=10000");
                var largeUrl = bigUrl(origin, "big-deep", 600, "&nest=10000");
                Promise.all([rejectionOf(smallUrl), rejectionOf(largeUrl)]).then(function (texts) {
                    var position = /\s*\(line \d+:\d+\)/;
                    var small = withoutUrl(texts[0], smallUrl).replace(position, "");
                    var large = withoutUrl(texts[1], largeUrl).replace(position, "");
                    expect(small).toContain("Maximum call stack size exceeded");
                    expect(large).toBe(small);
                    done();
                }).catch(failWith(done));
            });

            it("resolves one module for concurrent imports from several call sites",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var query = bigQuery("big-shared", LINES);
                var url = origin + "/esm/big.mjs?" + query;
                var parent = origin + "/esm/big-parent.mjs?child=" + encodeURIComponent(query) +
                             "&k=";
                Promise.all([
                    import(url),
                    import(parent + "big-shared-a"),
                    import(url),
                    import(parent + "big-shared-b"),
                ]).then(function (mods) {
                    expectWholeBody(mods[0], "big-shared", LINES);
                    expect(mods[2]).toBe(mods[0]);
                    expect(mods[1].child).toBe(mods[0]);
                    expect(mods[3].child).toBe(mods[0]);
                    done();
                }).catch(failWith(done));
            });

            it("survives workers terminated while their large modules compile",
               function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var MODULE_LINES = 40000;
                // The sweep terminates worker n at n * STEP of a calibrated
                // import's duration, from 0 to slightly past its end. The
                // background compile occupies only part of that duration, and
                // where it starts depends on the machine, so the points cover
                // all of it.
                var STEPS = 23;
                var STEP = 0.05;

                function importOnMain() {
                    import(bigUrl(origin, "big-after-workers", LINES)).then(function (mod) {
                        expectWholeBody(mod, "big-after-workers", LINES);
                        done();
                    }).catch(failWith(done));
                }

                // Calls onFetching when the worker's import is issued and
                // onSettled when it settles, each at most once; a worker
                // that errors counts as settled.
                function startWorker(k, onFetching, onSettled) {
                    var worker = new Worker("./httpImportSettleWorker.js");
                    var fetching = false;
                    var settled = false;
                    function settle() {
                        if (!settled) {
                            settled = true;
                            onSettled(worker);
                        }
                    }
                    worker.onmessage = function (msg) {
                        if (msg.data === "fetching" && !fetching) {
                            fetching = true;
                            onFetching(worker);
                        } else if (msg.data === "settled") {
                            settle();
                        }
                    };
                    worker.onerror = function (error) {
                        fail("worker " + k + " errored: " + formatError(error));
                        settle();
                    };
                    worker.postMessage(bigUrl(origin, k, MODULE_LINES));
                }

                // One worker at a time, so each compile has the pool to itself
                // as the calibration import did. A worker moves the sweep on
                // at its termination point or when it settles, whichever
                // comes first; a terminated worker never settles.
                function sweep(durationMs, step) {
                    if (step === STEPS) {
                        importOnMain();
                        return;
                    }
                    var ended = false;
                    function next(worker) {
                        if (ended) {
                            return;
                        }
                        ended = true;
                        worker.terminate();
                        sweep(durationMs, step + 1);
                    }
                    startWorker("big-worker-" + step, function (worker) {
                        setTimeout(function () {
                            next(worker);
                        }, durationMs * step * STEP);
                    }, next);
                }

                var fetchingAt = 0;
                startWorker("big-worker-calibration", function () {
                    fetchingAt = Date.now();
                }, function (worker) {
                    worker.terminate();
                    if (fetchingAt === 0) {
                        importOnMain();
                        return;
                    }
                    sweep(Date.now() - fetchingAt, 0);
                });
            }, 60000);
        });

        // The import map is process-wide, so every spec here installs its own
        // and restores the empty map afterwards.
        // Each present configureLoader section replaces its state wholesale, so
        // an empty array is explicit policy — "nothing is volatile any more" —
        // not a no-op.
        describe("volatile patterns", function () {
            var nsModule = require("ns:module");

            afterEach(function () {
                nsModule.configureLoader({ volatilePatterns: [] });
            });

            it("stops treating a URL as volatile once the list is emptied", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                // The fixture pushes one entry per evaluation, so the bucket
                // length counts how many times the module actually ran.
                var url = origin + "/esm/graph-leaf.mjs?k=vol";
                function evaluations() {
                    return (globalThis.__nsMixedOrdervol || []).length;
                }

                nsModule.configureLoader({ volatilePatterns: ["k=vol"] });

                import(url).then(function () {
                    return import(url);
                }).then(function () {
                    // Volatile: the cached module is dropped, so it re-evaluates.
                    expect(evaluations()).toBe(2);

                    nsModule.configureLoader({ volatilePatterns: [] });
                    return import(url);
                }).then(function () {
                    // Cleared: the registry entry is reused, nothing re-runs.
                    expect(evaluations()).toBe(2);
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
            });
        });

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

            // import() resolves through the same cascade as a static import.
            // It used to resolve twice — once here with the referrer, once more
            // inside the walk pre-pass with none — and the scope-less second
            // pass is the one that decided the walk root.
            it("resolves a dynamic import through the referrer's scope", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var insideScope = __dirname + "/esm/scoped/inside/";
                var scopes = {};
                scopes[insideScope] = { "ns-scoped-leaf": origin + "/esm/graph-leaf.mjs?k=dyn" };
                setMap({
                    imports: { "ns-scoped-leaf": origin + "/esm/graph-leaf.mjs?k=top" },
                    scopes: scopes,
                });

                import("~/tests/esm/scoped/inside/dynamic.mjs").then(function (mod) {
                    return mod.loadLeaf();
                }).then(function (name) {
                    // The scope wins over the top-level entry for this referrer.
                    expect(name).toBe("dyn");
                    done();
                }).catch(function (error) {
                    expect("rejected: " + formatError(error)).toBe("resolved");
                    done();
                });
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

        // An imperative API rejects bad input loudly, the way WebIDL does on the
        // web and ERR_INVALID_ARG_TYPE does in Node. Silently skipping a
        // mistyped section or a typo'd key turns a caller's bug into a config
        // that quietly does nothing.
        describe("loader surface argument validation", function () {
            var nsModule = require("ns:module");

            it("rejects a missing or non-object config", function () {
                expect(function () {
                    nsModule.configureLoader();
                }).toThrowError(TypeError, /configureLoader expects a config object/);
                expect(function () {
                    nsModule.configureLoader(42);
                }).toThrowError(TypeError, /configureLoader expects a config object/);
            });

            it("rejects an unknown top-level config key by name", function () {
                expect(function () {
                    nsModule.configureLoader({ typoKey: [] });
                }).toThrowError(TypeError, /unknown option 'typoKey'/);
            });

            it("rejects a non-array volatilePatterns", function () {
                expect(function () {
                    nsModule.configureLoader({ volatilePatterns: "x" });
                }).toThrowError(TypeError, /volatilePatterns must be an array of strings/);
            });

            it("rejects a non-string volatilePatterns element by index", function () {
                expect(function () {
                    nsModule.configureLoader({ volatilePatterns: [1] });
                }).toThrowError(TypeError, /volatilePatterns\[0\] must be a string/);
                expect(function () {
                    nsModule.configureLoader({ volatilePatterns: ["ok", null] });
                }).toThrowError(TypeError, /volatilePatterns\[1\] must be a string/);
            });

            it("rejects a non-object canonicalization", function () {
                expect(function () {
                    nsModule.configureLoader({ canonicalization: "x" });
                }).toThrowError(TypeError, /canonicalization must be an object/);
            });

            it("rejects a non-array canonicalization sub-key by name", function () {
                expect(function () {
                    nsModule.configureLoader({ canonicalization: { stripParams: "t" } });
                }).toThrowError(TypeError,
                                /canonicalization\.stripParams must be an array of strings/);
                expect(function () {
                    nsModule.configureLoader({ canonicalization: { forPathPrefixes: [7] } });
                }).toThrowError(TypeError, /canonicalization\.forPathPrefixes\[0\] must be a string/);
            });

            it("rejects a non-array invalidateModules argument", function () {
                expect(function () {
                    nsModule.invalidateModules("x");
                }).toThrowError(TypeError, /invalidateModules expects an array of URL strings/);
            });

            it("rejects a non-string invalidateModules element by index", function () {
                expect(function () {
                    nsModule.invalidateModules([1]);
                }).toThrowError(TypeError, /urls\[0\] must be a string/);
            });

            it("rejects a non-string canonicalizeHttpUrlKey argument", function () {
                // Debug-only diagnostic; release builds omit the member entirely.
                if (typeof nsModule.canonicalizeHttpUrlKey !== "function") {
                    pending("canonicalizeHttpUrlKey is debug-only; absent in this build");
                    return;
                }
                expect(function () {
                    nsModule.canonicalizeHttpUrlKey(42);
                }).toThrowError(TypeError, /canonicalizeHttpUrlKey expects a URL string/);
            });

            // Validate-before-apply: the whole config is checked before any of
            // it is installed, so a call that throws leaves every section on the
            // state it already had.
            it("applies no section when any part of the config is invalid", function () {
                if (typeof nsModule.canonicalizeHttpUrlKey !== "function") {
                    pending("canonicalizeHttpUrlKey is debug-only; absent in this build");
                    return;
                }
                var url = "http://h/dev/core?p=x&t=123";
                var before = nsModule.canonicalizeHttpUrlKey(url);

                // A well-formed canonicalization section paired with a typo'd key.
                expect(function () {
                    nsModule.configureLoader({
                        canonicalization: { stripParams: ["t"], forPathPrefixes: ["/dev/"] },
                        typoKey: 1,
                    });
                }).toThrowError(TypeError, /unknown option 'typoKey'/);

                // Had the canonicalization section been applied, `t` would now
                // be stripped and the key would differ.
                expect(nsModule.canonicalizeHttpUrlKey(url)).toBe(before);
            });

            it("leaves volatilePatterns untouched when the same call throws", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var url = origin + "/esm/graph-leaf.mjs?k=vpre";
                function evaluations() {
                    return (globalThis.__nsMixedOrdervpre || []).length;
                }

                // Nothing is volatile yet, so a second import reuses the entry.
                import(url).then(function () {
                    return import(url);
                }).then(function () {
                    expect(evaluations()).toBe(1);

                    // A valid volatilePatterns alongside an unknown key: the
                    // call throws and the patterns must NOT be installed.
                    expect(function () {
                        nsModule.configureLoader({
                            volatilePatterns: ["k=vpre"],
                            typoKey: 1,
                        });
                    }).toThrowError(TypeError, /unknown option 'typoKey'/);

                    return import(url);
                }).then(function () {
                    // Still not volatile: the rejected call installed nothing.
                    expect(evaluations()).toBe(1);
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
            // The loader's per-request timeout is 30s in debug builds, 5s in
            // release, and a transport error is retried once — so the
            // rejection lands ~60s (debug) or ~10s (release) after the import,
            // beyond jasmine's default 5s spec timeout. Jasmine 2.0 has no
            // per-spec timeout argument; widen the global interval for just
            // this describe.
            var isDebugBuild =
                typeof require("ns:module").canonicalizeHttpUrlKey === "function";
            var originalTimeout;
            beforeEach(function() {
                originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
                jasmine.DEFAULT_TIMEOUT_INTERVAL = isDebugBuild ? 80000 : 15000;
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
                // delayMs must exceed the per-request timeout (30s debug /
                // 5s release) so the fetch rejects instead of completing
                // late but successfully.
                var spec = origin
                    ? (origin + "/esm/timeout.mjs?delayMs=" + (isDebugBuild ? 32000 : 12000))
                    : "http://127.0.0.1:59999/timeout-test.js";

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
        
        it("should handle malformed URLs gracefully", function(done) {
            // The loader should ignore malformed http specifiers
            var loading;
            expect(function() {
                loading = import("http://");
            }).not.toThrow();
            loading.then(function() {
                done();
            }, function(error) {
                expect(error.message).toBeDefined();
                done();
            });
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

    // A module served over HTTP resolves specifiers the way a browser does,
    // against its own URL, and reaches the filesystem only explicitly. The
    // bundled fixtures named by refused specifiers exist, so an implicit
    // filesystem fallback would have loaded them.
    describe("specifier resolution from an HTTP importer", function () {
        var nsModule = require("ns:module");

        afterEach(function () {
            nsModule.configureLoader({ importMap: { imports: {} } });
        });

        function importer(origin, dir) {
            return import(origin + "/esm/resolve/" + dir + "/importer.mjs");
        }

        function expectRefused(promise, done, check) {
            promise.then(function () {
                expect("resolved").toBe("rejected");
                done();
            }, function (error) {
                check(String((error && error.message) || error));
                done();
            });
        }

        it("resolves ./, ../, root- and scheme-relative import() against the importer's URL",
           function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var schemeRelative = origin.replace(/^https?:/, "") + "/esm/resolve/rel/scheme.mjs";
            importer(origin, "rel/dir").then(function (mod) {
                return Promise.all([
                    mod.load("./sibling.mjs"),
                    mod.load("../parent.mjs"),
                    mod.load("/esm/resolve/rel/rooted.mjs"),
                    mod.load(schemeRelative),
                ]);
            }).then(function (mods) {
                expect(mods.map(function (m) { return m.path; })).toEqual([
                    "/esm/resolve/rel/dir/sibling.mjs",
                    "/esm/resolve/rel/parent.mjs",
                    "/esm/resolve/rel/rooted.mjs",
                    "/esm/resolve/rel/scheme.mjs",
                ]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("keeps an import()'s query as part of the module's identity", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            importer(origin, "query").then(function (mod) {
                return Promise.all([mod.load("./target.mjs?k=1"), mod.load("./target.mjs?k=2")]);
            }).then(function (mods) {
                expect([mods[0].query, mods[1].query]).toEqual(["k=1", "k=2"]);
                expect(mods[0]).not.toBe(mods[1]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("refuses a static bare import the import map does not cover", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var spec = "tests/esm/http-importer/bare-static.mjs";
            expectRefused(
                import(origin + "/esm/resolve/static.mjs?spec=" + encodeURIComponent(spec)),
                done,
                function (message) {
                    expect(message).toContain("\"" + spec + "\"");
                    expect(message).toContain("not in the import map");
                    expect(globalThis.__nsHttpImporterDiskRead_bareStatic).toBeUndefined();
                });
        });

        it("refuses a dynamic bare import the import map does not cover", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var spec = "tests/esm/http-importer/bare-dynamic.mjs";
            expectRefused(importer(origin, "bare").then(function (mod) {
                return mod.load(spec);
            }), done, function (message) {
                expect(message).toContain("\"" + spec + "\"");
                expect(message).toContain(origin + "/esm/resolve/bare/importer.mjs");
                expect(message).toContain("not in the import map");
                expect(globalThis.__nsHttpImporterDiskRead_bareDynamic).toBeUndefined();
            });
        });

        it("refuses an app-relative ~/ import", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var spec = "~/tests/esm/http-importer/tilde.mjs";
            expectRefused(importer(origin, "tilde").then(function (mod) {
                return mod.load(spec);
            }), done, function (message) {
                expect(message).toContain("\"" + spec + "\"");
                expect(message).toContain("\"~/\" paths are not available");
                expect(globalThis.__nsHttpImporterDiskRead_tilde).toBeUndefined();
            });
        });

        // The fixture is written at run time: a colon in a checked-in file
        // name cannot be checked out on Windows.
        describe("with a module at the app root named like an other-scheme URL", function () {
            var spec = "x-ns-test:other-scheme.mjs";
            var fixturePath = NSBundle.mainBundle.resourcePath + "/app/" + spec;

            afterEach(function () {
                var fileManager = NSFileManager.defaultManager;
                if (fileManager.fileExistsAtPath(fixturePath)) {
                    fileManager.removeItemAtPathError(fixturePath);
                }
            });

            it("refuses the import() instead of reading the app root", function (done) {
                var origin = getHostOrigin();
                if (!origin) {
                    pending("REPORT_BASEURL not set; skipping host HTTP tests");
                    done();
                    return;
                }
                var body = "globalThis.__nsHttpImporterDiskRead_otherScheme = true;\n" +
                           "export const name = \"other-scheme\";\n";
                var data = NSString.stringWithString(body).dataUsingEncoding(NSUTF8StringEncoding);
                var written = NSFileManager.defaultManager
                    .createFileAtPathContentsAttributes(fixturePath, data, null);
                expect(written).toBe(true);
                expect(NSFileManager.defaultManager.fileExistsAtPath(fixturePath)).toBe(true);
                expectRefused(importer(origin, "other-scheme").then(function (mod) {
                    return mod.load(spec);
                }), done, function (message) {
                    expect(message).toContain(spec);
                    expect(globalThis.__nsHttpImporterDiskRead_otherScheme).toBeUndefined();
                });
            });
        });

        it("imports a builtin", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            importer(origin, "builtin").then(function (mod) {
                return mod.load("ns:module");
            }).then(function (ns) {
                expect(ns.createRequire).toBe(nsModule.createRequire);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("imports a bundled module named by an explicit file:// URL", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            importer(origin, "file-url").then(function (mod) {
                return mod.load("file:///app/tests/esm/http-importer/file-url.mjs");
            }).then(function (ns) {
                expect(ns.name).toBe("file-url");
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("imports a bare specifier through its import-map entry, whatever the target",
           function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            nsModule.configureLoader({
                importMap: {
                    imports: { "ns-http-importer-mapped": "~/tests/esm/http-importer/mapped.mjs" },
                },
            });
            importer(origin, "mapped").then(function (mod) {
                return mod.load("ns-http-importer-mapped");
            }).then(function (ns) {
                expect(ns.name).toBe("mapped");
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("resolves a relative import-map target against the importer's URL", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            nsModule.configureLoader({
                importMap: { imports: { "ns-http-importer-relative": "./mapped-target.mjs?k=map" } },
            });
            Promise.all([
                importer(origin, "map-relative").then(function (mod) {
                    return mod.load("ns-http-importer-relative");
                }),
                import(origin + "/esm/resolve/static.mjs?spec=ns-http-importer-relative"),
            ]).then(function (namespaces) {
                expect([namespaces[0].path, namespaces[0].query])
                    .toEqual(["/esm/resolve/map-relative/mapped-target.mjs", "k=map"]);
                expect([namespaces[1].dep.path, namespaces[1].dep.query])
                    .toEqual(["/esm/resolve/mapped-target.mjs", "k=map"]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("imports a blob:nativescript URL", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            // The bare test realm has no Blob; createObjectURL needs an
            // instance carrying `type`, and the loader only calls `.text()`.
            var previousBlob = globalThis.Blob;
            globalThis.Blob = function Blob(parts, options) {
                this._text = (parts || []).join("");
                this.type = (options && options.type) || "";
            };
            globalThis.Blob.prototype.text = function () {
                return Promise.resolve(this._text);
            };
            var url = URL.createObjectURL(
                new Blob(["export const name = 'http-importer-blob';\n"],
                         { type: "text/javascript" }),
                { ext: ".mjs" });
            function cleanUp() {
                URL.revokeObjectURL(url);
                if (typeof previousBlob === "undefined") {
                    delete globalThis.Blob;
                } else {
                    globalThis.Blob = previousBlob;
                }
            }
            importer(origin, "blob").then(function (mod) {
                return mod.load(url);
            }).then(function (ns) {
                cleanUp();
                expect(ns.name).toBe("http-importer-blob");
                done();
            }).catch(function (error) {
                cleanUp();
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        function rejectionMessage(promise) {
            return promise.then(function () {
                return "resolved";
            }, function (error) {
                return String((error && error.message) || error);
            });
        }

        it("stays an HTTP importer when the import map maps its own URL to a file",
           function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var importerUrl = origin + "/esm/resolve/self-mapped/importer.mjs";
            var mod;
            import(importerUrl).then(function (loaded) {
                mod = loaded;
                var imports = {};
                imports[importerUrl] = "~/tests/esm/http-importer/self-mapped.mjs";
                nsModule.configureLoader({ importMap: { imports: imports } });
                return mod.load("./target.mjs?k=self");
            }).then(function (target) {
                expect([target.path, target.query])
                    .toEqual(["/esm/resolve/self-mapped/target.mjs", "k=self"]);
                return rejectionMessage(mod.load("tests/esm/http-importer/self-mapped-bare.mjs"));
            }).then(function (bareMessage) {
                expect(bareMessage).toContain("not in the import map");
                return rejectionMessage(mod.load("~/tests/esm/http-importer/self-mapped-tilde.mjs"));
            }).then(function (tildeMessage) {
                expect(tildeMessage).toContain("\"~/\" paths are not available");
                expect(globalThis.__nsHttpImporterDiskRead_selfMappedBare).toBeUndefined();
                expect(globalThis.__nsHttpImporterDiskRead_selfMappedTilde).toBeUndefined();
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("refuses a static import of a dot-prefixed bare specifier", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var spec = ".hidden/dep.mjs";
            expectRefused(
                import(origin + "/esm/resolve/static.mjs?spec=" + encodeURIComponent(spec)),
                done,
                function (message) {
                    expect(message).toContain("\"" + spec + "\"");
                    expect(message).toContain("not in the import map");
                });
        });

        it("refuses a dynamic import of '.x', '.' and '..' as bare specifiers", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            importer(origin, "dot-bare/dir").then(function (mod) {
                return Promise.all([".hidden/dynamic.mjs", ".", ".."].map(function (spec) {
                    return rejectionMessage(mod.load(spec));
                }));
            }).then(function (messages) {
                messages.forEach(function (message) {
                    expect(message).toContain("not in the import map");
                });
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        // `new URL()` and the loader share the WHATWG URL parser, so every
        // spelling of one URL names one module.
        it("imports one module for every spelling of its URL from import()", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var importerUrl = origin + "/esm/resolve/identity/importer.mjs";
            import(importerUrl).then(function (mod) {
                return Promise.all([
                    mod.load("./x.mjs?v=1"),
                    mod.load("./sub/../x.mjs?v=1"),
                    mod.load("/esm/resolve/identity/./x.mjs?v=1"),
                    import(origin + "/esm/resolve/identity/x.mjs?v=1"),
                    import(new URL("./x.mjs?v=1", importerUrl).href),
                ]);
            }).then(function (namespaces) {
                expect(namespaces[0].query).toBe("v=1");
                namespaces.forEach(function (ns) {
                    expect(ns).toBe(namespaces[0]);
                });
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("imports one module for every spelling of its URL from a static import", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            function staticImporter(spec) {
                return import(origin + "/esm/resolve/static.mjs?spec=" + encodeURIComponent(spec));
            }
            Promise.all([
                staticImporter("./identity-static/x.mjs?v=1"),
                staticImporter("/esm/resolve/identity-static/./x.mjs?v=1"),
                import(origin + "/esm/resolve/identity-static/x.mjs?v=1"),
            ]).then(function (namespaces) {
                expect(namespaces[2].query).toBe("v=1");
                expect(namespaces[0].dep).toBe(namespaces[2]);
                expect(namespaces[1].dep).toBe(namespaces[2]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        // `LOCALHOST` reaches the same server as the canonical origin but is
        // spelled the way the parser would not spell it.
        it("keeps the importer's origin as written in the URLs it resolves", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var written = origin.replace("127.0.0.1", "LOCALHOST");
            var childUrl = written + "/esm/resolve/authority/x.mjs";
            var direct;
            import(childUrl).then(function (ns) {
                direct = ns;
                return Promise.all([
                    importer(written, "authority").then(function (mod) {
                        return Promise.all([
                            mod.load("./x.mjs"),
                            mod.load("/esm/resolve/authority/x.mjs"),
                        ]);
                    }),
                    import(written + "/esm/resolve/authority/static.mjs?spec=" +
                           encodeURIComponent("./x.mjs")),
                    importer(origin, "authority-own").then(function (mod) {
                        return Promise.all([
                            mod.load(childUrl.replace(/^http:/, "")),
                            mod.load(childUrl.replace(/^http:/, "HTTP:")),
                        ]);
                    }),
                ]);
            }).then(function (results) {
                expect(results[0][0]).toBe(direct);
                expect(results[0][1]).toBe(direct);
                expect(results[1].dep).toBe(direct);
                expect(results[2][0]).toBe(direct);
                expect(results[2][1]).toBe(direct);
                expect(direct.url).toBe(childUrl);
                expect(nsModule.getLoadedModuleUrls()).toContain(childUrl);
                nsModule.invalidateModules([childUrl]);
                expect(nsModule.getLoadedModuleUrls()).not.toContain(childUrl);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("keeps the importer's origin as written when the query or fragment is empty",
           function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var written = origin.replace("127.0.0.1", "LOCALHOST");
            importer(written, "authority-empty").then(function (mod) {
                return Promise.all([mod.load("./query.mjs?"), mod.load("./hash.mjs#")]);
            }).then(function (mods) {
                expect(mods[0].url).toBe(written + "/esm/resolve/authority-empty/query.mjs?");
                expect(mods[1].url).toBe(written + "/esm/resolve/authority-empty/hash.mjs");
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("normalizes a specifier the way the WHATWG URL parser does", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            importer(origin, "norm").then(function (mod) {
                return Promise.all([
                    mod.load("/esm/resolve/norm/./a/../dots.mjs"),
                    mod.load("../../../../../esm/resolve/norm/climb.mjs"),
                    mod.load("./sub\\back.mjs"),
                    mod.load(origin.replace(/^http:/, "HTTP:") + "/esm/resolve/norm/upper.mjs"),
                ]);
            }).then(function (mods) {
                expect(mods.map(function (m) { return m.path; })).toEqual([
                    "/esm/resolve/norm/dots.mjs",
                    "/esm/resolve/norm/climb.mjs",
                    "/esm/resolve/norm/sub/back.mjs",
                    "/esm/resolve/norm/upper.mjs",
                ]);
                expect(mods[3].url).toBe(origin + "/esm/resolve/norm/upper.mjs");
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });
    });

    describe("an import-map entry keyed by a file module's own URL", function () {
        var nsModule = require("ns:module");

        afterEach(function () {
            nsModule.configureLoader({ importMap: { imports: {} } });
        });

        // `mapKey` derives the entry key from the loaded module's own URL; the
        // entry points at the test server.
        function expectStaysFileImporter(dir, mapKey, done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            import("~/tests/esm/" + dir + "/local.mjs").then(function (mod) {
                var imports = {};
                var key = mapKey(mod.url);
                imports[key] = origin + "/esm/resolve/" + dir + "/" +
                               (key.charAt(key.length - 1) === "/" ? "" : "local.mjs");
                nsModule.configureLoader({ importMap: { imports: imports } });
                return Promise.all([
                    mod.load("~/tests/esm/" + dir + "/tilde-dep.mjs"),
                    mod.load("tests/esm/" + dir + "/bare-dep.mjs"),
                    mod.load("./sibling.mjs"),
                ]);
            }).then(function (namespaces) {
                expect(namespaces.map(function (ns) { return ns.name; })).toEqual([
                    dir + "-tilde",
                    dir + "-bare",
                    dir + "-sibling",
                ]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        }

        it("leaves an exact entry out of the module's import() resolution", function (done) {
            expectStaysFileImporter("self-mapped-file", function (url) {
                return url;
            }, done);
        });

        it("leaves a prefix entry out of the module's import() resolution", function (done) {
            expectStaysFileImporter("self-mapped-prefix", function (url) {
                return url.substring(0, url.lastIndexOf("/") + 1);
            }, done);
        });
    });

    describe("import-map lookup of a query from a file module", function () {
        var nsModule = require("ns:module");

        afterEach(function () {
            nsModule.configureLoader({ importMap: { imports: {} } });
        });

        it("looks a static import's query up in the map and drops an import()'s", function (done) {
            nsModule.configureLoader({
                importMap: {
                    imports: {
                        "ns-query-map-pkg": "~/tests/esm/query-map/stripped.mjs",
                        "ns-query-map-pkg?x": "~/tests/esm/query-map/literal.mjs",
                    },
                },
            });
            Promise.all([
                import("~/tests/esm/query-map/static-importer.mjs"),
                import("ns-query-map-pkg?x"),
            ]).then(function (namespaces) {
                expect(namespaces[0].dep.name).toBe("literal");
                expect(namespaces[1].name).toBe("stripped");
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
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

    // The spelling of these URLs is what dev tooling compares module URLs
    // against, so it must survive every route into the loader byte for byte.
    describe("module URLs in the shapes dev tooling emits", function () {
        var nsModule = require("ns:module");

        afterEach(function () {
            nsModule.configureLoader({ importMap: { imports: {} } });
        });

        // Each module reports the request target the server saw and its own
        // import.meta.url.
        function expectSpelledAsWritten(ns, url) {
            var target = url.slice(url.indexOf("/", url.indexOf("://") + 3));
            var q = target.indexOf("?");
            expect(ns.url).toBe(url);
            expect(ns.path).toBe(q < 0 ? target : target.slice(0, q));
            expect(ns.query).toBe(q < 0 ? "" : target.slice(q + 1));
            expect(nsModule.getLoadedModuleUrls()).toContain(url);
        }

        function expectEvicted(urls) {
            nsModule.invalidateModules(urls);
            var loaded = nsModule.getLoadedModuleUrls();
            urls.forEach(function (url) {
                expect(loaded).not.toContain(url);
            });
        }

        it("keeps them as written when a file module imports them", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var written = origin.replace("127.0.0.1", "LOCALHOST");
            var base = origin + "/esm/resolve/tooling-direct";
            var urls = [
                base + "/ns/m/src/app.ts?v=abc",
                base + "/ns/core/index.js",
                base + "/ns/node/x",
                base + "/ns/m/node_modules/pkg/index.js",
                base + "/ns/asm?path=%2Fsrc%2FApp.vue&mode=inline",
                base + "/ns/asm?path=/src/App.vue&mode=inline",
                base + "/ns/sfc/src/App.vue?vue&type=script",
                base + "/ns/m/q.js?b=2&a=1",
                base + "/@ng/component?c=x&t=1",
                base + "/@id/__x00__virtual:thing",
                base + "/@fs/Users/me/proj/x.ts",
                written + "/esm/resolve/tooling-direct/ns/m/upper.js?v=1",
            ];
            Promise.all(urls.map(function (url) {
                return import(url);
            })).then(function (namespaces) {
                namespaces.forEach(function (ns, i) {
                    expectSpelledAsWritten(ns, urls[i]);
                });
                expectEvicted(urls);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
                done();
            });
        });

        it("keeps them as written when an import-map entry targets them", function (done) {
            var origin = getHostOrigin();
            if (!origin) {
                pending("REPORT_BASEURL not set; skipping host HTTP tests");
                done();
                return;
            }
            var written = origin.replace("127.0.0.1", "LOCALHOST");
            var base = origin + "/esm/resolve/tooling-mapped";
            var dynamicUrl = base + "/ns/m/src/dynamic.ts?v=abc";
            var staticUrl = base + "/ns/asm?path=%2Fsrc%2FApp.vue&mode=inline";
            var upperUrl = written + "/esm/resolve/tooling-mapped/ns/m/upper.js?b=2&a=1";
            nsModule.configureLoader({
                importMap: {
                    imports: {
                        "ns-tooling-url-dynamic": dynamicUrl,
                        "ns-tooling-url-static": staticUrl,
                        "ns-tooling-url-upper": upperUrl,
                    },
                },
            });
            Promise.all([
                import("ns-tooling-url-dynamic"),
                import("~/tests/esm/tooling-url/static-importer.mjs"),
                import("ns-tooling-url-upper"),
            ]).then(function (namespaces) {
                expectSpelledAsWritten(namespaces[0], dynamicUrl);
                expectSpelledAsWritten(namespaces[1].dep, staticUrl);
                expectSpelledAsWritten(namespaces[2], upperUrl);
                expectEvicted([dynamicUrl, staticUrl, upperUrl]);
                done();
            }).catch(function (error) {
                expect("rejected: " + formatError(error)).toBe("resolved");
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

    // A registered key is canonicalized again whenever it is looked up, so a key
    // must be a fixed point.
    function checkKey(input, expected) {
        var canon = getCanon();
        if (typeof canon !== "function") {
            pending("ns:module.canonicalizeHttpUrlKey not exposed (release build)");
            return;
        }
        expect(canon(input)).toBe(expected);
        expect(canon(expected)).toBe(expected);
    }

    // [input, key with no vocabulary, key under TOOLING_VOCABULARY]
    var TOOLING_URLS = [
        ["http://h:5173/ns/m/src/app.ts?v=abc",
         "http://h:5173/ns/m/src/app.ts?v=abc",
         "http://h:5173/ns/m/src/app.ts"],
        ["http://h:5173/ns/core/index.js",
         "http://h:5173/ns/core/index.js",
         "http://h:5173/ns/core/index.js"],
        ["http://h:5173/ns/node/x",
         "http://h:5173/ns/node/x",
         "http://h:5173/ns/node/x"],
        ["http://h:5173/ns/m/node_modules/pkg/index.js?v=abc",
         "http://h:5173/ns/m/node_modules/pkg/index.js?v=abc",
         "http://h:5173/ns/m/node_modules/pkg/index.js"],
        ["http://h:5173/ns/asm?path=%2Fsrc%2FApp.vue&mode=inline",
         "http://h:5173/ns/asm?path=%2Fsrc%2FApp.vue&mode=inline",
         "http://h:5173/ns/asm?mode=inline&path=%2Fsrc%2FApp.vue"],
        ["http://h:5173/ns/asm?path=/src/App.vue&mode=inline",
         "http://h:5173/ns/asm?path=/src/App.vue&mode=inline",
         "http://h:5173/ns/asm?mode=inline&path=/src/App.vue"],
        ["http://h:5173/ns/sfc/src/App.vue?vue&type=script",
         "http://h:5173/ns/sfc/src/App.vue?vue&type=script",
         "http://h:5173/ns/sfc/src/App.vue?type=script&vue"],
        ["http://h:5173/ns/m/q.js?b=2&a=1",
         "http://h:5173/ns/m/q.js?b=2&a=1",
         "http://h:5173/ns/m/q.js?a=1&b=2"],
        ["http://h:5173/@ng/component?c=x&t=1",
         "http://h:5173/@ng/component?c=x&t=1",
         "http://h:5173/@ng/component?c=x&t=1"],
        ["http://h:5173/@id/__x00__virtual:thing?import",
         "http://h:5173/@id/__x00__virtual:thing?import",
         "http://h:5173/@id/__x00__virtual:thing"],
        ["http://h:5173/@fs/Users/me/proj/x.ts?t=1",
         "http://h:5173/@fs/Users/me/proj/x.ts?t=1",
         "http://h:5173/@fs/Users/me/proj/x.ts"],
        ["http://h:5173/node_modules/.vite/deps/pkg.js?v=abc",
         "http://h:5173/node_modules/.vite/deps/pkg.js?v=abc",
         "http://h:5173/node_modules/.vite/deps/pkg.js"],
        ["http://MyMac.local:5173/ns/m/app.js?v=1",
         "http://MyMac.local:5173/ns/m/app.js?v=1",
         "http://MyMac.local:5173/ns/m/app.js"],
        ["http://MyMac.local:5173/ns/m/app.js?",
         "http://MyMac.local:5173/ns/m/app.js?",
         "http://MyMac.local:5173/ns/m/app.js"],
        ["http://MyMac.local:5173/ns/m/app.js#",
         "http://MyMac.local:5173/ns/m/app.js",
         "http://MyMac.local:5173/ns/m/app.js"],
        ["http://h:80/ns/m/app.js?v=1",
         "http://h:80/ns/m/app.js?v=1",
         "http://h:80/ns/m/app.js"],
        ["http://192.168.1.20:5173/ns/m/app.js?v=1",
         "http://192.168.1.20:5173/ns/m/app.js?v=1",
         "http://192.168.1.20:5173/ns/m/app.js"],
        ["http://[::1]:5173/ns/m/app.js?v=1",
         "http://[::1]:5173/ns/m/app.js?v=1",
         "http://[::1]:5173/ns/m/app.js"],
        // The URL parser rejects a zone id; the key keeps the URL as written.
        ["http://[fe80::1%25en0]:5173/ns/m/app.js?v=1#x",
         "http://[fe80::1%25en0]:5173/ns/m/app.js?v=1",
         "http://[fe80::1%25en0]:5173/ns/m/app.js"],
    ];

    var TOOLING_VOCABULARY = {
        stripParams: ["t", "v", "import"],
        forPathPrefixes: ["/ns/", "/@id/", "/@fs/", "/node_modules/.vite/"],
        preserveQueryFor: ["/@ng/component"],
    };

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

        // Upstream path joins collapse `http://` to `http:/`. Every key
        // derivation repairs that before it tests the scheme, so a key that
        // arrives collapsed — through invalidateModules or a cache-bust mark —
        // lands on the same identity the resolver produces.
        it("repairs a collapsed scheme to one identity", function () {
            checkKey("http:/h/ns/core", "http://h/ns/core");
            checkKey("https:/h/ns/core", "https://h/ns/core");
            // Already well-formed keys are untouched by the repair.
            checkKey("http://h/ns/core", "http://h/ns/core");
        });

        // Some loaders hand the URL over wrapped as file://http(s)://…, and a
        // path join can collapse the scheme inside that wrapper too. Unwrapping
        // and repairing have to compose, or the wrapped-collapsed form becomes
        // a third identity for the same module.
        it("repairs a collapsed scheme inside a file:// wrapper", function () {
            checkKey("file://http:/h/ns/core", "http://h/ns/core");
            checkKey("file://https:/h/ns/core", "https://h/ns/core");
            // The well-formed wrapper still unwraps to the same key.
            checkKey("file://http://h/ns/core", "http://h/ns/core");
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

        it("keeps the URLs dev tooling emits as written", function () {
            TOOLING_URLS.forEach(function (row) {
                checkKey(row[0], row[1]);
            });
        });
    });

    describe("with a tooling-shaped vocabulary", function () {
        beforeEach(function () {
            var nsModule = require("ns:module");
            if (typeof nsModule.canonicalizeHttpUrlKey !== "function") {
                return;
            }
            nsModule.configureLoader({ canonicalization: TOOLING_VOCABULARY });
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

        it("keys the URLs dev tooling emits", function () {
            TOOLING_URLS.forEach(function (row) {
                checkKey(row[0], row[2]);
            });
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