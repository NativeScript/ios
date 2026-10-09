// A JS function marshalled as a block caches that block on itself. These tests
// keep re-marshalling one function while native code drops the cached block's
// last reference on another thread, so the block's dispose helper (which waits
// for the isolate's Locker) overlaps cache hits made by the Locker's holder.
describe("JS block cache under cross-thread release", function () {
    var ITERATIONS = 600;
    var RELEASE_MODES = [
        { name: "a concurrent queue", mode: 0 },
        { name: "a serial queue", mode: 1 },
        { name: "the main operation queue", mode: 2 },
    ];

    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 60000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    function hammer(mode, state) {
        var callback = function () {
            state.ran++;
        };
        TNSTestNativeCallbacks.repeatPausingAfter(ITERATIONS, function () {
            TNSTestNativeCallbacks.keepBlockReleaseMode(callback, mode);
        });
    }

    // Releases land up to 2 ms after the loop, and enqueued operations run on
    // later main-queue passes.
    function settle(mode, state, done) {
        var attempts = 200;
        (function poll() {
            if ((mode !== 2 || state.ran === ITERATIONS) || --attempts === 0) {
                setTimeout(function () {
                    __collect();
                    if (mode === 2) {
                        expect(state.ran).toBe(ITERATIONS);
                    }
                    done();
                }, 20);
                return;
            }
            setTimeout(poll, 10);
        })();
    }

    RELEASE_MODES.forEach(function (variant) {
        it("survives releases from " + variant.name + " while JS runs on the main thread", function (done) {
            var state = { ran: 0 };
            hammer(variant.mode, state);
            settle(variant.mode, state, done);
        });

        it("survives releases from " + variant.name + " while JS runs on a background thread", function (done) {
            var state = { ran: 0 };
            TNSTestNativeCallbacks.runOnBackgroundQueueCompletion(
                function () {
                    hammer(variant.mode, state);
                },
                function () {
                    settle(variant.mode, state, done);
                }
            );
        });
    });
});

describe("JS block whose dispose is waiting for the isolate", function () {
    // Drops the last native reference to fn's cached block on a background
    // queue while this thread keeps the isolate locked, so the block's dispose
    // stays parked on the Locker for the rest of the turn.
    function strandDispose(fn) {
        TNSTestNativeCallbacks.repeatPausingAfter(1, function () {
            TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1);
        });
        TNSTestNativeCallbacks.sleepMilliseconds(30);
    }

    it("is reported by interop.handleof while native code holds it", function () {
        var fn = function () {};
        TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1000);
        expect(interop.handleof(fn) instanceof interop.Pointer).toBe(true);
    });

    it("is not handed out by interop.handleof", function () {
        var fn = function () {};
        strandDispose(fn);
        expect(function () {
            interop.handleof(fn);
        }).toThrow();
    });

    it("is replaced by a fresh block when the function is marshalled again", function (done) {
        var ran = 0;
        var fn = function () {
            ran++;
        };
        strandDispose(fn);
        NSOperationQueue.mainQueue.addOperationWithBlock(fn);

        var attempts = 100;
        (function poll() {
            if (ran === 1 || --attempts === 0) {
                expect(ran).toBe(1);
                done();
                return;
            }
            setTimeout(poll, 10);
        })();
    });
});

describe("JS block outliving its worker", function () {
    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 10000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    // The function is also registered through interop.FunctionReference, so
    // the worker's teardown disposes it while native code still holds the
    // block built from it; the block's own dispose runs after the isolate is
    // gone.
    it("is released after a teardown that disposed its function", function (done) {
        var worker = new Worker("./blockFunctionReferenceWorker.js");
        worker.onmessage = function (msg) {
            expect(msg.data).toBe("kept");
            worker.terminate();
            setTimeout(done, 600);
        };
        worker.onerror = function (e) {
            expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
            done();
        };
        worker.postMessage(0);
    });
});
