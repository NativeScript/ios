describe("primordials", function () {
    const boom = function () {
        throw new Error("intrinsic tampered");
    };

    // Tampering with the intrinsics breaks Jasmine and most of the runtime as
    // well, so the tampered window stays synchronous and assertion-free:
    // results go into locals, the originals come back in a finally, and only
    // then do the expectations run. Nothing inside the window may use an array
    // method or `.call` either — plain indexing and direct calls only.
    function withTampered(patches, body) {
        const originals = [];
        for (let i = 0; i < patches.length; i++) {
            originals[i] = patches[i][0][patches[i][1]];
        }
        try {
            for (let i = 0; i < patches.length; i++) {
                patches[i][0][patches[i][1]] = boom;
            }
            return body();
        } finally {
            for (let i = 0; i < patches.length; i++) {
                patches[i][0][patches[i][1]] = originals[i];
            }
        }
    }

    const arrayAndCall = [
        [Array.prototype, "slice"],
        [Array.prototype, "indexOf"],
        [Array.prototype, "push"],
        [Array.prototype, "splice"],
        [Function.prototype, "call"],
    ];

    it("the tampering used by this suite is actually observable", function () {
        const outcome = withTampered(arrayAndCall, function () {
            try {
                [1, 2].slice(0);
                return "no throw";
            } catch (e) {
                return e.message;
            }
        });

        expect(outcome).toBe("intrinsic tampered");
        expect([1, 2].slice(0).length).toBe(2);
    });

    it("global dispatchEvent delivers to every listener while intrinsics are tampered", function () {
        const seen = [];
        const first = function (e) { seen[seen.length] = "first:" + e.type; };
        const second = { handleEvent: function (e) { seen[seen.length] = "second:" + e.type; } };
        const event = new Event("primordials-dispatch");

        global.addEventListener("primordials-dispatch", first);
        global.addEventListener("primordials-dispatch", second);

        let dispatchResult;
        try {
            dispatchResult = withTampered(arrayAndCall, function () {
                return global.dispatchEvent(event);
            });
        } finally {
            global.removeEventListener("primordials-dispatch", first);
            global.removeEventListener("primordials-dispatch", second);
        }

        expect(dispatchResult).toBe(true);
        expect(seen.join(",")).toBe("first:primordials-dispatch,second:primordials-dispatch");
    });

    it("addEventListener/removeEventListener and once work while intrinsics are tampered", function () {
        const calls = [];
        const persistent = function () { calls[calls.length] = "persistent"; };
        const onceOnly = function () { calls[calls.length] = "once"; };

        try {
            withTampered(arrayAndCall, function () {
                global.addEventListener("primordials-registration", persistent);
                global.addEventListener("primordials-registration", onceOnly, { once: true });
                global.dispatchEvent(new Event("primordials-registration"));
                global.dispatchEvent(new Event("primordials-registration"));
                global.removeEventListener("primordials-registration", persistent);
                global.dispatchEvent(new Event("primordials-registration"));
            });
        } finally {
            global.removeEventListener("primordials-registration", persistent);
            global.removeEventListener("primordials-registration", onceOnly);
        }

        expect(calls.join(",")).toBe("persistent,once,persistent");
    });

    it("reportError still reaches an error listener while intrinsics are tampered", function () {
        let received = null;
        // preventDefault keeps the unhandled tail (which aborts the process)
        // out of the picture.
        const onError = function (e) {
            received = e;
            e.preventDefault();
        };
        const error = new Error("primordials-report");

        global.addEventListener("error", onError);
        try {
            withTampered(arrayAndCall, function () {
                global.reportError(error);
            });
        } finally {
            global.removeEventListener("error", onError);
        }

        expect(received).not.toBeNull();
        expect(received.type).toBe("error");
        expect(received.error).toBe(error);
        expect(received.message).toBe("primordials-report");
    });

    it("console.log of a circular object neither throws nor crashes with JSON.stringify tampered", function () {
        // The smart-stringify builtin both calls JSON.stringify and tracks
        // already-visited objects with Array.prototype.indexOf/push. Its output
        // is not reachable from JS and JsonStringifyObject swallows a throwing
        // stringify, so this only pins down that the tampered path stays
        // non-fatal; the primordial routing itself is covered by review.
        const circular = { name: "primordials" };
        circular.self = circular;

        let threw = null;
        try {
            withTampered([
                [JSON, "stringify"],
                [Array.prototype, "indexOf"],
                [Array.prototype, "push"],
            ], function () {
                console.log(circular);
            });
        } catch (e) {
            threw = e;
        }

        expect(threw).toBeNull();
    });

    it("a native super called with arguments works while intrinsics are tampered", function () {
        // ts-helpers routes `_super.call(this, x)` over a native base through
        // Array.prototype.slice and Reflect.construct.
        const PrimordialsSubclass = (function (_super) {
            global.__extends(PrimordialsSubclass, _super);
            function PrimordialsSubclass(x) {
                return _super.call(this, x) || this;
            }
            return PrimordialsSubclass;
        }(TNSCInterface));

        // The first construction is what registers the Objective-C class, and
        // that has to happen with the intrinsics intact.
        new PrimordialsSubclass(1);

        TNSClearOutput();
        let threw = null;
        try {
            withTampered([
                [Array.prototype, "slice"],
                [Array.prototype, "concat"],
                [Function.prototype, "bind"],
                [Reflect, "construct"],
            ], function () {
                return new PrimordialsSubclass(7);
            });
        } catch (e) {
            threw = e;
        }

        expect(threw).toBeNull();
        expect(TNSGetOutput()).toBe("initWithPrimitive:7 called");
        TNSClearOutput();
    });

    it("__extends and __tsEnum work while Object intrinsics are tampered", function () {
        function Base() { }
        Base.prototype.hello = function () { return "hello"; };
        Base.staticMember = 1;
        function Derived() { }

        let enumerated = null;
        let threw = null;
        try {
            withTampered([
                [Object, "create"],
                [Object, "keys"],
                [Object, "setPrototypeOf"],
                [Object.prototype, "hasOwnProperty"],
                [Function.prototype, "call"],
            ], function () {
                global.__extends(Derived, Base);
                enumerated = global.__tsEnum({ First: 0, Second: 1 });
            });
        } catch (e) {
            threw = e;
        }

        expect(threw).toBeNull();
        expect(new Derived().hello()).toBe("hello");
        expect(Derived.staticMember).toBe(1);
        expect(enumerated.First).toBe(0);
        expect(enumerated[0]).toBe("First");
    });
});
