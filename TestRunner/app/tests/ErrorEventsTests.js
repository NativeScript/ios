describe("WHATWG error events", function () {
    // Many tests exercise the global error/rejection path, which ends in the
    // __onUncaughtError shim when a listener does not preventDefault(). Install a
    // spy for every test and restore the previous hook in afterEach. Also track
    // listeners added on the global target so they never leak into other suites
    // (the internal EventTarget backing the global is process-wide).
    let previousHook;
    let uncaught;
    let addedGlobalListeners;

    beforeEach(function () {
        previousHook = global.__onUncaughtError;
        uncaught = [];
        global.__onUncaughtError = function (error) {
            uncaught.push(error);
        };
        addedGlobalListeners = [];
    });

    afterEach(function () {
        global.__onUncaughtError = previousHook;
        for (let i = 0; i < addedGlobalListeners.length; i++) {
            const l = addedGlobalListeners[i];
            global.removeEventListener(l.type, l.handler);
        }
        addedGlobalListeners = [];
    });

    function onGlobal(type, handler) {
        global.addEventListener(type, handler);
        addedGlobalListeners.push({ type: type, handler: handler });
    }

    // Poll across a few runloop turns until `predicate` is true (or give up).
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

    // Wait a couple of quiet runloop turns before asserting a NON-event.
    function afterQuietTurns(cb) {
        setTimeout(function () {
            setTimeout(cb, 25);
        }, 25);
    }

    it("reportError fires an 'error' listener with an ErrorEvent carrying error and message", function (done) {
        const err = new Error("x");
        let received = null;
        onGlobal("error", function (e) {
            received = e;
            e.preventDefault();
        });

        global.reportError(err);

        expect(received).not.toBeNull();
        expect(received instanceof ErrorEvent).toBe(true);
        expect(received.type).toBe("error");
        expect(received.error).toBe(err);
        expect(received.message).toBe("x");
        // preventDefault() in the listener must suppress the __onUncaughtError shim for
        // THIS error. Assert on the specific error rather than uncaught.length: the shim is
        // process-global and other specs' async errors/rejections can drain into it during
        // these quiet turns, so a bare length===0 is flaky in the full suite.
        afterQuietTurns(function () {
            expect(uncaught).not.toContain(err);
            done();
        });
    });

    it("reportError without preventDefault still invokes __onUncaughtError (back-compat)", function (done) {
        const err = new Error("back-compat");
        let received = null;
        onGlobal("error", function (e) {
            received = e;
        });

        global.reportError(err);

        expect(received).not.toBeNull();
        expect(received.error).toBe(err);
        expect(uncaught.length).toBe(1);
        expect(uncaught[0]).toBe(err);
        done();
    });

    it("reportError throws TypeError when called with no arguments", function () {
        expect(function () {
            global.reportError();
        }).toThrowError(TypeError);
    });

    it("unhandledrejection listener receives reason and promise; preventDefault suppresses the shim", function (done) {
        const reason = new Error("rejected");
        let received = null;
        onGlobal("unhandledrejection", function (e) {
            received = e;
            e.preventDefault();
        });

        Promise.reject(reason);

        pollUntil(function () { return received !== null; }, function () {
            expect(received).not.toBeNull();
            expect(received instanceof PromiseRejectionEvent).toBe(true);
            expect(received.type).toBe("unhandledrejection");
            expect(received.reason).toBe(reason);
            expect(typeof received.promise.then).toBe("function");
            // Assert THIS rejection was suppressed, not uncaught.length===0 — the shim is
            // process-global and unrelated async errors drain into it during quiet turns.
            afterQuietTurns(function () {
                expect(uncaught).not.toContain(reason);
                done();
            });
        });
    });

    it("an unhandled rejection with no listener still reaches __onUncaughtError", function (done) {
        const reason = new Error("no-listener-rejection");
        Promise.reject(reason);

        pollUntil(function () { return uncaught.length > 0; }, function () {
            expect(uncaught.length).toBeGreaterThan(0);
            expect(uncaught[0]).toBe(reason);
            done();
        });
    });

    it("fires rejectionhandled when a handler is attached after the rejection was reported", function (done) {
        const reason = new Error("late-handler");
        let rejectionHandled = null;
        onGlobal("rejectionhandled", function (e) {
            rejectionHandled = e;
        });
        // Prevent the report so it does not hit the shim; the promise still counts
        // as reported and becomes outstanding for rejectionhandled purposes.
        // Capture the promise carried by the unhandledrejection event: the runtime
        // events carry the underlying V8 promise (the PromiseProxy wrapper the
        // user holds is a different object), so "same promise" is verified by
        // comparing the two events' promise, which must be identical.
        let reportedPromise = null;
        onGlobal("unhandledrejection", function (e) {
            reportedPromise = e.promise;
            e.preventDefault();
        });

        const p = Promise.reject(reason);

        pollUntil(function () { return reportedPromise !== null; }, function () {
            // Attach a late handler a couple turns after the report.
            setTimeout(function () {
                p.catch(function () {});
                pollUntil(function () { return rejectionHandled !== null; }, function () {
                    expect(rejectionHandled).not.toBeNull();
                    expect(rejectionHandled instanceof PromiseRejectionEvent).toBe(true);
                    expect(rejectionHandled.type).toBe("rejectionhandled");
                    expect(typeof rejectionHandled.promise.then).toBe("function");
                    expect(rejectionHandled.promise).toBe(reportedPromise);
                    // The original rejection reason is retained past reporting
                    // and carried on the rejectionhandled event, per spec.
                    expect(rejectionHandled.reason).toBe(reason);
                    done();
                });
            }, 20);
        });
    });

    describe("constructors and EventTarget semantics", function () {
        it("Event is spec-sane and cancelable via preventDefault", function () {
            const e = new Event("x", { cancelable: true });
            expect(e.type).toBe("x");
            expect(e.cancelable).toBe(true);
            expect(e.bubbles).toBe(false);
            expect(e.defaultPrevented).toBe(false);
            e.preventDefault();
            expect(e.defaultPrevented).toBe(true);
        });

        it("a non-cancelable Event ignores preventDefault", function () {
            const e = new Event("x");
            e.preventDefault();
            expect(e.defaultPrevented).toBe(false);
        });

        it("ErrorEvent exposes message/error/filename/lineno/colno", function () {
            const err = new Error("boom");
            const e = new ErrorEvent("error", { message: "m", error: err });
            expect(e instanceof Event).toBe(true);
            expect(e.message).toBe("m");
            expect(e.error).toBe(err);
            expect(e.filename).toBe("");
            expect(e.lineno).toBe(0);
            expect(e.colno).toBe(0);
        });

        it("PromiseRejectionEvent exposes promise/reason", function () {
            const p = Promise.reject(1);
            p.catch(function () {});
            const r = { some: "reason" };
            const e = new PromiseRejectionEvent("unhandledrejection", { promise: p, reason: r });
            expect(e instanceof Event).toBe(true);
            expect(e.promise).toBe(p);
            expect(e.reason).toBe(r);
        });

        it("dispatchEvent returns !defaultPrevented", function () {
            const target = new EventTarget();
            target.addEventListener("t", function (e) { e.preventDefault(); });
            expect(target.dispatchEvent(new Event("t", { cancelable: true }))).toBe(false);

            const target2 = new EventTarget();
            target2.addEventListener("t", function () {});
            expect(target2.dispatchEvent(new Event("t", { cancelable: true }))).toBe(true);
        });

        it("once:true listener fires exactly once", function () {
            const target = new EventTarget();
            let count = 0;
            target.addEventListener("t", function () { count++; }, { once: true });
            target.dispatchEvent(new Event("t"));
            target.dispatchEvent(new Event("t"));
            expect(count).toBe(1);
        });

        it("removeEventListener stops future dispatches", function () {
            const target = new EventTarget();
            let count = 0;
            const handler = function () { count++; };
            target.addEventListener("t", handler);
            target.dispatchEvent(new Event("t"));
            target.removeEventListener("t", handler);
            target.dispatchEvent(new Event("t"));
            expect(count).toBe(1);
        });

        it("listeners run in registration order", function () {
            const target = new EventTarget();
            const order = [];
            target.addEventListener("t", function () { order.push(1); });
            target.addEventListener("t", function () { order.push(2); });
            target.addEventListener("t", function () { order.push(3); });
            target.dispatchEvent(new Event("t"));
            expect(order).toEqual([1, 2, 3]);
        });

        it("stopImmediatePropagation stops remaining listeners", function () {
            const target = new EventTarget();
            const order = [];
            target.addEventListener("t", function (e) { order.push(1); e.stopImmediatePropagation(); });
            target.addEventListener("t", function () { order.push(2); });
            target.dispatchEvent(new Event("t"));
            expect(order).toEqual([1]);
        });

        it("a throwing listener does not stop later listeners", function () {
            const target = new EventTarget();
            const order = [];
            target.addEventListener("t", function () { order.push(1); throw new Error("listener boom"); });
            target.addEventListener("t", function () { order.push(2); });
            target.dispatchEvent(new Event("t"));
            expect(order).toEqual([1, 2]);
        });
    });

    it("reportError still fires listeners after globalThis.dispatchEvent is overwritten", function (done) {
        const err = new Error("resilient");
        let received = null;
        onGlobal("error", function (e) {
            received = e;
            e.preventDefault();
        });

        const originalDispatch = globalThis.dispatchEvent;
        globalThis.dispatchEvent = function () { return true; };
        try {
            global.reportError(err);
        } finally {
            globalThis.dispatchEvent = originalDispatch;
        }

        expect(received).not.toBeNull();
        expect(received.error).toBe(err);
        // Assert THIS error was suppressed, not uncaught.length===0 (process-global shim;
        // other specs' async errors can drain into it during quiet turns).
        afterQuietTurns(function () {
            expect(uncaught).not.toContain(err);
            done();
        });
    });
});
