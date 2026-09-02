describe("Worker startup", function () {
    var moduleNames = ["modA", "modB", "modC", "modD", "modE", "modF"];
    var entryCount = 6;
    var expected = {};
    moduleNames.forEach(function (name) {
        expected[name] = require("./concurrentStartup/" + name).value;
    });

    // Every worker thread reads script sources and code caches while it starts;
    // a batch started together loads the same files at the same moment, which
    // is how an app that spins up its workers at launch behaves. The entries
    // load the modules in rotated orders, so concurrent workers are reading
    // different files at any instant.
    it("many workers start at once against warm script caches", function (done) {
        var originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 30000;

        var finished = false;
        var finish = function () {
            if (finished) {
                return;
            }
            finished = true;
            jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            done();
        };

        var start = function (entry, onValues) {
            var worker = new Worker("./concurrentStartup/worker" + entry + ".js");
            worker.onmessage = function (msg) {
                expect(msg.data.values).toEqual(expected);
                worker.terminate();
                onValues();
            };
            worker.onerror = function (e) {
                expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
                worker.terminate();
                finish();
            };
        };

        var startBatch = function () {
            var total = entryCount * 2;
            var remaining = total;
            for (var i = 0; i < total; i++) {
                start(i % entryCount, function () {
                    remaining--;
                    if (remaining === 0) {
                        finish();
                    }
                });
            }
        };

        // Each entry once, one after another, so every entry's own code cache
        // exists before the batch.
        var warm = function (entry) {
            if (entry === entryCount) {
                startBatch();
                return;
            }
            start(entry, function () {
                warm(entry + 1);
            });
        };
        warm(0);
    });
});
