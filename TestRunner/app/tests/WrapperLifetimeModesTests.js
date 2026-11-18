// Wrapper lifetime under the configured mode ("wrapperLifetime" in the app
// config). The suite runs under the default mode; the rooted expectations run
// when the TestRunner app is configured with "mode": "rooted".
describe("Wrapper lifetime modes", function () {
    var runtime = require("ns:runtime");
    var mode = runtime.getConfig("wrapperLifetimeMode");
    var scope = runtime.getConfig("wrapperLifetimeScope");
    var rooted = mode === "rooted";

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
        expect(["resurrecting", "rooted"].indexOf(mode)).not.toBe(-1);
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
            if (rooted) {
                expect(holder.state).toBeDefined();
                expect(function () {
                    holder.state.item.isEqual(null);
                }).not.toThrow();
            }
            done();
        });
    });

    it("keeps the JS state of a natively owned plain object when every wrapper is rooted", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = TNSAllocLog.new();
            obj.state = { value: 42 };
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            if (rooted && scope === "all") {
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
        var watched = NSHashTable.weakObjectsHashTable();
        (function () {
            for (var i = 0; i < N; i++) {
                var obj = i % 2 === 0 ? Extended.new() : TNSAllocLog.new();
                obj.state = { i: i };
                watched.addObject(obj);
            }
        })();
        settle(2, function () {
            expect(deallocs()).toBeGreaterThan(N / 2);
            // Later specs count deallocations from a cleared log, so none of
            // these objects may outlive this spec. Reading the table retains
            // the survivors until that read's array is collected, hence the
            // rounds between reads.
            (function drain(attempts) {
                var survivors = watched.allObjects.count;
                if (survivors === 0 || attempts === 0) {
                    expect(survivors).toBe(0);
                    done();
                    return;
                }
                settle(3, function () {
                    drain(attempts - 1);
                });
            })(4);
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

    // +new runs the JS-implemented init from native code, before JS has a
    // wrapper for the object.
    it("manages the lifetime of an object whose JS-implemented initializer created its wrapper", function (done) {
        var JSInit = (function (_super) {
            __extends(JSInit, _super);
            function JSInit() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            JSInit.prototype.init = function () {
                var self = _super.prototype.init.call(this);
                self.initialized = true;
                return self;
            };
            return JSInit;
        })(TNSAllocLog);
        var owner = NSMutableArray.new();
        (function () {
            var obj = JSInit.new();
            obj.state = { i: 1 };
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            expect(obj.initialized).toBe(true);
            expect(obj.state && obj.state.i).toBe(1);
            obj = null;
            expect(deallocs()).toBe(0);
            owner.removeAllObjects();
            settle(3, function () {
                if (mode !== "resurrecting") {
                    expect(deallocs()).toBe(1);
                }
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
            if (rooted && view !== undefined) {
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
            if (rooted) {
                expect(owner.objectAtIndex(0).state).toBe(0);
            }
            done();
        });
    });

    it("reads the native retainCount of a key-value observed object whose JS class implements it", function (done) {
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
        var observer = NSObject.new();
        (function () {
            var obj = Counting.new();
            obj.addObserverForKeyPathOptionsContext(observer, "description", 0, null);
            obj.state = 7;
            owner.addObject(obj);
        })();
        settle(2, function () {
            var obj = owner.objectAtIndex(0);
            if (rooted) {
                expect(obj.state).toBe(7);
            }
            obj.removeObserverForKeyPath(observer, "description");
            done();
        });
    });

    // Replaced through the protocol prototype, the native class itself answers
    // -retainCount from JS, so the scan has to read the original. The
    // replacement outlives the spec, and the other modes' ownership checks
    // still call it from a GC prologue, so it is installed in the rooted mode
    // only.
    it("never calls a JS replacement of a native class's retainCount while scanning", function (done) {
        if (!rooted) {
            done();
            return;
        }
        var calls = 0;
        var proto = TNSReplaceableRetainCountProtocol.prototype;
        var original = proto.retainCount;
        proto.retainCount = function () {
            calls++;
            return original.call(this);
        };
        var Replaced = (function (_super) {
            __extends(Replaced, _super);
            function Replaced() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return Replaced;
        })(TNSReplaceableRetainCount);
        var owner = NSMutableArray.new();
        var scanned;
        (function () {
            var obj = Replaced.new();
            obj.state = 3;
            owner.addObject(obj);
            var before = calls;
            expect(TNSReplaceableRetainCount.retainCountOf(obj)).toBeGreaterThan(1);
            expect(calls).toBe(before + 1);
            scanned = calls;
        })();
        settle(2, function () {
            if (rooted) {
                expect(calls).toBe(scanned);
                expect(owner.objectAtIndex(0).state).toBe(3);
            }
            owner.removeAllObjects();
            settle(3, function () {
                if (rooted) {
                    expect(calls).toBe(scanned);
                    expect(deallocs()).toBe(1);
                }
                done();
            });
        });
    });

    it("keeps the JS state of a natively owned timer when every wrapper is rooted", function (done) {
        var owner = NSMutableArray.new();
        var map = new WeakMap();
        (function () {
            var timer = NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1000, TNSAllocLog.new(), "description", null, false);
            timer.state = 5;
            map.set(timer, "timer");
            owner.addObject(timer);
        })();
        settle(2, function () {
            var timer = owner.objectAtIndex(0);
            if (rooted && scope === "all") {
                expect(timer.state).toBe(5);
                expect(map.get(timer)).toBe("timer");
            }
            timer = null;
            expect(deallocs()).toBe(0);
            owner.removeAllObjects();
            settle(4, function () {
                if (rooted && scope === "all") {
                    expect(deallocs()).toBe(1);
                }
                done();
            });
        });
    });

    it("scans a wrapper of NSTimer.alloc()'s uninitialized placeholder", function (done) {
        if (!(rooted && scope === "all")) {
            done();
            return;
        }
        var placeholder = TNSUninitializedTimer.placeholder();
        expect(placeholder.isKindOfClass(NSTimer)).toBe(true);
        placeholder.state = 1;
        settle(2, function () {
            expect(placeholder.state).toBe(1);
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

    it("counts rooted-mode activity", function (done) {
        var before = runtime.getWrapperLifetimeStats();
        (function () {
            for (var i = 0; i < 8; i++) {
                TNSAllocLog.new().state = i;
            }
        })();
        settle(2, function () {
            var after = runtime.getWrapperLifetimeStats();
            if (rooted) {
                expect(after.queuedReleases).toBeGreaterThan(before.queuedReleases);
                expect(after.resurrections).toBe(before.resurrections);
            } else {
                expect(after.queuedReleases).toBe(before.queuedReleases);
            }
            done();
        });
    });
});
