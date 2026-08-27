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

    // Overwrites the stack region that held the creation locals so
    // conservative stack scanning cannot keep dead wrappers alive.
    function scrubStack() {
        return (function scrub(n) {
            return n > 0 ? scrub(n - 1) + n : 0;
        })(300);
    }

    // Retiring a registration has to reset the persistent, not just drop its
    // weakness: a handle left non-weak is a strong root, so the object it
    // names can never be collected again.
    it("frees the handle of an object retired by __releaseNativeCounterpart", function (done) {
        var ref;
        (function () {
            var obj = TNSObjCTypes.alloc().init();
            ref = new WeakRef(obj);
            __releaseNativeCounterpart(obj);
        })();

        scrubStack();
        __collect();
        setTimeout(function () {
            __collect();
            expect(ref.deref()).toBeUndefined();
            done();
        }, 0);
    });

    // Retirement reached from a -dealloc that a finalizer drove: it frees the
    // victim's state while the drain is mid-iteration over the handle table.
    it("retires another registration from a -dealloc reached by the drain", function () {
        var victims = [];
        var retired = 0;

        var DeallocRetire = TNSApi.extend({
            methodCalledInDealloc: function () {
                var victim = victims.pop();
                if (victim !== undefined) {
                    __releaseNativeCounterpart(victim);
                    retired++;
                }
            }
        }, { name: "TNSApiDeallocRetire" });

        // Kept alive by JS for the whole spec, so each retirement hits a live
        // registration rather than one the same GC already queued.
        var keepAlive = NSMutableArray.alloc().init();
        for (var i = 0; i < 8; i++) {
            var victim = TNSObjCTypes.alloc().init();
            keepAlive.addObject(victim);
            victims.push(victim);
        }

        (function () {
            var holder = NSMutableArray.alloc().init();
            for (var j = 0; j < 8; j++) {
                holder.addObject(DeallocRetire.alloc().init());
            }
        })();

        scrubStack();
        __collect();
        __collect();

        expect(retired).toBeGreaterThan(0);
        expect(keepAlive.count).toBe(8);
    });

    // Collection adapters reset their own persistent and delete wrappers from
    // -dealloc; a graph of them dies in one drain, so those resets land while
    // the finalizer that released the graph is still on the stack.
    it("survives adapter deallocs cascading out of a finalizer", function () {
        var rounds = 24;

        (function () {
            for (var i = 0; i < rounds; i++) {
                var holder = NSMutableArray.alloc().init();
                holder.addObject([1, 2, 3]);
                holder.addObject({ a: 1, b: 2 });
                holder.addObject(new Uint8Array(8));
                holder.addObject(NSMutableArray.arrayWithArray([[i], { i: i }]));
            }
        })();

        scrubStack();
        __collect();
        __collect();

        // A live adapter still answers after the sweep.
        var survivor = NSMutableArray.arrayWithArray([1, 2, 3]);
        expect(survivor.count).toBe(3);
        expect(survivor.objectAtIndex(1)).toBe(2);
    });

    // Allocation pressure shaped like the field workload: native lazy-global
    // paths (TextDecoder, atob/btoa) interleaved with adapter marshalling, so
    // a wrapper freed twice lands on somebody else's live allocation.
    function churn(rounds) {
        var decoder = new TextDecoder();
        var sink = 0;
        for (var i = 0; i < rounds; i++) {
            sink += decoder.decode(new Uint8Array([65, 66, 67, i % 128])).length;
            sink += atob(btoa("churn-" + i)).length;
            var probe = NSMutableArray.alloc().init();
            probe.addObject([i, i + 1]);
            probe.addObject(new Uint8Array(8));
            probe.addObject({ k: i });
            sink += probe.count;
        }
        return sink;
    }

    // The JS object's internal field owns the wrapper an adapter attaches to
    // it. When a finalizer drops the last native reference to the adapter, the
    // adapter's -dealloc detaches that wrapper from inside the disposal that
    // released it, so the disposal must not free what it read beforehand.
    it("releases adapters from inside a finalizer across repeated cycles", function () {
        var cycles = 12;

        for (var c = 0; c < cycles; c++) {
            (function () {
                var holders = [];
                for (var i = 0; i < 8; i++) {
                    // Each holder takes the only native reference to the
                    // adapters built for these collections.
                    var holder = NSMutableArray.alloc().init();
                    holder.addObject([c, i, i + 1]);
                    holder.addObject(new Uint8Array(16));
                    holder.addObject({ c: c, i: i });
                    holders.push(holder);
                }
            })();

            scrubStack();
            __collect();
            expect(churn(16)).toBeGreaterThan(0);
            __collect();
        }

        var survivor = NSMutableArray.arrayWithArray([1, 2, 3]);
        expect(survivor.count).toBe(3);
        expect(survivor.objectAtIndex(2)).toBe(3);
    });

    // Marshalling the same collection twice builds a second adapter for a JS
    // object whose field is already claimed. The second adapter must leave the
    // field alone, so that neither adapter's -dealloc frees the other's
    // wrapper, and both must still marshal back to the original JS object.
    it("survives a JS collection marshalled to native twice", function () {
        var rounds = 8;

        for (var r = 0; r < rounds; r++) {
            var arr = [r, r + 1, r + 2];
            var obj = { id: r, param: "abc" };
            var types = TNSObjCTypes.alloc().init();

            // objectAtIndex: on the outer adapter builds a fresh adapter for
            // the nested collection on every call.
            expect(types.methodWithNSArrayWrappingDictionary([obj])).toBe(obj);
            expect(types.methodWithNSArrayWrappingDictionary([obj])).toBe(obj);
            expect(types.methodWithNSArrayWrappingDictionary([arr])).toBe(arr);
            expect(types.methodWithNSArrayWrappingDictionary([arr])).toBe(arr);

            var first = NSMutableArray.alloc().init();
            first.addObject(arr);
            var second = NSMutableArray.alloc().init();
            second.addObject(arr);
            expect(first.count).toBe(1);
            expect(second.count).toBe(1);

            expect(churn(8)).toBeGreaterThan(0);
        }

        scrubStack();
        __collect();
        expect(churn(16)).toBeGreaterThan(0);
        __collect();

        var survivor = NSMutableArray.arrayWithArray([4, 5]);
        expect(survivor.count).toBe(2);
    });

    // A key enumerator reads the persistent its adapter owns, and the adapter
    // resets that persistent in -dealloc, so an enumeration keeps its adapter
    // alive for as long as the enumerator itself lives.
    it("keeps a dictionary adapter alive for its keys enumerator", function () {
        var rounds = 8;

        for (var r = 0; r < rounds; r++) {
            var types = TNSObjCTypes.alloc().init();
            // Fast enumeration over a foreign NSDictionary goes through
            // -keyEnumerator; the enumerator outlives the call that made it,
            // draining with the pool rather than with the adapter.
            var dictionary = { a: 3, b: { "-1": [4, 5] }, d: 6 };
            expect(types.methodWithNSDictionary(dictionary)).toBe(dictionary);
            TNSClearOutput();

            var map = new Map();
            map.set("a", 3);
            map.set("d", 6);
            expect(types.methodWithNSDictionary(map)).toBe(map);
            TNSClearOutput();

            expect(churn(8)).toBeGreaterThan(0);
        }

        scrubStack();
        __collect();
        expect(churn(16)).toBeGreaterThan(0);
        __collect();

        // A dictionary enumerated after the sweep still reports its keys.
        var late = { x: 1, y: 2 };
        expect(TNSObjCTypes.alloc().init().methodWithNSDictionary(late)).toBe(late);
        expect(TNSGetOutput()).toBe("x 1y 2");
        TNSClearOutput();
    });

    // The field crashes surfaced on worker isolates, where the same churn runs
    // and the isolate is torn down while adapters may still be alive.
    it("survives the same churn on a worker isolate", function (done) {
        var originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 15000;

        var worker = new Worker("./adapterChurnWorker.js");
        var rounds = 0;

        var finish = function () {
            jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
            worker.terminate();
            done();
        };

        worker.onmessage = function (msg) {
            expect(msg.data.ok).toBe(true);
            rounds++;
            if (rounds === 6) {
                finish();
                return;
            }
            worker.postMessage(rounds);
        };
        worker.onerror = function (e) {
            expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
            finish();
        };

        worker.postMessage(0);
    });

    // A natively held block's last release can land inside the finalizer
    // drain, where the JSBlock dispose helper must not touch handles itself.
    it("tears down a natively held block released by a finalizer", function (done) {
        var ref;
        (function () {
            var callback = function () {
                TNSLog("retained block called");
            };
            ref = new WeakRef(callback);

            var owner = TNSObjCTypes.alloc().init();
            owner.methodRetainingBlock(callback);
            owner.methodCallRetainingBlock();

            var holder = NSMutableArray.alloc().init();
            holder.addObject(owner);
        })();
        TNSClearOutput();

        scrubStack();
        // The deferred teardown runs on a later event-loop pass, so the
        // collectability check polls rather than assuming one tick suffices.
        var attempts = 20;
        (function pollCollected() {
            __collect();
            if (ref.deref() === undefined) {
                done();
                return;
            }
            if (--attempts === 0) {
                expect(ref.deref()).toBeUndefined();
                done();
                return;
            }
            setTimeout(pollCollected);
        })();
    });

    // Releasing the block detaches the function's wrapper, so a later
    // marshal of the same function must build a fresh block rather than
    // reaching for the dead one.
    it("re-marshals a function whose block was already released", function (done) {
        var callback = function () {
            TNSLog("re-marshalled block called");
        };

        var first = TNSObjCTypes.alloc().init();
        first.methodRetainingBlock(callback);
        first.methodReleaseRetainingBlock();
        first = null;

        // The block's remaining reference is the autoreleased one taken when
        // it was marshalled; it goes away with the pool at the end of the turn.
        setTimeout(function () {
            __collect();
            var second = TNSObjCTypes.alloc().init();
            second.methodRetainingBlock(callback);
            TNSClearOutput();
            second.methodCallRetainingBlock();

            expect(TNSGetOutput()).toBe("re-marshalled block called");
            TNSClearOutput();
            done();
        }, 0);
    });
});
