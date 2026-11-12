// Wrapper lifetime under the configured mode ("wrapperLifetime" in the app
// config). The suite runs under the default mode; the other expectations run
// when the TestRunner app is configured with "mode": "rooted" or "canary".
describe("Wrapper lifetime modes", function () {
    var runtime = require("ns:runtime");
    var mode = runtime.getConfig("wrapperLifetimeMode");
    var scope = runtime.getConfig("wrapperLifetimeScope");
    var rooted = mode === "rooted";
    var canary = mode === "canary";
    // JS state on a natively owned object survives its wrapper's death.
    var keepsState = rooted || canary;

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

    // Watches specific objects without retaining them; unlike the dealloc log,
    // it ignores objects earlier specs left to the collector.
    function watch(obj) {
        var table = NSHashTable.weakObjectsHashTable();
        table.addObject(obj);
        return table;
    }

    function alive(table) {
        return table.allObjects.count;
    }

    function deallocs() {
        return (TNSGetOutput().match(/TNSAllocLog dealloc/g) || []).length;
    }

    // Collect, then let the release queue drain (it drains on the event loop
    // and on entry to native calls).
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

    beforeEach(function () {
        TNSClearOutput();
    });

    // The name carries the mode so a run's log shows which one it exercised.
    it("reports the configured mode and scope (" + mode + "/" + scope + ")", function () {
        expect(["resurrecting", "rooted", "canary"].indexOf(mode)).not.toBe(-1);
        expect(["extended", "all"].indexOf(scope)).not.toBe(-1);
        expect(function () {
            runtime.setConfig("wrapperLifetimeMode", "rooted");
        }).toThrowError(TypeError, /read-only/);
    });

    it("keeps the JS state of a natively owned JS-extended object and everything it references", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var holder = Extended.new();
            holder.state = { item: TNSAllocLog.new() };
            owner.addObject(holder);
        })();
        settle(2, function () {
            var holder = owner.objectAtIndex(0);
            if (keepsState) {
                expect(holder.state).toBeDefined();
                expect(function () {
                    holder.state.item.isEqual(null);
                }).not.toThrow();
            }
            done();
        });
    });

    it("keeps the JS state of a natively owned plain object when every wrapper is in scope", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = TNSAllocLog.new();
            obj.state = { value: 42 };
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            if (keepsState && scope === "all") {
                expect(obj.state && obj.state.value).toBe(42);
            }
            done();
        });
    });

    it("keeps WeakMap entries and WeakRef targets of natively owned objects when every wrapper is rooted", function (done) {
        var owner = NSMutableArray.new();
        var map = new WeakMap();
        var ref;
        (function () {
            var obj = TNSAllocLog.new();
            map.set(obj, "value");
            ref = new WeakRef(obj);
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            if (rooted && scope === "all") {
                expect(map.get(obj)).toBe("value");
                expect(ref.deref()).toBe(obj);
            }
            done();
        });
    });

    it("collects objects only JS references", function (done) {
        var N = 16;
        (function () {
            for (var i = 0; i < N; i++) {
                var obj = i % 2 === 0 ? Extended.new() : TNSAllocLog.new();
                obj.state = { i: i };
            }
        })();
        settle(2, function () {
            expect(deallocs()).toBeGreaterThan(N / 2);
            done();
        });
    });

    it("frees a natively owned object once native code lets go of it", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = Extended.new();
            obj.state = { i: 1 };
            owner.addObject(obj);
        })();
        settle(2, function () {
            expect(deallocs()).toBe(0);
            owner.removeAllObjects();
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("collects a native-retain cycle whose back reference is a WeakRef", function (done) {
        (function () {
            var owner = NSMutableArray.new();
            var child = Extended.new();
            owner.addObject(child);
            child.state = { owner: new WeakRef(owner) };
        })();
        settle(4, function () {
            expect(deallocs()).toBe(1);
            done();
        });
    });

    // The ListView shape: JS keeps the cell, the cell points at its item view
    // through a WeakRef, and the item view owns native objects. After teardown
    // the WeakRef must either be cleared or hand back a view whose native
    // objects are alive.
    it("never hands a WeakRef target back with released native objects", function (done) {
        var cell = NSObject.new();
        (function () {
            var view = {};
            var nativeView = TNSAllocLog.new();
            nativeView.owner = view;
            view.nativeView = nativeView;
            view.color = TNSAllocLog.new();
            cell.owner = new WeakRef(view);
        })();
        settle(2, function () {
            var view = cell.owner.deref();
            if (keepsState && view !== undefined) {
                expect(function () {
                    view.color.isEqual(null);
                    view.nativeView.isEqual(null);
                }).not.toThrow();
            }
            done();
        });
    });

    it("tolerates a JS-implemented retainCount while scanning", function (done) {
        var Counting = (function (_super) {
            __extends(Counting, _super);
            function Counting() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Counting.prototype.retainCount = function () {
                return 1;
            };
            return Counting;
        })(NSObject);
        var owner = NSMutableArray.new();
        (function () {
            for (var i = 0; i < 4; i++) {
                var obj = Counting.new();
                obj.state = i;
                owner.addObject(obj);
            }
        })();
        settle(2, function () {
            expect(owner.count).toBe(4);
            if (keepsState) {
                expect(owner.objectAtIndex(0).state).toBe(0);
            }
            done();
        });
    });

    it("lets an explicitly released rooted wrapper go", function (done) {
        var owner = NSMutableArray.new();
        var obj = Extended.new();
        owner.addObject(obj);
        __releaseNativeCounterpart(obj);
        expect(function () {
            obj.isEqual(null);
        }).toThrowError(ReferenceError);
        owner.removeAllObjects();
        settle(2, function () {
            expect(deallocs()).toBe(1);
            done();
        });
    });

    it("counts phantom-mode activity", function (done) {
        var before = runtime.getWrapperLifetimeStats();
        (function () {
            for (var i = 0; i < 8; i++) {
                TNSAllocLog.new().state = i;
            }
        })();
        settle(2, function () {
            var after = runtime.getWrapperLifetimeStats();
            if (mode !== "resurrecting") {
                expect(after.queuedReleases).toBeGreaterThan(before.queuedReleases);
                expect(after.resurrections).toBe(before.resurrections);
            } else {
                expect(after.queuedReleases).toBe(before.queuedReleases);
            }
            done();
        });
    });

    // Own-property semantics hold whatever the mode: in canary mode the names
    // live on the state object and the canary's interceptors present them.
    it("keeps own-property semantics for JS properties on a native object", function () {
        var obj = Extended.new();
        obj.a = 1;
        Object.defineProperty(obj, "hidden", { value: 2, enumerable: false, configurable: true });
        Object.defineProperty(obj, "self", {
            get: function () {
                return this;
            },
            configurable: true
        });

        expect(Object.keys(obj)).toEqual(["a"]);
        expect(Object.getOwnPropertyNames(obj).sort()).toEqual(["a", "hidden", "self"]);
        expect("a" in obj).toBe(true);
        expect(Object.prototype.hasOwnProperty.call(obj, "hidden")).toBe(true);
        expect(obj.hidden).toBe(2);
        expect(obj.self).toBe(obj);
        expect(Object.getOwnPropertyDescriptor(obj, "a").value).toBe(1);

        expect(delete obj.a).toBe(true);
        expect("a" in obj).toBe(false);
        expect(obj.a).toBeUndefined();
        // Prototype members are not own properties.
        expect(Object.prototype.hasOwnProperty.call(obj, "isEqual")).toBe(false);
    });

    it("hands back a native object's JS properties on a new wrapper after the old one died", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = Extended.new();
            obj.tag = "kept";
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            if (keepsState) {
                expect(obj.tag).toBe("kept");
            }
            done();
        });
    });

    it("leaves plain objects outside the extended scope without forwarding", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = TNSAllocLog.new();
            obj.tag = "lost";
            owner.addObject(obj);
        })();
        settle(2, function () {
            if (canary && scope === "extended") {
                expect(owner.objectAtIndex(0).tag).toBeUndefined();
            }
            done();
        });
    });

    it("lets a native object's JS state go when the object is deallocated", function (done) {
        var owner = NSMutableArray.new();
        var before = runtime.getWrapperLifetimeStats();
        var watched;
        (function () {
            var obj = Extended.new();
            obj.tag = "state";
            owner.addObject(obj);
            watched = watch(obj);
        })();
        settle(2, function () {
            owner.removeAllObjects();
            settle(3, function () {
                var after = runtime.getWrapperLifetimeStats();
                expect(alive(watched)).toBe(0);
                if (canary) {
                    expect(after.canaryStates).toBeGreaterThan(before.canaryStates);
                    expect(after.canaryNativeDeaths).toBeGreaterThan(before.canaryNativeDeaths);
                }
                done();
            });
        });
    });

    // The documented cost of the canary contract: state that references its own
    // object keeps the state, the object's wrapper and the native object alive
    // until native code would have released it anyway, which nothing does here.
    it("keeps a native object whose JS state references it", function (done) {
        var watched;
        (function () {
            var obj = Extended.new();
            obj.callback = function () {
                return obj;
            };
            watched = watch(obj);
        })();
        settle(3, function () {
            expect(alive(watched)).toBe(canary ? 1 : 0);
            done();
        });
    });

    // Third-party code can strip a live object's associations, which releases
    // the token that reports native death; the state goes with it.
    it("survives a live object's associations being removed", function () {
        if (typeof objc_removeAssociatedObjects !== "function") {
            return;
        }
        var obj = Extended.new();
        obj.tag = "first";
        objc_removeAssociatedObjects(obj);
        if (canary) {
            expect(obj.tag).toBeUndefined();
        }
        obj.tag = "second";
        expect(obj.tag).toBe("second");
    });

    // V8 refuses to freeze, seal or prevent extensions on an object with
    // interceptors, which every canary has.
    it("refuses to freeze a canary", function () {
        if (!canary) {
            return;
        }
        expect(function () {
            Object.freeze(Extended.new());
        }).toThrowError(TypeError);
    });
});
