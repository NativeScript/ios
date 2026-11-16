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

    // The worker's teardown itself drops the block's last reference, while it
    // still has the function left to dispose.
    it("is released by the teardown that later disposes its function", function (done) {
        var worker = new Worker("./blockTeardownReleaseWorker.js");
        worker.onmessage = function (msg) {
            expect(msg.data).toBe("held");
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

// Native state such as a static is shared by every isolate, so a block made
// from one isolate's function can be handed to another. Only the isolate that
// made it gets the function itself back; any other one gets a function that
// calls the block, which runs the original function in its own isolate.
describe("JS block made by another isolate", function () {
    var originalTimeout;
    var workers = [];
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 20000;
    });
    afterEach(function () {
        TNSOwnedBlocks.clearSharedBlock();
        workers.splice(0).forEach(function (worker) {
            worker.terminate();
        });
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    function evalWorker() {
        var worker = new Worker("~/shared/Workers/EvalWorker.js");
        worker.onerror = function (e) {
            fail("unexpected worker error: " + (e && e.message ? e.message : e));
            return true;
        };
        workers.push(worker);
        return worker;
    }

    // Resolves with the worker's next message.
    function ask(worker, source) {
        return new Promise(function (resolve) {
            worker.onmessage = function (msg) {
                resolve(msg.data);
            };
            worker.postMessage({ eval: source });
        });
    }

    // Resolves once the worker's runtime is gone.
    function terminate(worker) {
        return new Promise(function (resolve) {
            worker.addEventListener("nsworkerended", function () {
                resolve();
            });
            worker.terminate();
        });
    }

    function collect() {
        return new Promise(function (resolve) {
            setTimeout(function () {
                __collect();
                setTimeout(resolve, 20);
            }, 20);
        });
    }

    function finish(done) {
        return function (err) {
            if (err) {
                fail(err && err.stack ? err.stack : err);
            }
            done();
        };
    }

    // `offset` exists only in the worker, so a call answering x + 1000 ran
    // there.
    var storeWorkerFunction =
        "globalThis.offset = 1000;" +
        "globalThis.calls = 0;" +
        "globalThis.fn = function (x) { calls++; return x + offset; };" +
        "TNSOwnedBlocks.storeSharedBlock(fn);" +
        "postMessage('stored');";

    it("calls a worker's function through its block, and answers zero once the worker is gone", function (done) {
        var worker = evalWorker();
        var state = {};
        ask(worker, storeWorkerFunction)
            .then(function (reply) {
                expect(reply).toBe("stored");
                state.fn = TNSOwnedBlocks.sharedBlock();
                state.owned = TNSOwnedBlocks.retainedSharedBlock();
                expect(typeof state.fn).toBe("function");
                expect(typeof state.owned).toBe("function");
                expect(state.fn(1)).toBe(1001);
                expect(state.owned(2)).toBe(1002);
                state.taken = TNSOwnedBlocks.takeSharedBlock();
                expect(state.taken(3)).toBe(1003);
                expect(TNSOwnedBlocks.sharedBlock()).toBe(null);
                return ask(worker, "postMessage(calls);");
            })
            .then(function (calls) {
                expect(calls).toBe(3);
                return terminate(worker);
            })
            .then(function () {
                expect(state.fn(4)).toBe(0);
                expect(state.owned(5)).toBe(0);
                expect(state.taken(6)).toBe(0);
                expect(TNSOwnedBlocks.callBlockWithValue(state.fn, 7)).toBe(0);
                state = null;
                return collect();
            })
            .then(finish(done), finish(done));
    });

    it("hands native code the worker's own block when the function wrapping it is passed back", function (done) {
        var worker = evalWorker();
        var state = {};
        ask(worker, storeWorkerFunction)
            .then(function () {
                state.fn = TNSOwnedBlocks.takeSharedBlock();
                expect(TNSOwnedBlocks.callBlockWithValue(state.fn, 1)).toBe(1001);
                TNSOwnedBlocks.storeSharedBlock(state.fn);
                state.fn = null;
                return collect();
            })
            .then(function () {
                return ask(worker,
                    "var back = TNSOwnedBlocks.sharedBlock();" +
                    "postMessage({ same: back === fn, calls: calls, result: back(2) });");
            })
            .then(function (reply) {
                expect(reply.same).toBe(true);
                expect(reply.calls).toBe(1);
                expect(reply.result).toBe(1002);
                TNSOwnedBlocks.clearSharedBlock();
                return terminate(worker);
            })
            .then(finish(done), finish(done));
    });

    // A block's function runs on the thread that calls the block, inside the
    // isolate that made it.
    it("calls the main isolate's function through its block from a worker", function (done) {
        var worker = evalWorker();
        var state = { calls: 0, offset: 500 };
        state.fn = function (x) {
            state.calls++;
            state.thread = NSThread.currentThread.hash;
            state.onMainThread = NSThread.isMainThread;
            return x + state.offset;
        };
        TNSOwnedBlocks.storeSharedBlock(state.fn);
        ask(worker,
            "var fn = TNSOwnedBlocks.sharedBlock();" +
            "var owned = TNSOwnedBlocks.retainedSharedBlock();" +
            "postMessage({ type: typeof fn, thread: NSThread.currentThread.hash," +
            "  results: [fn(1), owned(2), TNSOwnedBlocks.callBlockWithValue(fn, 3)] });")
            .then(function (reply) {
                expect(reply.type).toBe("function");
                expect(reply.results).toEqual([501, 502, 503]);
                expect(state.calls).toBe(3);
                expect(state.onMainThread).toBe(false);
                expect(state.thread).toBe(reply.thread);
                TNSOwnedBlocks.clearSharedBlock();
                return terminate(worker);
            })
            .then(collect)
            .then(finish(done), finish(done));
    });

    it("answers the main isolate its own function", function () {
        var fn = function (x) {
            return x * 2;
        };
        TNSOwnedBlocks.storeSharedBlock(fn);
        expect(TNSOwnedBlocks.sharedBlock()).toBe(fn);
        expect(TNSOwnedBlocks.retainedSharedBlock()).toBe(fn);
        expect(TNSOwnedBlocks.takeSharedBlock()).toBe(fn);
        expect(TNSOwnedBlocks.sharedBlock()).toBe(null);
    });

    it("answers a worker its own function", function (done) {
        var worker = evalWorker();
        ask(worker,
            "var own = function (x) { return x * 3; };" +
            "TNSOwnedBlocks.storeSharedBlock(own);" +
            "postMessage([TNSOwnedBlocks.sharedBlock() === own," +
            "  TNSOwnedBlocks.retainedSharedBlock() === own," +
            "  TNSOwnedBlocks.takeSharedBlock() === own," +
            "  TNSOwnedBlocks.sharedBlock() === null]);")
            .then(function (reply) {
                expect(reply).toEqual([true, true, true, true]);
                return terminate(worker);
            })
            .then(finish(done), finish(done));
    });

    // A later worker's isolate may sit at the address of the one that made the
    // block, so only an isolate id tells the two apart. Which later isolate
    // lands there depends on the allocator, so several workers in a row read
    // the block.
    it("does not answer a later worker the function of a block whose worker is gone", function (done) {
        var READERS = 4;
        var maker = evalWorker();
        function read(i) {
            if (i === READERS) {
                return Promise.resolve();
            }
            var reader = evalWorker();
            return ask(reader,
                "var fn = TNSOwnedBlocks.sharedBlock();" +
                "postMessage({ type: typeof fn, result: fn(1)," +
                "  owned: TNSOwnedBlocks.retainedSharedBlock()(2) });")
                .then(function (reply) {
                    expect(reply.type).toBe("function");
                    expect(reply.result).toBe(0);
                    expect(reply.owned).toBe(0);
                    return terminate(reader);
                })
                .then(function () {
                    return read(i + 1);
                });
        }
        ask(maker, storeWorkerFunction)
            .then(function () {
                return terminate(maker);
            })
            .then(function () {
                return read(0);
            })
            .then(finish(done), finish(done));
    });
});
