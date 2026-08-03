describe("Extended class naming", function () {
    it("keeps explicit main-isolate class names verbatim", function () {
        var MainClaim = NSObject.extend({}, { name: "TNSMainVerbatimName" });
        expect(NSStringFromClass(MainClaim)).toBe("TNSMainVerbatimName");
    });

    it("scopes worker-created explicit class names to their isolate", function (done) {
        var worker = new Worker("~/shared/Workers/EvalWorker.js");
        worker.onmessage = function (msg) {
            worker.terminate();
            var workerName = msg.data.name;
            expect(workerName).not.toBe("TNSWorkerNameClaim");
            expect(workerName.indexOf("TNSWorkerNameClaim")).toBe(0);
            // The verbatim name must remain available to the main isolate.
            var MainClass = NSObject.extend({}, { name: "TNSWorkerNameClaim" });
            expect(NSStringFromClass(MainClass)).toBe("TNSWorkerNameClaim");
            done();
        };
        worker.postMessage({
            eval: "var C = NSObject.extend({}, { name: 'TNSWorkerNameClaim' }); " +
                  "postMessage({ name: NSStringFromClass(C) });"
        });
    });

    it("scopes worker-created TypeScript-extended class names to their isolate", function (done) {
        var worker = new Worker("~/shared/Workers/EvalWorker.js");
        worker.onmessage = function (msg) {
            worker.terminate();
            var workerName = msg.data.name;
            expect(workerName).not.toBe("TNSWorkerTsNameClaim");
            expect(workerName.indexOf("TNSWorkerTsNameClaim")).toBe(0);
            done();
        };
        worker.postMessage({
            eval: "function TNSWorkerTsNameClaim() {} " +
                  "__extends(TNSWorkerTsNameClaim, NSObject); " +
                  "postMessage({ name: NSStringFromClass(TNSWorkerTsNameClaim) });"
        });
    });
});
