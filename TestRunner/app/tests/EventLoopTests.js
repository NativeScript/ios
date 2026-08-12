// V8 delivers these resolutions as platform foreground tasks, so they only
// settle if the runtime pumps its foreground task runner (the EventLoop's
// internal lane).
describe("event loop foreground tasks", function () {
    it("resolves Atomics.waitAsync when notified on the same thread", function (done) {
        const sab = new SharedArrayBuffer(4);
        const i32 = new Int32Array(sab);

        const result = Atomics.waitAsync(i32, 0, 0);
        expect(result.async).toBe(true);

        result.value.then(value => {
            expect(value).toBe("ok");
            done();
        }).catch(e => {
            fail("Atomics.waitAsync promise rejected: " + e);
            done();
        });

        const woken = Atomics.notify(i32, 0);
        expect(woken).toBe(1);
    });

    it("resolves Atomics.waitAsync with 'timed-out' after the timeout", function (done) {
        const sab = new SharedArrayBuffer(4);
        const i32 = new Int32Array(sab);

        const result = Atomics.waitAsync(i32, 0, 0, 50);
        expect(result.async).toBe(true);

        result.value.then(value => {
            expect(value).toBe("timed-out");
            done();
        }).catch(e => {
            fail("Atomics.waitAsync promise rejected: " + e);
            done();
        });
    });

    it("resolves Atomics.waitAsync synchronously on value mismatch", function () {
        const sab = new SharedArrayBuffer(4);
        const i32 = new Int32Array(sab);
        i32[0] = 42;

        const result = Atomics.waitAsync(i32, 0, 0);
        expect(result.async).toBe(false);
        expect(result.value).toBe("not-equal");
    });

    it("keeps ordinary promise chains working alongside foreground tasks", function (done) {
        const sab = new SharedArrayBuffer(4);
        const i32 = new Int32Array(sab);
        const order = [];

        Atomics.waitAsync(i32, 0, 0).value.then(() => {
            order.push("waitAsync");
            return Promise.resolve();
        }).then(() => {
            order.push("chained");
            expect(order).toEqual(["waitAsync", "chained"]);
            done();
        }).catch(e => {
            fail("promise chain failed: " + e);
            done();
        });

        Atomics.notify(i32, 0);
    });

    // The kAuto-stall fix: the wakeup task resolves the promise without
    // entering JS, so its .then only runs if each loop entry ends with a
    // microtask checkpoint. It must beat a timer scheduled well after it.
    it("runs microtasks of a natively-resolved promise before a later macrotask", function (done) {
        const i32 = new Int32Array(new SharedArrayBuffer(4));
        const order = [];

        Atomics.waitAsync(i32, 0, 0).value.then(() => {
            order.push("wait");
        });
        Atomics.notify(i32, 0);

        __ns__setTimeout(() => {
            order.push("timer");
            expect(order).toEqual(["wait", "timer"]);
            done();
        }, 50);
    });
});

// The ordered lane rides the home runloop's performed-block order, so these
// callbacks must be strict macrotasks: after the current turn's microtasks,
// FIFO with native timers by due time.
describe("event loop ordered macrotasks", function () {
    it("__ns__queueMacrotask runs the callback asynchronously", function (done) {
        let ran = false;
        __ns__queueMacrotask(() => {
            ran = true;
            done();
        });
        expect(ran).toBe(false);
    });

    it("runs after the current turn's microtasks", function (done) {
        const order = [];
        __ns__queueMacrotask(() => {
            order.push("macrotask");
            expect(order).toEqual(["microtask", "macrotask"]);
            done();
        });
        Promise.resolve().then(() => order.push("microtask"));
    });

    it("is FIFO among itself", function (done) {
        const order = [];
        __ns__queueMacrotask(() => order.push(1));
        __ns__queueMacrotask(() => order.push(2));
        __ns__queueMacrotask(() => {
            order.push(3);
            expect(order).toEqual([1, 2, 3]);
            done();
        });
    });

    // native timers (__ns__*): the app-level `setTimeout` global in this test
    // app is an NSTimer-based polyfill, not the runtime timers
    it("stays FIFO-ordered with native setTimeout(0)", function (done) {
        const order = [];
        __ns__queueMacrotask(() => order.push("macro1"));
        __ns__setTimeout(() => order.push("timeout"), 0);
        __ns__queueMacrotask(() => {
            order.push("macro2");
            expect(order).toEqual(["macro1", "timeout", "macro2"]);
            done();
        });
    });

    it("rejects non-function arguments", function () {
        expect(() => __ns__queueMacrotask("nope")).toThrowError(TypeError);
        expect(() => __ns__queueMacrotask()).toThrowError(TypeError);
    });
});

