// WeakMap, WeakSet, WeakRef and FinalizationRegistry keyed on native objects.
// The expectations hold in every wrapper lifetime mode; under "canary" they
// depend on the weak collections keying a native object by its lifetime key
// rather than by its current wrapper.
describe("Weak collections of native objects", function () {
    var runtime = require("ns:runtime");
    var canary = runtime.getConfig("wrapperLifetimeMode") === "canary";

    var Extended = (function (_super) {
        __extends(Extended, _super);
        function Extended() {
            return (_super !== null && _super.apply(this, arguments)) || this;
        }
        return Extended;
    })(TNSAllocLog);

    function scrub(n) {
        return n > 0 ? scrub(n - 1) + n : 0;
    }

    function settle(rounds, callback) {
        scrub(300);
        __collect();
        __collect();
        setTimeout(function () {
            NSObject.new();
            if (rounds > 1) {
                settle(rounds - 1, callback);
            } else {
                callback();
            }
        }, 10);
    }

    it("keeps a WeakMap entry for a native object across a wrapper change", function (done) {
        var owner = NSMutableArray.new();
        var map = new WeakMap();
        var before = runtime.getWrapperLifetimeStats();
        (function () {
            var obj = Extended.new();
            map.set(obj, "value");
            owner.addObject(obj);
        })();
        settle(2, function () {
            if (canary) {
                // The first wrapper died; the entry belongs to the native object.
                expect(runtime.getWrapperLifetimeStats().queuedReleases).toBeGreaterThan(before.queuedReleases);
            }
            var obj = owner.objectAtIndex(0);
            expect(map.get(obj)).toBe("value");
            expect(map.has(obj)).toBe(true);
            expect(map.delete(obj)).toBe(true);
            expect(map.has(obj)).toBe(false);
            done();
        });
    });

    it("keeps a WeakSet member for a native object across a wrapper change", function (done) {
        var owner = NSMutableArray.new();
        var set = new WeakSet();
        (function () {
            var obj = Extended.new();
            set.add(obj);
            owner.addObject(obj);
        })();
        settle(2, function () {
            expect(set.has(owner.objectAtIndex(0))).toBe(true);
            done();
        });
    });

    it("dereferences a WeakRef to a natively owned object while the object lives", function (done) {
        var owner = NSMutableArray.new();
        var ref;
        (function () {
            var obj = Extended.new();
            obj.tag = "kept";
            ref = new WeakRef(obj);
            owner.addObject(obj);
        })();
        settle(2, function () {
            var target = ref.deref();
            expect(target).toBe(owner.objectAtIndex(0));
            expect(target.tag).toBe("kept");
            expect(ref.get()).toBe(target);
            done();
        });
    });

    it("clears a WeakRef once the native object is gone", function (done) {
        var owner = NSMutableArray.new();
        var ref;
        (function () {
            var obj = Extended.new();
            ref = new WeakRef(obj);
            owner.addObject(obj);
        })();
        settle(2, function () {
            owner.removeAllObjects();
            var attempts = 10;
            (function poll() {
                settle(1, function () {
                    if (ref.deref() === undefined || --attempts === 0) {
                        expect(ref.deref()).toBeUndefined();
                        done();
                        return;
                    }
                    poll();
                });
            })();
        });
    });

    it("runs a FinalizationRegistry callback once the native object is gone", function (done) {
        var owner = NSMutableArray.new();
        var held = [];
        var registry = new FinalizationRegistry(function (value) {
            held.push(value);
        });
        (function () {
            var obj = Extended.new();
            registry.register(obj, "held");
            owner.addObject(obj);
        })();
        settle(2, function () {
            expect(held).toEqual([]);
            owner.removeAllObjects();
            var attempts = 15;
            (function poll() {
                settle(1, function () {
                    if (held.length > 0 || --attempts === 0) {
                        expect(held).toEqual(["held"]);
                        done();
                        return;
                    }
                    poll();
                });
            })();
        });
    });

    it("keeps a getOrInsert entry for a native object across a wrapper change", function (done) {
        if (typeof WeakMap.prototype.getOrInsert !== "function") {
            done();
            return;
        }
        var owner = NSMutableArray.new();
        var map = new WeakMap();
        var seenKey;
        (function () {
            var obj = Extended.new();
            expect(map.getOrInsert(obj, "value")).toBe("value");
            var other = Extended.new();
            expect(map.getOrInsertComputed(other, function (key) {
                seenKey = key;
                return "computed";
            })).toBe("computed");
            expect(seenKey).toBe(other);
            owner.addObject(obj);
            owner.addObject(other);
        })();
        settle(2, function () {
            expect(map.get(owner.objectAtIndex(0))).toBe("value");
            expect(map.get(owner.objectAtIndex(1))).toBe("computed");
            done();
        });
    });

    it("unregisters a FinalizationRegistry target through a later wrapper of its token", function (done) {
        var owner = NSMutableArray.new();
        var registry = new FinalizationRegistry(function () {});
        var target = {};
        (function () {
            var obj = Extended.new();
            registry.register(target, "held", obj);
            owner.addObject(obj);
        })();
        settle(2, function () {
            expect(registry.unregister(owner.objectAtIndex(0))).toBe(true);
            target = null;
            expect(FinalizationRegistry.length).toBe(1);
            done();
        });
    });

    it("keys a Proxy around a native object by the Proxy", function () {
        var obj = Extended.new();
        var proxy = new Proxy(obj, {});
        var map = new WeakMap();
        map.set(obj, "target");
        expect(map.has(proxy)).toBe(false);
        map.set(proxy, "proxy");
        expect(map.get(obj)).toBe("target");
        expect(map.get(proxy)).toBe("proxy");
        expect(new WeakRef(proxy).deref()).toBe(proxy);
    });

    it("does not give state to a native object a lookup only probes", function () {
        var before = runtime.getWrapperLifetimeStats();
        var map = new WeakMap();
        var set = new WeakSet();
        for (var i = 0; i < 8; i++) {
            var obj = Extended.new();
            map.has(obj);
            map.get(obj);
            map.delete(obj);
            set.has(obj);
        }
        if (canary) {
            expect(runtime.getWrapperLifetimeStats().canaryStates).toBe(before.canaryStates);
        }
    });

    it("keeps working as the standard collections for other keys", function () {
        var key = {};
        var map = new WeakMap([[key, 1]]);
        expect(map.get(key)).toBe(1);
        expect(map instanceof WeakMap).toBe(true);
        expect(new WeakSet([key]).has(key)).toBe(true);
        expect(new WeakRef(key).deref()).toBe(key);
    });

    it("iterates NSArray wrappers through the prototype", function () {
        var array = NSArray.arrayWithArray([1, 2, 3]);
        var seen = [];
        for (var value of array) {
            seen.push(value);
        }
        expect(seen).toEqual([1, 2, 3]);
        expect([].concat(Array.from(NSMutableArray.arrayWithArray(["a"])))).toEqual(["a"]);
        expect(Object.getOwnPropertySymbols(array).length).toBe(0);
    });

    // A JS class gets a fast-enumeration override only for an iterator it
    // defines itself, not for the one it inherits from NSArray.
    it("enumerates natively a JS subclass of NSArray that inherits the iterator", function () {
        var Pair = (function (_super) {
            __extends(Pair, _super);
            function Pair() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Pair.prototype.objectAtIndex = function (index) {
                return index === 0 ? "first" : "second";
            };
            Object.defineProperty(Pair.prototype, "count", {
                get: function () {
                    return 2;
                },
                enumerable: true,
                configurable: true
            });
            return Pair;
        })(NSArray);
        var pair = Pair.alloc().init();
        TNSClearOutput();
        TNSObjCTypes.alloc().init().methodWithNSArray(pair);
        expect(TNSGetOutput()).toBe("firstsecond");
        TNSClearOutput();
    });
});
