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
