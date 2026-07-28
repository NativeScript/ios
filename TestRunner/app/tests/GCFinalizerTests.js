describe("GC finalizer callbacks", function () {
    // A finalizer callback runs from V8's GC epilogue. Since 14.9,
    // Heap::CollectGarbage holds a DisallowJavascriptExecution across the whole
    // collection, so entering JS from one is a GRACEFUL_FATAL that aborts the
    // process rather than throwing. The runtime reaches JS on that path
    // whenever disposing a wrapper releases an ObjC object whose -dealloc hits
    // a JS-implemented override, which is why v8_resurrecting_finalizers.patch
    // lifts the scope for the finalizer drain. Without that lift this spec does
    // not fail, it kills the test host.
    it("may run a JS override reached from -dealloc", function () {
        var calls = 0;

        var DeallocReentry = TNSApi.extend({
            methodCalledInDealloc: function () {
                calls++;
            }
        }, { name: "TNSApiDeallocReentry" });

        // The holder is released by its own finalizer, and releasing it drops
        // the last reference to the subclass instance, so the override runs
        // inside the GC callback rather than from ordinary JS.
        (function () {
            var holder = NSMutableArray.alloc().init();
            holder.addObject(DeallocReentry.alloc().init());
        })();

        __collect();
        var sink = 0;
        for (var i = 0; i < 200000; i++) {
            sink += i % 7;
        }
        __collect();

        expect(sink).toBeGreaterThan(0);
        expect(calls).toBe(1);
    });
});
