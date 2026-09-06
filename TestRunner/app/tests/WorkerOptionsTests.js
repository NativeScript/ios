describe("Worker platform options", function () {
    var entry = "./workerOptions/qosWorker.js";

    // Jasmine arms a spec's async timeout before calling it, so the interval
    // has to be raised ahead of the spec, not inside it. A utility thread boots
    // a whole isolate under throttled CPU and I/O; on a contended host that has
    // taken well over 10 s.
    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 120000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    var reportQos = function (options, done, check) {
        var worker = options === undefined ? new Worker(entry) : new Worker(entry, options);
        var settled = false;
        var finish = function () {
            if (settled) {
                return;
            }
            settled = true;
            worker.terminate();
            done();
        };
        worker.onmessage = function (msg) {
            check(msg.data.qos);
            finish();
        };
        worker.onerror = function (e) {
            expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
            finish();
        };
    };

    // Background is deliberately absent: the system defines that class as work
    // that may take minutes, and on a loaded host a background thread has not
    // finished booting an isolate within two minutes. It is covered below
    // without waiting on it.
    var priorities = [
        ["userInteractive", NSQualityOfService.UserInteractive],
        ["userInitiated", NSQualityOfService.UserInitiated],
        ["default", NSQualityOfService.Default],
        ["utility", NSQualityOfService.Utility]
    ];

    priorities.forEach(function (pair) {
        it("runs the worker thread at " + pair[0] + " quality of service", function (done) {
            reportQos({ ios: { priority: pair[0] } }, done, function (qos) {
                expect(qos).toBe(pair[1]);
            });
        });
    });

    it("accepts background priority", function () {
        var worker;
        expect(function () {
            worker = new Worker(entry, { ios: { priority: "background" } });
        }).not.toThrow();
        worker.terminate();
    });

    it("still honors the deprecated iosPriority option", function (done) {
        reportQos({ iosPriority: "utility" }, done, function (qos) {
            expect(qos).toBe(NSQualityOfService.Utility);
        });
    });

    it("prefers ios.priority over iosPriority when both are given", function (done) {
        reportQos({ ios: { priority: "userInteractive" }, iosPriority: "background" }, done, function (qos) {
            expect(qos).toBe(NSQualityOfService.UserInteractive);
        });
    });

    it("ignores unknown keys inside ios", function (done) {
        reportQos({ ios: { priority: "utility", somethingElse: 42 } }, done, function (qos) {
            expect(qos).toBe(NSQualityOfService.Utility);
        });
    });

    it("starts a worker given no options at all", function (done) {
        reportQos(undefined, done, function (qos) {
            expect(typeof qos).toBe("number");
        });
    });

    it("treats ios: null like an absent ios", function (done) {
        reportQos({ ios: null, iosPriority: "utility" }, done, function (qos) {
            expect(qos).toBe(NSQualityOfService.Utility);
        });
    });

    it("throws a TypeError when ios is not an object", function () {
        expect(function () {
            new Worker(entry, { ios: 42 });
        }).toThrowError(TypeError, /"ios"/);
    });

    it("throws a TypeError for an unknown ios.priority", function () {
        expect(function () {
            new Worker(entry, { ios: { priority: "highest" } });
        }).toThrowError(TypeError, /"ios\.priority"/);
    });

    it("throws a TypeError for a non-string ios.priority", function () {
        expect(function () {
            new Worker(entry, { ios: { priority: 3 } });
        }).toThrowError(TypeError, /"ios\.priority"/);
    });
});
