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

    // A GcProtected (natively retained) instance is resurrected by its
    // finalizer, but anything reachable only through it is queued in the same
    // GC and disposed — the resurrected parent then holds "husks" whose
    // internal field was neutered to undefined. Touching a husk must never
    // read the dead field as an External (which fabricates a garbage wrapper
    // pointer — the unguarded behavior segfaulted in
    // Interop::SetStructPropertyValue). Under the default
    // releasedObjectPolicy ("report") the operation no-ops and a
    // `releasednativeaccess` event fires (deduplicated per object); under
    // "throw" it throws a catchable ReferenceError. See the "Known hazard"
    // section of docs/knowledge/v8-resurrecting-finalizers.md.
    it("reports or throws (never crashes) when touching a released object through a resurrected parent", function (done) {
        // Only the TypeScript __extends path installs the retain/release
        // swizzles that GcProtect (and thus resurrection) depends on.
        var HuskParent = (function (_super) {
            __extends(HuskParent, _super);
            function HuskParent() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return HuskParent;
        })(NSObject);

        var N = 16;
        var holder = NSMutableArray.alloc().init();

        (function create() {
            for (var i = 0; i < N; i++) {
                var t = HuskParent.alloc().init();
                t.buddy = CGPointMake(3, 4);
                t.__mine = true;
                holder.addObject(t); // native-only retain → GcProtect
            }
        })();

        // Overwrite the stack region that held the creation locals so
        // conservative stack scanning cannot keep the dead wrappers alive.
        (function scrub(n) {
            return n > 0 ? scrub(n - 1) + n : 0;
        })(300);
        __collect();
        __collect();

        var husks = [];
        for (var i = 0; i < N; i++) {
            var t2 = holder.objectAtIndex(i);
            if (t2.__mine !== true) {
                // Wrapper was disposed instead of resurrected — not this
                // spec's scenario.
                continue;
            }
            var b = t2.buddy;
            var neutered = false;
            try {
                interop.handleof(b);
            } catch (e) {
                neutered = true;
            }
            if (neutered) {
                husks.push(b);
            }
        }

        // Zero husks is a legal (if unlucky) outcome — the assertions below
        // are the guard; this log keeps the coverage observable.
        TNSLog("husk spec: " + husks.length + "/" + N + " husks formed");
        if (husks.length === 0) {
            done();
            return;
        }

        var events = [];
        var onReleased = function (e) {
            events.push(e);
        };
        global.addEventListener("releasednativeaccess", onReleased);

        var husk = husks[0];
        var rect = CGRectMake(0, 0, 100, 100);

        // Default policy: report — the operations no-op.
        rect.origin = husk;
        expect(rect.origin.x).toBe(0);
        expect(husk.x).toBeUndefined();

        // Throw policy: same touches become catchable ReferenceErrors.
        var runtime = require("ns:runtime");
        runtime.setConfig("releasedObjectPolicy", "throw");
        expect(function () {
            rect.origin = husk;
        }).toThrowError(/released/);
        expect(function () {
            return husk.x;
        }).toThrowError(/released/);
        runtime.setConfig("releasedObjectPolicy", "report");

        // The event dispatches on the microtask queue; assert after a turn.
        setTimeout(function () {
            global.removeEventListener("releasednativeaccess", onReleased);
            // One event: the first touch reports, the second is deduplicated
            // per object, and throw-mode touches never report.
            expect(events.length).toBe(1);
            expect(events[0].operation).toBe("struct field assignment");
            expect(String(events[0].error)).toMatch(/released/);
            done();
        }, 0);
    });
});
