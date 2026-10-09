// A function can be marshalled both as a block and, once wrapped in
// interop.FunctionReference, as a C function pointer. Neither use may take over
// the state the other keeps on the function.
describe("Function used as a block and as a function pointer", function () {
    function square(x) {
        return x * x;
    }

    afterEach(function () {
        TNSClearOutput();
    });

    it("is called through a function pointer after being a block", function () {
        var blockCalls = [];
        var fn = new interop.FunctionReference(function (x) {
            blockCalls.push(x);
            return square(x);
        });

        TNSTestNativeCallbacks.repeatPausingAfter(2, fn);
        expect(blockCalls).toEqual([0, 1]);

        functionWithSimpleFunctionPointer(fn);
        expect(TNSGetOutput()).toBe("4");
    });

    it("is called as a block after being a function pointer", function () {
        var blockCalls = [];
        var fn = new interop.FunctionReference(function (x) {
            blockCalls.push(x);
            return square(x);
        });

        functionWithSimpleFunctionPointer(fn);
        expect(TNSGetOutput()).toBe("4");

        TNSTestNativeCallbacks.repeatPausingAfter(2, fn);
        expect(blockCalls).toEqual([2, 0, 1]);

        TNSClearOutput();
        functionWithSimpleFunctionPointer(fn);
        expect(TNSGetOutput()).toBe("4");
    });

    it("keeps its function pointer across a second interop.FunctionReference", function () {
        var fn = new interop.FunctionReference(square);
        functionWithSimpleFunctionPointer(fn);
        var trampoline = interop.handleof(fn).toNumber();

        expect(new interop.FunctionReference(fn)).toBe(fn);
        expect(interop.handleof(fn).toNumber()).toBe(trampoline);
    });

    it("keeps its cached block across interop.FunctionReference", function () {
        var fn = function () {};
        TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1000);
        var block = interop.handleof(fn).toNumber();

        expect(new interop.FunctionReference(fn)).toBe(fn);
        expect(interop.handleof(fn).toNumber()).toBe(block);

        TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1000);
        expect(interop.handleof(fn).toNumber()).toBe(block);
    });

    it("is reported by interop.handleof as its function pointer once it has one", function () {
        var fn = function () {};
        TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1000);
        var block = interop.handleof(fn).toNumber();

        new interop.FunctionReference(fn);
        functionWithSimpleFunctionPointer(fn);
        var trampoline = interop.handleof(fn).toNumber();
        expect(trampoline).not.toBe(block);

        TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 1000);
        expect(interop.handleof(fn).toNumber()).toBe(trampoline);
    });

    it("throws when passed as a function pointer without interop.FunctionReference", function () {
        var fn = function () {};
        TNSTestNativeCallbacks.repeatPausingAfter(1, fn);
        expect(function () {
            functionWithSimpleFunctionPointer(fn);
        }).toThrowError(/FunctionReference/);
        expect(function () {
            functionWithSimpleFunctionPointer(function () {});
        }).toThrowError(/FunctionReference/);
    });

    it("is collected once its blocks are gone", function (done) {
        for (var i = 0; i < 50; i++) {
            var fn = new interop.FunctionReference(function () {});
            if (i % 2) {
                TNSTestNativeCallbacks.repeatPausingAfter(1, fn);
            } else {
                TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 5);
            }
        }
        setTimeout(function () {
            __collect();
            __collect();
            done();
        }, 50);
    });

    describe("in a worker", function () {
        var originalTimeout;
        beforeEach(function () {
            originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
            jasmine.DEFAULT_TIMEOUT_INTERVAL = 10000;
        });
        afterEach(function () {
            jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
        });

        it("is torn down while native code still holds its block", function (done) {
            var worker = new Worker("./functionReferenceBlockWorker.js");
            worker.onmessage = function (msg) {
                expect(msg.data).toEqual({ pointerOutput: "4", blockKept: true });
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
});
