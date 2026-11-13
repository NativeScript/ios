describe("Wrapper lifetime", function () {
    var runtime = require("ns:runtime");

    function releasedObject() {
        var obj = NSObject.alloc().init();
        __releaseNativeCounterpart(obj);
        return obj;
    }

    function stats() {
        return runtime.getWrapperLifetimeStats();
    }

    // The state-lost confirmation runs on the event loop's internal lane, not
    // necessarily before the next timer.
    function afterTurns(turns, callback) {
        setTimeout(function () {
            if (turns > 1) {
                afterTurns(turns - 1, callback);
            } else {
                callback();
            }
        }, 10);
    }

    afterEach(function () {
        runtime.setConfig("releasedObjectPolicy", "report");
    });

    describe("released objects reaching native code", function () {
        it("passes nil, not a dictionary, for a released argument under the report policy", function (done) {
            var released = releasedObject();
            var events = [];
            var onReleased = function (e) {
                events.push(e);
            };
            global.addEventListener("releasednativeaccess", onReleased);

            var dict = NSMutableDictionary.new();
            dict.setValueForKey(released, "key");
            expect(dict.count).toBe(0);

            setTimeout(function () {
                global.removeEventListener("releasednativeaccess", onReleased);
                expect(events.length).toBe(1);
                expect(events[0].error.message).toMatch(/__releaseNativeCounterpart/);
                expect(events[0].error.message).toMatch(/native argument/);
                done();
            });
        });

        it("throws a ReferenceError for a released argument under the throw policy", function () {
            var released = releasedObject();
            runtime.setConfig("releasedObjectPolicy", "throw");
            var dict = NSMutableDictionary.new();
            expect(function () {
                dict.setValueForKey(released, "key");
            }).toThrowError(ReferenceError, /released by __releaseNativeCounterpart/);
            expect(dict.count).toBe(0);
        });

        it("uses NSNull for a released collection element", function () {
            var released = releasedObject();
            var array = NSArray.arrayWithArray([released]);
            expect(array.count).toBe(1);
            var element = array.objectAtIndex(0);
            expect(element === null || element instanceof NSNull).toBe(true);
        });

        it("throws a ReferenceError when a released object is a method receiver", function () {
            var released = releasedObject();
            expect(function () {
                released.isEqual(null);
            }).toThrowError(ReferenceError, /released by __releaseNativeCounterpart/);
        });

        it("throws a ReferenceError when reading a property of a released object", function () {
            var released = releasedObject();
            expect(function () {
                return released.description;
            }).toThrowError(ReferenceError, /released by __releaseNativeCounterpart/);
        });

        it("marks the target when released through a Proxy", function () {
            var target = NSObject.alloc().init();
            var proxy = new Proxy(target, {});
            __releaseNativeCounterpart(proxy);
            expect(function () {
                target.isEqual(null);
            }).toThrowError(ReferenceError, /released by __releaseNativeCounterpart/);
            expect(function () {
                proxy.isEqual(null);
            }).toThrowError(ReferenceError, /released by __releaseNativeCounterpart/);
        });

        it("counts explicit releases and released accesses", function () {
            var before = stats();
            var released = releasedObject();
            expect(stats().releasedExplicitly).toBe(before.releasedExplicitly + 1);
            try {
                released.isEqual(null);
            } catch (e) {
            }
            expect(stats().releasedAccesses).toBe(before.releasedAccesses + 1);
        });
    });

    // A natively retained JS-extended object is resurrected by its finalizer,
    // while a native object referenced only from its JS state is released in
    // the same collection: the shape behind native crashes where the released
    // object reached UIKit as a dictionary. Zero husks is a legal (if unlucky)
    // outcome, as in GCFinalizerTests.
    it("names garbage collection as the reason for an object released under a resurrected holder", function () {
        if (runtime.getConfig("wrapperLifetimeMode") !== "resurrecting") {
            // Nothing is resurrected, so nothing reachable is released.
            return;
        }
        var Holder = (function (_super) {
            __extends(Holder, _super);
            function Holder() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return Holder;
        })(NSObject);

        var N = 16;
        var owner = NSMutableArray.alloc().init();
        var before = stats();
        (function create() {
            for (var i = 0; i < N; i++) {
                var holder = Holder.alloc().init();
                holder.state = { item: NSObject.alloc().init() };
                owner.addObject(holder);
            }
        })();
        (function scrub(n) {
            return n > 0 ? scrub(n - 1) + n : 0;
        })(300);
        __collect();
        __collect();

        expect(stats().resurrections).toBeGreaterThan(before.resurrections);

        var husks = 0;
        for (var i = 0; i < N; i++) {
            var holder = owner.objectAtIndex(i);
            if (holder.state === undefined) {
                continue;
            }
            try {
                holder.state.item.isEqual(null);
            } catch (e) {
                expect(e instanceof ReferenceError).toBe(true);
                expect(e.message).toMatch(/garbage collected/);
                husks++;
            }
        }
        TNSLog("wrapper lifetime spec: " + husks + "/" + N + " husks formed");
    });

    it("reports JS state lost on a wrapper whose native object lives on", function (done) {
        if (runtime.getConfig("wrapperLifetimeMode") !== "resurrecting") {
            // Rooted wrappers keep their state; unrooted ones die in a phantom
            // callback, where their properties can no longer be read.
            done();
            return;
        }
        var previous = runtime.getConfig("wrapperLifetimeWarnings");
        runtime.setConfig("wrapperLifetimeWarnings", true);
        var N = 16;
        var owner = NSMutableArray.alloc().init();
        var before = stats();
        (function create() {
            for (var i = 0; i < N; i++) {
                var obj = NSObject.alloc().init();
                obj.jsState = i;
                owner.addObject(obj);
            }
        })();
        (function scrub(n) {
            return n > 0 ? scrub(n - 1) + n : 0;
        })(300);
        __collect();
        __collect();

        afterTurns(5, function () {
            var after = stats();
            runtime.setConfig("wrapperLifetimeWarnings", previous);
            expect(after.stateLostCandidates).toBeGreaterThan(before.stateLostCandidates);
            expect(after.stateLostConfirmed).toBeGreaterThan(before.stateLostConfirmed);
            expect(owner.objectAtIndex(0).jsState).toBeUndefined();
            done();
        });
    });

    it("does not report state lost when nothing native keeps the object", function (done) {
        var previous = runtime.getConfig("wrapperLifetimeWarnings");
        runtime.setConfig("wrapperLifetimeWarnings", true);
        // Settle earlier specs' garbage first, so only this spec's objects
        // can move the counter.
        __collect();
        __collect();
        afterTurns(5, function () {
            var before = stats();
            (function create() {
                for (var i = 0; i < 16; i++) {
                    var obj = NSObject.alloc().init();
                    obj.jsState = i;
                }
            })();
            (function scrub(n) {
                return n > 0 ? scrub(n - 1) + n : 0;
            })(300);
            __collect();
            __collect();

            afterTurns(5, function () {
                var after = stats();
                runtime.setConfig("wrapperLifetimeWarnings", previous);
                expect(after.stateLostConfirmed).toBe(before.stateLostConfirmed);
                done();
            });
        });
    });

    it("exposes numeric counters", function () {
        var current = stats();
        expect(Object.keys(current).sort()).toEqual([
            "collected",
            "releasedAccesses",
            "releasedExplicitly",
            "resurrections",
            "demotions",
            "promotions",
            "queuedReleases",
            "stateLostCandidates",
            "stateLostConfirmed",
        ].sort());
        Object.keys(current).forEach(function (key) {
            expect(typeof current[key]).toBe("number");
        });
    });

    it("validates the wrapperLifetimeWarnings config key", function () {
        var previous = runtime.getConfig("wrapperLifetimeWarnings");
        expect(typeof previous).toBe("boolean");
        expect(function () {
            runtime.setConfig("wrapperLifetimeWarnings", "yes");
        }).toThrowError(TypeError, /'wrapperLifetimeWarnings' must be a boolean/);
        runtime.setConfig("wrapperLifetimeWarnings", !previous);
        expect(runtime.getConfig("wrapperLifetimeWarnings")).toBe(!previous);
        runtime.setConfig("wrapperLifetimeWarnings", previous);
    });
});
