describe("interop.escapeException and boundary hardening", function () {
    // Several tests drive an unhandled/reported error through the uncaught path,
    // which ends in the __onUncaughtError shim (unless a listener prevents it).
    // Spy on it and restore the previous hook afterwards.
    let previousHook;
    let uncaught;

    beforeEach(function () {
        previousHook = global.__onUncaughtError;
        uncaught = [];
        global.__onUncaughtError = function (error) {
            uncaught.push(error);
        };
    });

    afterEach(function () {
        global.__onUncaughtError = previousHook;
    });

    function uncaughtSeen(substr) {
        for (let i = 0; i < uncaught.length; i++) {
            const e = uncaught[i];
            const msg = e && e.message !== undefined ? String(e.message) : String(e);
            if (msg.indexOf(substr) > -1) {
                return true;
            }
        }
        return false;
    }

    function pollUntil(predicate, cb) {
        let turns = 0;
        (function poll() {
            if (predicate() || turns >= 25) {
                cb();
                return;
            }
            turns++;
            setTimeout(poll, 10);
        })();
    }

    describe("interop.escapeException()", function () {
        it("returns a throwable Error preserving the message", function () {
            const wrapped = interop.escapeException(new Error("boom"));
            expect(wrapped instanceof Error).toBe(true);
            expect(wrapped.message).toBe("boom");

            let caught = null;
            try {
                throw wrapped;
            } catch (e) {
                caught = e;
            }
            expect(caught).toBe(wrapped);
        });

        it("throws TypeError when called with no arguments", function () {
            expect(function () {
                interop.escapeException();
            }).toThrowError(TypeError);
        });

        it("is idempotent (double-wrap returns the same object)", function () {
            const once = interop.escapeException(new Error("once"));
            const twice = interop.escapeException(once);
            expect(twice).toBe(once);
        });
    });

    describe("escaping through a native-invoked block", function () {
        it("a branded escape surfaces to native as an NSException; JS keeps running", function () {
            const ex = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                throw interop.escapeException(new Error("escape-me"));
            });

            expect(ex).not.toBeNull();
            expect(ex instanceof NSException).toBe(true);
            expect(ex.reason).toContain("escape-me");

            // JS is still alive after the escape round-trip.
            expect(1 + 1).toBe(2);
        });

        it("a plain Error is not escaped as an NSException; it surfaces as a normal JS throw", function () {
            // The whole chain is JS-initiated, so an unbranded plain error thrown
            // in the block propagates back to this JS caller (correct exception
            // semantics) rather than becoming an ObjC NSException — and it does
            // not abort the process.
            let caught = null;
            let ret;
            try {
                ret = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                    throw new Error("plain-no-escape");
                });
            } catch (e) {
                caught = e;
            }

            expect(caught).not.toBeNull();
            expect(caught.message).toBe("plain-no-escape");
            expect(caught instanceof NSException).toBe(false);
            // The fixture never caught an NSException, so it never returned one.
            expect(ret).toBeUndefined();
        });

        it("round-trips an original native NSException back to native", function () {
            let caughtInJs = null;
            try {
                NSArray.alloc().init().objectAtIndex(3);
            } catch (e) {
                caughtInJs = e;
            }
            expect(caughtInJs).not.toBeNull();
            expect(caughtInJs.nativeException instanceof NSException).toBe(true);

            const ex = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                throw interop.escapeException(caughtInJs);
            });

            expect(ex).not.toBeNull();
            expect(ex instanceof NSException).toBe(true);
            expect(ex.name).toBe("NSRangeException");
            expect(ex.reason).toContain("beyond bounds");
        });
    });

    describe("JS stack travels with escaped exceptions", function () {
        // Named functions so the captured JS stack contains recognizable tokens
        // regardless of how the module's script name is rendered in a frame.
        function escapeSiteMarker(makeThrow) {
            makeThrow();
        }

        it("a synthesized escape carries the JS stack in userInfo and via the category", function () {
            const ex = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                escapeSiteMarker(function throwSynthesizedEscape() {
                    throw interop.escapeException(new Error("synth-with-stack"));
                });
            });

            expect(ex).not.toBeNull();
            expect(ex instanceof NSException).toBe(true);

            // userInfo carries the origin JS stack under the documented key.
            const userInfoStack = ex.userInfo ? ex.userInfo.objectForKey("JavaScriptStack") : null;
            expect(userInfoStack).not.toBeNull();
            expect(String(userInfoStack)).toContain("throwSynthesizedEscape");

            // The category (associated-object) accessor returns the same/similar text.
            const viaCategory = TNSTestNativeCallbacks.jsStackTraceForException(ex);
            expect(viaCategory).not.toBeNull();
            expect(String(viaCategory)).toContain("throwSynthesizedEscape");
        });

        it("a non-Error escape still produces an escape-site stack via the category", function () {
            const ex = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                escapeSiteMarker(function throwPlainStringEscape() {
                    throw interop.escapeException("plain-string");
                });
            });

            expect(ex).not.toBeNull();
            expect(ex instanceof NSException).toBe(true);

            const viaCategory = TNSTestNativeCallbacks.jsStackTraceForException(ex);
            expect(viaCategory).not.toBeNull();
            expect(String(viaCategory).length).toBeGreaterThan(0);
            expect(String(viaCategory)).toContain("throwPlainStringEscape");
        });

        it("an original native NSException round-trips unchanged but carries a JS stack via the category", function () {
            let caughtInJs = null;
            try {
                NSArray.alloc().init().objectAtIndex(3);
            } catch (e) {
                caughtInJs = e;
            }
            expect(caughtInJs).not.toBeNull();
            expect(caughtInJs.nativeException instanceof NSException).toBe(true);

            const ex = TNSTestNativeCallbacks.invokeBlockCatchingException(function () {
                escapeSiteMarker(function rethrowOriginalNativeException() {
                    throw interop.escapeException(caughtInJs);
                });
            });

            // The original native exception reaches native unchanged.
            expect(ex).not.toBeNull();
            expect(ex instanceof NSException).toBe(true);
            expect(ex.name).toBe("NSRangeException");
            expect(ex.reason).toContain("beyond bounds");

            // Identity preserved: no JavaScriptStack key was injected into userInfo.
            const userInfoStack = ex.userInfo ? ex.userInfo.objectForKey("JavaScriptStack") : null;
            expect(userInfoStack).toBeNull();

            // ...but the associated-object stack is now available via the category,
            // proving attachment without mutating the exception.
            const viaCategory = TNSTestNativeCallbacks.jsStackTraceForException(ex);
            expect(viaCategory).not.toBeNull();
            expect(String(viaCategory).length).toBeGreaterThan(0);
            expect(String(viaCategory)).toContain("rethrowOriginalNativeException");
        });
    });

    describe("adapter boundary hardening (no process abort on JS throw)", function () {
        it("a throwing getter read through the DictionaryAdapter yields a default, reports, and does not crash", function (done) {
            const jsObject = {
                get boom() {
                    throw new Error("dict-adapter-boom");
                }
            };

            const value = TNSTestNativeCallbacks.dictionaryValueForKeyKey(jsObject, "boom");
            // Native received a default (nil) instead of the process aborting.
            expect(value).toBeNull();

            pollUntil(function () { return uncaughtSeen("dict-adapter-boom"); }, function () {
                expect(uncaughtSeen("dict-adapter-boom")).toBe(true);
                done();
            });
        });

        it("a throwing overridden property getter read from native does not crash and is reported", function (done) {
            // baseProperty uses the default getter selector (KVC-accessible),
            // unlike TNSApi.property which has a custom getter.
            const Derived = TNSDerivedInterface.extend({
                get baseProperty() {
                    throw new Error("getter-adapter-boom");
                }
            });
            const instance = Derived.alloc().init();

            // Reading the overridden getter from native must not abort the process
            // and must not propagate (the hardened ClassBuilder accessor reports
            // the unbranded error and returns a default value).
            let threw = false;
            try {
                TNSTestNativeCallbacks.objectValueForKeyKey(instance, "baseProperty");
            } catch (e) {
                threw = true;
            }
            expect(threw).toBe(false);

            pollUntil(function () { return uncaughtSeen("getter-adapter-boom"); }, function () {
                expect(uncaughtSeen("getter-adapter-boom")).toBe(true);
                done();
            });
        });
    });

    // manual: uncaughtErrorPolicy "throw" is not exercised automatically because
    // its terminal case (a real crash) would kill the test runner, and the policy
    // cannot be toggled at runtime (GetAppConfigValue caches, and flipping it
    // would break every other spec). The whole suite staying green under the
    // default "report" policy is itself the pin that the claim-slot machinery is
    // inert when the policy is off.
    //
    // To smoke it manually, set { "uncaughtErrorPolicy": "throw" } in the app
    // config, then:
    //
    // 1. BOUNDARY-ORIGINATED, reported SYNCHRONOUSLY (catchable — Android parity):
    //    boundaries that report inside their own frame via HandleBoundaryException
    //    — overridden property getters/setters and DictionaryAdapter reads invoked
    //    from native — rethrow the NSException at that boundary after scope
    //    teardown. A native @try/@catch wrapping that native access catches it.
    //    (The existing "throwing overridden getter"/"throwing DictionaryAdapter"
    //    specs above drive exactly these boundaries; under "throw" the read would
    //    surface a NativeScriptFatalJSException instead of a nil default.)
    //
    //    IMPORTANT LIMITATION (verified empirically): the native→JS block /
    //    overridden-method boundary (ArgConverter::MethodCallback, e.g.
    //    invokeBlockCatchingException) does NOT get a synchronous rethrow. It uses
    //    tc.ReThrow(), so an unbranded plain Error is surfaced to V8 as a pending
    //    exception and is caught in JS up-stack (or reported later at an uncaught
    //    Invoke), never during the block's own frame. A native @try/@catch around
    //    invokeBlockCatchingException therefore does NOT catch a plain Error under
    //    "throw" — it still surfaces to JS. Use interop.escapeException(err) to
    //    force a synchronous native @throw at that boundary regardless of policy.
    //
    // 2. LOOP-ORIGINATED (deferred clean-frame throw): an uncaught error in a
    //    setTimeout callback has no originating boundary to claim it, so it is
    //    thrown from a clean, scope-free frame on the runtime loop and terminates
    //    the app (nothing catches it) with a NativeScriptFatalJSException crash
    //    report:
    //
    //      setTimeout(() => { throw new Error("policy-throw-timer"); }, 0);
    //
    // Default-off behavior (report + continue) is covered by every other suite
    // here.
});
