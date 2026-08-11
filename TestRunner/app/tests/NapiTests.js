describe("Node-API addon", function () {
    var napi = require("napitestmodule");

    it("exports the addon's functions", function () {
        expect(typeof napi).toBe("object");
        expect(typeof napi.echoString).toBe("function");
        expect(typeof napi.doubleNumber).toBe("function");
        expect(typeof napi.negateBool).toBe("function");
        expect(typeof napi.transformObject).toBe("function");
        expect(typeof napi.transformArray).toBe("function");
        expect(typeof napi.throwError).toBe("function");
        expect(typeof napi.wrapValue).toBe("function");
        expect(typeof napi.unwrapValue).toBe("function");
        expect(typeof napi.finalizerRan).toBe("function");
        expect(typeof napi.resetFinalizerFlag).toBe("function");
        expect(typeof napi.holdRef).toBe("function");
        expect(typeof napi.getRef).toBe("function");
        expect(typeof napi.releaseRef).toBe("function");
    });

    it("is instantiated once per env", function () {
        expect(require("napitestmodule")).toBe(napi);
    });

    it("round-trips a string", function () {
        expect(napi.echoString("hello")).toBe("hello");
        expect(napi.echoString("")).toBe("");
        expect(napi.echoString("ünïcödé ☃")).toBe("ünïcödé ☃");
    });

    it("round-trips a number", function () {
        expect(napi.doubleNumber(21)).toBe(42);
        expect(napi.doubleNumber(-1.5)).toBe(-3);
    });

    it("round-trips a bool", function () {
        expect(napi.negateBool(true)).toBe(false);
        expect(napi.negateBool(false)).toBe(true);
    });

    it("reads a property and builds a new object", function () {
        var result = napi.transformObject({ value: 4, ignored: "x" });
        expect(result.value).toBe(8);
        expect(result.tag).toBe("napi");
        expect(result.ignored).toBeUndefined();
    });

    it("reads an array and builds a new array", function () {
        var result = napi.transformArray([7, 8, 9]);
        expect(Array.isArray(result)).toBe(true);
        expect(result.length).toBe(2);
        expect(result[0]).toBe(3);
        expect(result[1]).toBe(7);

        expect(napi.transformArray([])).toEqual([0, 0]);
    });

    it("throws a catchable Error carrying a code", function () {
        var error;
        try {
            napi.throwError();
        } catch (e) {
            error = e;
        }
        expect(error instanceof Error).toBe(true);
        expect(error.message).toBe("napi test failure");
        expect(error.code).toBe("ERR_TEST_CODE");
    });

    describe("napi_define_properties", function () {
        it("defines a value property", function () {
            var descriptor = Object.getOwnPropertyDescriptor(napi, "moduleName");
            expect(descriptor.value).toBe("napitestmodule");
            expect(descriptor.get).toBeUndefined();
            expect(descriptor.enumerable).toBe(true);
        });

        it("defines an accessor property", function () {
            var descriptor = Object.getOwnPropertyDescriptor(napi, "wrapCount");
            expect(typeof descriptor.get).toBe("function");
            expect(descriptor.value).toBeUndefined();

            var before = napi.wrapCount;
            napi.wrapValue({}, 1);
            expect(napi.wrapCount).toBe(before + 1);
        });
    });

    describe("napi_wrap", function () {
        it("unwraps the payload it wrapped", function () {
            var target = {};
            expect(napi.wrapValue(target, 3.5)).toBe(target);
            expect(napi.unwrapValue(target)).toBe(3.5);
        });

        it("runs the finalizer once the wrapper is collected", function (done) {
            napi.resetFinalizerFlag();
            expect(napi.finalizerRan()).toBe(false);

            (function () {
                napi.wrapValue({}, 11);
            })();

            // Conservative stack scanning keeps the dead wrapper alive until
            // the loop below overwrites the frame that held it.
            __collect();
            var sink = 0;
            for (var i = 0; i < 200000; i++) {
                sink += i % 7;
            }
            __collect();

            expect(sink).toBeGreaterThan(0);

            // Node-API finalizers are queued from the weak callback and drained
            // on the next runloop turn, never inside the collection itself.
            expect(napi.finalizerRan()).toBe(false);
            setTimeout(function () {
                expect(napi.finalizerRan()).toBe(true);
                done();
            }, 0);
        });
    });

    describe("napi_create_reference", function () {
        afterEach(function () {
            napi.releaseRef();
        });

        it("holds and returns the referenced value", function () {
            var held = { id: "held" };
            napi.holdRef(held);
            expect(napi.getRef()).toBe(held);
            expect(napi.getRef()).toBe(held);
        });

        it("returns undefined once released", function () {
            napi.holdRef({ id: "held" });
            expect(napi.releaseRef()).toBe(true);
            expect(napi.getRef()).toBeUndefined();
            expect(napi.releaseRef()).toBe(false);
        });
    });
});
