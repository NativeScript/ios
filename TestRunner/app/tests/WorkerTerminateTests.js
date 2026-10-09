// terminate() reaches a worker that is still inside its entry script, the way
// it does in Node and on the web: the running entry is interrupted, the thread
// winds down, and nothing is reported as an error.
describe("Worker terminate during entry evaluation", function () {
    var busyEntry = "./workerTerminate/busyEntryWorker.js";
    var parkedEntry = "./workerTerminate/parkedEntryWorker.mjs";

    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 60000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    // Resolves once the worker's thread has ended; rejects when it has not
    // within `limitMs`.
    function waitForEnd(worker, limitMs) {
        return new Promise(function (resolve, reject) {
            var timer = setTimeout(function () {
                reject(new Error("worker did not end within " + limitMs + "ms"));
            }, limitMs);
            worker.addEventListener("nsworkerended", function () {
                clearTimeout(timer);
                resolve();
            });
        });
    }

    // A terminated worker reports no error, from either hop.
    function failOnError(worker) {
        worker.onerror = function (event) {
            fail("unexpected worker error: " + event.message);
            return true;
        };
    }

    function settle(done) {
        return function (err) {
            if (err) {
                fail(err.message);
            }
            done();
        };
    }

    it("interrupts an entry script spinning in a synchronous loop", function (done) {
        var worker = new Worker(busyEntry);
        failOnError(worker);
        worker.onmessage = function (event) {
            expect(event.data).toBe("spinning");
            var ended = waitForEnd(worker, 5000);
            worker.terminate();
            ended.then(settle(done), settle(done));
        };
    });

    it("ends an ES module entry parked in a top-level await", function (done) {
        var worker = new Worker(parkedEntry);
        failOnError(worker);
        worker.onmessage = function (event) {
            expect(event.data).toBe("parked");
            var ended = waitForEnd(worker, 5000);
            worker.terminate();
            ended.then(settle(done), settle(done));
        };
    });

    // Round i terminates 25·i milliseconds after construction. Runtime setup
    // takes a few hundred milliseconds on a simulator and the local entry's
    // settle pump lasts one second after it, so the rounds land anywhere from
    // before the thread has started, through runtime setup, to inside the
    // pump.
    it("ends a worker terminated at any point of its startup", function (done) {
        var ROUNDS = 16;
        (function round(i) {
            if (i === ROUNDS) {
                done();
                return;
            }
            var worker = new Worker(parkedEntry);
            failOnError(worker);
            var ended = waitForEnd(worker, 5000);
            if (i === 0) {
                worker.terminate();
            } else {
                setTimeout(function () { worker.terminate(); }, i * 25);
            }
            ended.then(function () { round(i + 1); }, settle(done));
        })(0);
    });

    it("resolves a node:worker_threads terminate() for a worker stuck in its entry", function (done) {
        var wt = require("node:worker_threads");
        var worker = new wt.Worker("~/tests/workerTerminate/busyEntryWorker.js");
        var exitCode = null;
        worker.on("error", function (err) {
            fail("unexpected worker error: " + err);
        });
        worker.on("exit", function (code) {
            exitCode = code;
        });
        worker.on("message", function (data) {
            expect(data).toBe("spinning");
            worker.terminate().then(function (code) {
                expect(code).toBe(0);
                expect(exitCode).toBe(0);
                done();
            }, settle(done));
        });
    });
});
