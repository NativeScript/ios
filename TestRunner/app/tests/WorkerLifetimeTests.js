// Worker lifetime under GC. A running worker's JS wrapper is a GC root, so it
// behaves like any other strongly held object: weak collections keyed on it
// keep their entries, and it keeps answering messages nobody holds a reference
// to it for. Once the worker ends — terminate() or its own close() — the root
// is dropped and the wrapper becomes collectable.

describe("Worker lifetime", function () {
    const WORKER_COUNT = 4;
    const PAYLOAD_SIZE = 64;

    // A collection per runloop turn: weak-collection clearing needs turns after
    // the collect, so nothing here asserts synchronously after __collect().
    function pollGC(predicate, cb) {
        let turns = 0;
        (function poll() {
            __collect();
            if (predicate() || turns >= 100) {
                cb();
                return;
            }
            turns++;
            setTimeout(poll, 20);
        })();
    }

    // Reached through a call rather than a closure, so the worker it derefs
    // cannot end up in a scope the caller's later callbacks keep alive.
    function terminateWorker(ref) {
        const worker = ref.deref();
        if (worker !== undefined) {
            worker.terminate();
        }
    }

    function postToWorker(ref, message) {
        const worker = ref.deref();
        if (worker !== undefined) {
            worker.postMessage(message);
        }
    }

    // Enough allocation to put V8 part-way through an incremental/concurrent
    // mark, so the collection that follows finishes a mark that was already
    // running rather than starting an atomic one.
    function churn() {
        let sink = null;
        for (let i = 0; i < 24; i++) {
            const block = new Array(8192);
            for (let j = 0; j < 8192; j++) {
                block[j] = { j: j, s: "churn-" + j };
            }
            sink = block;
        }
        return sink !== null;
    }

    function makePayload(id) {
        const payload = new Array(PAYLOAD_SIZE);
        for (let i = 0; i < PAYLOAD_SIZE; i++) {
            payload[i] = "payload-" + id + "-" + i;
        }
        return payload;
    }

    it("a live Worker survives GC as a WeakMap key", function (done) {
        // Nothing outside this map holds the values: an entry whose key stays
        // alive while its value is not marked is what leaves a dangling value
        // slot behind.
        const sideTable = new WeakMap();
        const refs = [];
        let replies = 0;

        for (let i = 0; i < WORKER_COUNT; i++) {
            refs.push((function () {
                const worker = new Worker("./eventLoopEchoWorker.js");
                // A second entry reachable only through the first one's value,
                // so resolving these takes more than one ephemeron pass.
                const link = { id: i };
                sideTable.set(link, { deep: i, payload: makePayload("deep" + i) });
                sideTable.set(worker, { id: i, link: link, payload: makePayload(i) });
                worker.onmessage = function () { replies++; };
                worker.postMessage("ping");
                return new WeakRef(worker);
            })());
        }

        let round = 0;
        function spin() {
            churn();
            // async execution runs the collection from a task, so V8 treats the
            // stack as pointer-free and the workers are genuinely unreachable
            // for it — a conservative scan of this frame would not let them be.
            __collect({ execution: "async" }).then(function () {
                __collect();

                // Only some turns touch the workers: a turn that does not leaves
                // them dead for a whole mark cycle.
                if (round % 3 === 0) {
                    for (let i = 0; i < refs.length; i++) {
                        postToWorker(refs[i], "ping-" + round);
                    }
                }

                round++;
                if (round < 15) {
                    setTimeout(spin, 20);
                    return;
                }

                for (let i = 0; i < refs.length; i++) {
                    const survivor = refs[i].deref();
                    expect(survivor).not.toBeUndefined();
                    if (survivor === undefined) {
                        continue;
                    }
                    const entry = sideTable.get(survivor);
                    expect(entry).not.toBeUndefined();
                    if (entry !== undefined) {
                        expect(entry.id).toBe(i);
                        expect(entry.payload.length).toBe(PAYLOAD_SIZE);
                        expect(entry.payload[PAYLOAD_SIZE - 1]).toBe("payload-" + i + "-" + (PAYLOAD_SIZE - 1));
                        const deep = sideTable.get(entry.link);
                        expect(deep).not.toBeUndefined();
                        if (deep !== undefined) {
                            expect(deep.deep).toBe(i);
                            expect(deep.payload.length).toBe(PAYLOAD_SIZE);
                        }
                    }
                }
                expect(replies).toBeGreaterThan(0);

                for (let i = 0; i < refs.length; i++) {
                    terminateWorker(refs[i]);
                }
                done();
            });
        }
        spin();
    });

    it("an unreferenced live Worker still answers messages", function (done) {
        let reply = null;
        const ref = (function () {
            const worker = new Worker("./eventLoopEchoWorker.js");
            worker.onmessage = function (event) { reply = event.data; };
            worker.postMessage("hello");
            return new WeakRef(worker);
        })();

        pollGC(function () { return reply !== null; }, function () {
            expect(reply).toBe("hello");
            expect(ref.deref()).not.toBeUndefined();
            terminateWorker(ref);
            done();
        });
    });

    it("a terminated Worker becomes collectable", function (done) {
        const ref = (function () {
            const worker = new Worker("./eventLoopEchoWorker.js");
            worker.postMessage("ping");
            return new WeakRef(worker);
        })();

        setTimeout(function () {
            terminateWorker(ref);
            setTimeout(function () {
                pollGC(function () { return ref.deref() === undefined; }, function () {
                    expect(ref.deref()).toBeUndefined();
                    done();
                });
            }, 100);
        }, 150);
    });

    it("a Worker that closed itself becomes collectable", function (done) {
        const ref = (function () {
            const worker = new Worker("./workerLifetimeCloseWorker.js");
            worker.postMessage("close");
            return new WeakRef(worker);
        })();

        setTimeout(function () {
            pollGC(function () { return ref.deref() === undefined; }, function () {
                expect(ref.deref()).toBeUndefined();
                done();
            });
        }, 300);
    });
});

describe("node:worker_threads Worker exit", function () {
    const wt = require("node:worker_threads");

    it("emits 'exit' once when the worker closes itself", function (done) {
        const worker = new wt.Worker("~/tests/workerLifetimeCloseWorker.js");
        const codes = [];
        worker.on("exit", function (code) { codes.push(code); });
        worker.postMessage("go");

        setTimeout(function () {
            expect(codes).toEqual([0]);
            done();
        }, 800);
    });

    it("emits 'exit' once on terminate()", function (done) {
        const worker = new wt.Worker("~/tests/eventLoopEchoWorker.js");
        const codes = [];
        worker.on("exit", function (code) { codes.push(code); });

        setTimeout(function () {
            worker.terminate();
            setTimeout(function () {
                expect(codes).toEqual([0]);
                done();
            }, 800);
        }, 150);
    });
});
