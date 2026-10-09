// Native threads keep calling into a worker's isolate while that worker is
// torn down. Calls that were already waiting for the isolate's Locker when the
// teardown took it must not touch the isolate once it is gone.
describe("Collection adapters read from native threads", function () {
    var ROUNDS = 3;

    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 20000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    function terminateWhileQueried(kind, round, done) {
        if (round === ROUNDS) {
            done();
            return;
        }
        var worker = new Worker("./collectionAdapterQueryWorker.js");
        worker.onmessage = function (msg) {
            expect(msg.data).toBe("querying");
            setTimeout(function () {
                worker.terminate();
                // Past the native loops' deadline, so each round's last
                // release has happened before the next one starts.
                setTimeout(function () {
                    terminateWhileQueried(kind, round + 1, done);
                }, 600);
            }, 20);
        };
        worker.onerror = function (e) {
            expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
            done();
        };
        worker.postMessage(kind);
    }

    it("survive the teardown of the worker that made an array adapter", function (done) {
        terminateWhileQueried("array", 0, done);
    });

    it("survive the teardown of the worker that made a dictionary adapter", function (done) {
        terminateWhileQueried("dictionary", 0, done);
    });
});
