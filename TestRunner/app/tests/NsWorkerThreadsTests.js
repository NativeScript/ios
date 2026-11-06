describe("ns:worker_threads", function () {
    var nsWorkerThreads = require("ns:worker_threads");
    var worker, originalTimeout;

    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 30000;
    });
    afterEach(function () {
        if (worker) {
            worker.onmessage = null;
            worker.onerror = null;
            worker.terminate();
            worker = null;
        }
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    it("exposes frozen exports", function () {
        expect(Object.isFrozen(nsWorkerThreads)).toBe(true);
        expect(typeof nsWorkerThreads.Worker).toBe("function");
    });

    // The export set is public API, declared in types/ns-worker-threads.d.ts
    // and docs/ns-builtin-modules.md — all three must change together.
    it("exposes exactly the declared surface", function () {
        expect(Object.keys(nsWorkerThreads).sort()).toEqual(["Worker"]);
    });

    it("exports the Worker the global holds", function () {
        expect(nsWorkerThreads.Worker).toBe(globalThis.Worker);
    });

    it("is a singleton per realm", function () {
        expect(require("ns:worker_threads")).toBe(nsWorkerThreads);
    });

    it("is a distinct module object from the node:worker_threads shim", function () {
        var shim = require("node:worker_threads");
        expect(shim).not.toBe(nsWorkerThreads);
        expect(Object.isFrozen(shim)).toBe(true);
    });

    it("constructs a worker with the runtime's options", function (done) {
        worker = new nsWorkerThreads.Worker("./workerResourceLimits/echoWorker.js", {
            ios: { priority: "utility" },
            resourceLimits: { maxOldGenerationSizeMb: 64 },
        });
        var settled = false;
        var finish = function () {
            if (settled) {
                return;
            }
            settled = true;
            done();
        };
        worker.onmessage = function (event) {
            expect(event.data.started).toBe(true);
            finish();
        };
        worker.onerror = function (event) {
            expect(String(event.message)).toBe("<no worker error>");
            finish();
        };
    });

    it("hands a worker realm its own constructor, not whatever the global names", function (done) {
        worker = new Worker("./nsWorkerThreadsIdentityWorker.js");
        worker.onmessage = function (event) {
            expect(event.data).toEqual({ isOriginal: true, isImpostor: false, frozen: true });
            done();
        };
        worker.onerror = function (event) {
            fail("worker error: " + event.message);
            done();
        };
    });
});