// clearTimeout leaves a tombstone in the merged ordered domain, so the
// cleared timer's already-posted token consumes its own slot as a no-op
// instead of running a later-scheduled item ahead of foreign runloop work
// queued between the two tokens' positions.
describe("event loop ordered tombstones", function () {
    it("clear + re-schedule does not reorder against queued macrotasks", function (done) {
        const order = [];
        const t1 = __ns__setTimeout(() => order.push("cleared"), 0);
        __ns__clearTimeout(t1);
        __ns__queueMacrotask(() => order.push("macro"));
        __ns__setTimeout(() => {
            order.push("t2");
            expect(order).toEqual(["macro", "t2"]);
            done();
        }, 0);
    });

    it("clearing an overdue timer does not fire a later timer early", function (done) {
        const order = [];
        const t1 = __ns__setTimeout(() => order.push("cleared"), 0);
        __ns__setTimeout(() => order.push("late"), 30);
        __ns__clearTimeout(t1);
        // busy-wait so both timers are overdue when their tokens drain in the
        // same runloop burst
        const start = Date.now();
        while (Date.now() - start < 50) { }
        __ns__queueMacrotask(() => {
            order.push("macro");
            expect(order).toEqual(["late", "macro"]);
            done();
        });
    });

    it("keeps interval callbacks running after an unrelated clear", function (done) {
        const order = [];
        const cleared = __ns__setInterval(() => order.push("cleared"), 1);
        __ns__clearInterval(cleared);
        let count = 0;
        const interval = __ns__setInterval(() => {
            if (++count === 3) {
                __ns__clearInterval(interval);
                expect(order).toEqual([]);
                done();
            }
        }, 5);
    });
});

describe("event loop workers", function () {
    beforeEach(function () {
        this.originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 15000;
    });

    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = this.originalTimeout;
    });

    it("keeps worker->parent messages ordered", function (done) {
        const worker = new Worker("./eventLoopEchoWorker.js");
        const received = [];
        worker.onmessage = function (msg) {
            received.push(msg.data);
            if (received.length === 3) {
                expect(received).toEqual([1, 2, 3]);
                worker.terminate();
                done();
            }
        };
        worker.postMessage(1);
        worker.postMessage(2);
        worker.postMessage(3);
    });

    it("resolves Atomics.waitAsync inside a worker's own loop", function (done) {
        const worker = new Worker("./EventLoopWaitAsyncWorker.js");
        worker.onmessage = function (msg) {
            expect(msg.data).toBe("ok");
            worker.terminate();
            done();
        };
        worker.postMessage("go");
    });

    // A worker reply racing an overdue waitAsync timeout on the parent: the
    // reply's wakeup must not be starved by the timeout entry.
    it("delivers worker messages whose wakeup raced an overdue waitAsync timeout", function (done) {
        const worker = new Worker("./eventLoopEchoWorker.js");
        let warm = false;
        worker.onmessage = function (msg) {
            if (msg.data === "warmup") {
                warm = true;
                const i32 = new Int32Array(new SharedArrayBuffer(4));
                Atomics.waitAsync(i32, 0, 0, 50);
                worker.postMessage("ping");
                // block the runloop until both the timeout and the reply are
                // pending, so their wakeups are serviced from the same burst
                const start = Date.now();
                while (Date.now() - start < 150) { }
            } else {
                expect(warm).toBe(true);
                expect(msg.data).toBe("ping");
                worker.terminate();
                done();
            }
        };
        worker.postMessage("warmup");
    });

    it("survives terminating a worker with queued loop work", function (done) {
        const worker = new Worker("./eventLoopEchoWorker.js");
        worker.onmessage = function () {
            // several messages are still queued on the worker's loop when the
            // terminate lands; none of them may crash or hang teardown
            for (let i = 0; i < 20; i++) {
                worker.postMessage("queued-" + i);
            }
            worker.terminate();
            __ns__setTimeout(done, 500);
        };
        worker.postMessage("alive");
    });

    // Rapid create/terminate cycles reuse isolate addresses; each new worker
    // must get a live loop, not a dead predecessor's (registry refresh path).
    it("keeps event loops healthy across worker churn", function (done) {
        let remaining = 8;
        (function cycle() {
            const worker = new Worker("./eventLoopEchoWorker.js");
            worker.onmessage = function () {
                worker.terminate();
                if (--remaining === 0) {
                    __ns__queueMacrotask(done);
                } else {
                    cycle();
                }
            };
            worker.postMessage("alive");
        })();
    });
});
