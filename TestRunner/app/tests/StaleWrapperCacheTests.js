describe("Instance cache staleness", function () {
    var ITERATIONS = 100;

    // NSObject (isa only) and TNSBaseInterface (isa + two ints) both land in the
    // 16-byte malloc bucket, so a TNSBaseInterface allocated after an NSObject is
    // freed can be handed the very same address.
    it("never hands out a wrapper built for an object that no longer lives at that address", function (done) {
        for (var i = 0; i < ITERATIONS; i++) {
            var original = NSObject.alloc().init();
            var alias = new NSObject(interop.handleof(original));
            if (i === 0) {
                expect(alias).toBe(original);
            }
            original = null;
            alias = null;
        }

        // An address can only be recycled once the runloop has drained its
        // autorelease pool, so the reallocation half has to run in a later turn.
        setTimeout(function () {
            var wrongPrototype = 0;
            var missingMethod = 0;
            var instances = [];

            for (var j = 0; j < ITERATIONS; j++) {
                var instance = TNSBaseInterface.alloc().init();
                instances.push(instance);

                if (Object.getPrototypeOf(instance) !== TNSBaseInterface.prototype) {
                    wrongPrototype++;
                }
                if (typeof instance.baseProtocolMethod2Optional !== "function") {
                    missingMethod++;
                }
            }

            expect(wrongPrototype).toBe(0, "instances built on a reused address got a foreign prototype");
            expect(missingMethod).toBe(0, "instances built on a reused address lost their protocol methods");

            instances = null;
            done();
        }, 0);
    });
});
