/**
 TODO: Revisit thread handling with promises regarding these tests
 */
describe("Promise scheduling", function () {
    it("should be executed", function(done) {
        Promise.resolve().then(done);
    });

    it("the 'then' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).then(res => {
            expect(res).toBe(expectedResult);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).catch(e => {
            expect(true).toBe(false, "The catch callback of the promise was called");
            done();
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'then' callback (with onRejected handler) should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).then(res => {
            expect(res).toBe(expectedResult);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }, e => {
            expect(true).toBe(false, "The catch callback of the promise was called");
            done();
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'catch' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedError = new Error("oops");

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => reject(expectedError));
        }).then(res => {
            expect(true).toBe(false, "The then callback of the promise was called");
            done();
        }).catch(e => {
            expect(e).toBe(expectedError);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'catch' callback (with onRejected handler) should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedError = new Error("oops");

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => reject(expectedError));
        }).then(res => {
            expect(true).toBe(false, "The then callback of the promise was called");
            done();
        }, e => {
            expect(e).toBe(expectedError);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'finally' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("chaining promises with return values", done => {
        const expectedHash = NSThread.currentThread.hash;
        let expectedValues = [1, 2, 4, 8];
        let actualValues = [];

        new Promise(function(resolve, reject) {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(1));
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return value * 2;
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return new Promise((res, rej) => setTimeout(() => res(value * 2), 50));
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return Promise.resolve(value * 2);
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            expect(actualValues).toEqual(expectedValues);
            done();
        });
    });

    it("the 'then' callback runs for a Promise created on a background thread and resolved on the runtime loop", done => {
        // https://github.com/NativeScript/ios/issues/330
        // The promise is constructed on a background dispatch queue whose run
        // loop is dormant, then resolve() is invoked on the runtime loop. The
        // resolution must run there instead of being marshaled back to the
        // parked background loop, otherwise the promise never settles.
        const backgroundQueue = dispatch_get_global_queue(qos_class_t.QOS_CLASS_DEFAULT, 0);
        dispatch_async(backgroundQueue, () => {
            new Promise(resolve => {
                NSOperationQueue.mainQueue.addOperationWithBlock(() => resolve("settled"));
            }).then(value => {
                expect(value).toBe("settled");
                done();
            }).catch(error => {
                expect(true).toBe(false, "The promise rejected unexpectedly: " + error);
                done();
            });
        });
    });
});

describe("unhandled rejections", function () {
    // Unhandled rejections are tracked per-isolate and reported once per runloop
    // turn (kCFRunLoopBeforeWaiting) through the same uncaught-error machinery
    // exposed via global.__onUncaughtError. Each test installs a temporary hook
    // and restores the previous one in afterEach no matter what.
    let previousHook;
    let reported;

    beforeEach(function () {
        previousHook = global.__onUncaughtError;
        reported = [];
        global.__onUncaughtError = function (error) {
            reported.push(error);
        };
    });

    afterEach(function () {
        global.__onUncaughtError = previousHook;
    });

    // The drain happens on a runloop turn, so poll across a few turns until the
    // hook fires (or give up after a bounded number of turns).
    function afterDrain(cb) {
        let turns = 0;
        (function poll() {
            if (reported.length > 0 || turns >= 20) {
                cb();
                return;
            }
            turns++;
            setTimeout(poll, 10);
        })();
    }

    // Wait a couple of runloop turns to confirm the hook did NOT fire.
    function afterQuietTurns(cb) {
        setTimeout(function () {
            setTimeout(cb, 20);
        }, 20);
    }

    it("reports an unhandled Promise.reject", function (done) {
        const reason = new Error("unhandled-promise-reject");
        Promise.reject(reason);
        afterDrain(function () {
            expect(reported.length).toBeGreaterThan(0);
            expect(reported[0]).toBe(reason);
            done();
        });
    });

    it("does not report when .catch is attached synchronously in the same turn", function (done) {
        const p = Promise.reject(new Error("handled-same-turn"));
        p.catch(function () {});
        afterQuietTurns(function () {
            expect(reported.length).toBe(0);
            done();
        });
    });

    it("reports an uncaught throw from an async function", function (done) {
        const reason = new Error("async-function-throw");
        (async () => {
            throw reason;
        })();
        afterDrain(function () {
            expect(reported.length).toBeGreaterThan(0);
            expect(reported[0]).toBe(reason);
            done();
        });
    });

    it("reports an unhandled rejection thrown from a .then callback", function (done) {
        const reason = new Error("then-callback-throw");
        Promise.resolve().then(() => {
            throw reason;
        });
        afterDrain(function () {
            expect(reported.length).toBeGreaterThan(0);
            expect(reported[0]).toBe(reason);
            done();
        });
    });

    it("ignores a late .catch attached after the rejection was already reported", function (done) {
        const reason = new Error("late-catch");
        const p = Promise.reject(reason);
        afterDrain(function () {
            expect(reported.length).toBeGreaterThan(0);
            // Attaching a handler after the report was already delivered must not
            // crash (Phase 1 silently drops the already-drained entry).
            p.catch(function () {});
            afterQuietTurns(function () {
                expect(reported.length).toBe(1);
                done();
            });
        });
    });
});
