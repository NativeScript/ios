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

    // Hands what `make` returns to native code, drops every JS reference to
    // it, and calls back with the object read back from native code: under
    // canary mode on a new wrapper.
    function rewrap(make, callback) {
        var owner = NSMutableArray.new();
        var before = runtime.getWrapperLifetimeStats();
        (function () {
            owner.addObject(make());
        })();
        settle(2, function () {
            if (canary) {
                // The first wrapper died. A WeakRef can't show it here: the
                // weak collections key a native object by its lifetime.
                expect(runtime.getWrapperLifetimeStats().queuedReleases).toBeGreaterThan(before.queuedReleases);
            }
            callback(owner.objectAtIndex(0));
        });
    }

    function hasOwn(obj, name) {
        return Object.prototype.hasOwnProperty.call(obj, name);
    }

    var WithMethod = (function (_super) {
        __extends(WithMethod, _super);
        function WithMethod() {
            return (_super !== null && _super.apply(this, arguments)) || this;
        }
        WithMethod.prototype.greet = function () {
            return this.greeting || "greet";
        };
        return WithMethod;
    })(TNSAllocLog);

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

    // Own-property semantics hold whatever the mode: in canary mode every
    // write also lands on the canary itself.
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
        var first;
        var before = runtime.getWrapperLifetimeStats();
        (function () {
            var obj = Extended.new();
            obj.tag = "kept";
            owner.addObject(obj);
            first = new WeakRef(obj);
        })();
        settle(2, function () {
            if (canary) {
                // The old canary died; a WeakRef keys the native object by its
                // lifetime in this mode, so it hands back the live one.
                expect(runtime.getWrapperLifetimeStats().queuedReleases).toBeGreaterThan(before.queuedReleases);
                expect(first.deref().tag).toBe("kept");
            }
            var obj = owner.objectAtIndex(0);
            if (keepsState) {
                expect(obj.tag).toBe("kept");
            }
            done();
        });
    });

    it("hands back a JS property that shadows a prototype member on a new wrapper", function (done) {
        rewrap(function () {
            var obj = WithMethod.new();
            obj.isEqual = function () {
                return "shadow";
            };
            // Bound to another object: one bound to `obj` would keep it alive.
            obj.greet = obj.greet.bind({ greeting: "bound" });
            obj.tag = "kept";
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(obj.tag).toBe("kept");
                expect(obj.isEqual(obj)).toBe("shadow");
                expect(obj.greet()).toBe("bound");
                expect(hasOwn(obj, "greet")).toBe(true);
            }
            done();
        });
    });

    it("hands back a property defined over a prototype member on a new wrapper", function (done) {
        rewrap(function () {
            var obj = WithMethod.new();
            Object.defineProperty(obj, "isEqual", {
                value: function () {
                    return "defined";
                },
                writable: true,
                configurable: true
            });
            expect(obj.isEqual(obj)).toBe("defined");
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(obj.isEqual(obj)).toBe("defined");
                var descriptor = Object.getOwnPropertyDescriptor(obj, "isEqual");
                expect(descriptor.writable).toBe(true);
                expect(descriptor.enumerable).toBe(false);
                expect(descriptor.configurable).toBe(true);
                expect(Object.keys(obj)).toEqual([]);
            }
            done();
        });
    });

    it("restores the prototype member a deleted shadowing property hid", function (done) {
        rewrap(function () {
            var obj = WithMethod.new();
            obj.greet = function () {
                return "shadow";
            };
            obj.tag = "kept";
            expect(delete obj.greet).toBe(true);
            expect(obj.greet()).toBe("greet");
            return obj;
        }, function (obj) {
            expect(hasOwn(obj, "greet")).toBe(false);
            expect(obj.greet()).toBe("greet");
            if (keepsState) {
                expect(obj.tag).toBe("kept");
            }
            done();
        });
    });

    it("hands back an accessor defined on the instance, running it on the new wrapper", function (done) {
        rewrap(function () {
            var obj = Extended.new();
            Object.defineProperty(obj, "self", {
                get: function () {
                    return this;
                },
                set: function (value) {
                    this.written = value;
                },
                configurable: true
            });
            obj.self = 1;
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(obj.self).toBe(obj);
                expect(obj.written).toBe(1);
                obj.self = 2;
                expect(obj.written).toBe(2);
                var descriptor = Object.getOwnPropertyDescriptor(obj, "self");
                expect(typeof descriptor.get).toBe("function");
                expect(typeof descriptor.set).toBe("function");
                expect(descriptor.enumerable).toBe(false);
            }
            done();
        });
    });

    it("hands back non-enumerable, read-only and symbol-keyed properties with their attributes", function (done) {
        var key = Symbol("key");
        rewrap(function () {
            var obj = Extended.new();
            obj.visible = 1;
            Object.defineProperty(obj, "hidden", { value: 2, writable: true, configurable: true });
            Object.defineProperty(obj, "fixed", { value: 3, enumerable: true });
            obj[key] = 4;
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(Object.keys(obj)).toEqual(["visible", "fixed"]);
                expect(Object.getOwnPropertyNames(obj).sort()).toEqual(["fixed", "hidden", "visible"]);
                expect(obj[key]).toBe(4);
                expect(Object.getOwnPropertyDescriptor(obj, "hidden")).toEqual({
                    value: 2, writable: true, enumerable: false, configurable: true
                });
                expect(Object.getOwnPropertyDescriptor(obj, "fixed")).toEqual({
                    value: 3, writable: false, enumerable: true, configurable: false
                });
                expect(delete obj.fixed).toBe(false);
            }
            done();
        });
    });

    function strictAssignThrows(obj, name, value) {
        "use strict";
        try {
            obj[name] = value;
        } catch (e) {
            return e instanceof TypeError;
        }
        return false;
    }

    function answerGot() {
        return "got";
    }

    // A rejected write is rejected by the wrapper's own property, and the
    // state keeps the old value. No closure here may capture the wrapper: the
    // getter stored in the state would keep it alive.
    it("rejects writes to read-only and getter-only properties", function (done) {
        rewrap(function () {
            var obj = Extended.new();
            Object.defineProperty(obj, "fixed", { value: 1, writable: false, configurable: true });
            Object.defineProperty(obj, "getterOnly", { get: answerGot, configurable: true });
            expect(Reflect.set(obj, "fixed", 2)).toBe(false);
            expect(Reflect.set(obj, "getterOnly", 2)).toBe(false);
            expect(strictAssignThrows(obj, "fixed", 2)).toBe(true);
            expect(strictAssignThrows(obj, "getterOnly", 2)).toBe(true);
            expect(obj.fixed).toBe(1);
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(obj.fixed).toBe(1);
                expect(obj.getterOnly).toBe("got");
                expect(Reflect.set(obj, "fixed", 2)).toBe(false);
            }
            done();
        });
    });

    it("runs the native setter of a native property written on a wrapper", function (done) {
        var Host = (function (_super) {
            __extends(Host, _super);
            function Host() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return Host;
        })(TNSAccessorHost);
        rewrap(function () {
            var obj = Host.new();
            var before = runtime.getWrapperLifetimeStats();
            obj.name = "native";
            expect(hasOwn(obj, "name")).toBe(false);
            if (canary) {
                // Not JS state: no state object was made for it.
                expect(runtime.getWrapperLifetimeStats().canaryStates).toBe(before.canaryStates);
            }
            obj.tag = "state";
            obj.name = "native2";
            expect(hasOwn(obj, "name")).toBe(false);
            return obj;
        }, function (obj) {
            expect(obj.name).toBe("native2");
            expect(hasOwn(obj, "name")).toBe(false);
            if (keepsState) {
                expect(obj.tag).toBe("state");
            }
            done();
        });
    });

    it("shadows a native property with a defined one until it is deleted", function (done) {
        var Host = (function (_super) {
            __extends(Host, _super);
            function Host() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return Host;
        })(TNSAccessorHost);
        var nativeName = Object.getOwnPropertyDescriptor(TNSAccessorHost.prototype, "name").get;
        rewrap(function () {
            var obj = Host.new();
            obj.name = "native";
            Object.defineProperty(obj, "name", { value: "js", writable: true, configurable: true });
            obj.name = "js2";
            expect(nativeName.call(obj)).toBe("native");
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(hasOwn(obj, "name")).toBe(true);
                expect(obj.name).toBe("js2");
            }
            expect(nativeName.call(obj)).toBe("native");
            delete obj.name;
            expect(hasOwn(obj, "name")).toBe(false);
            expect(obj.name).toBe("native");
            obj.name = "native3";
            expect(hasOwn(obj, "name")).toBe(false);
            expect(nativeName.call(obj)).toBe("native3");
            done();
        });
    });

    // Interceptors see only writes made through the wrapper itself.
    it("keeps a write through an object inheriting from a wrapper on that object", function () {
        var obj = Extended.new();
        var derived = Object.create(obj);
        derived.tag = "derived";
        Object.defineProperty(derived, "defined", { value: 1, configurable: true });
        expect(hasOwn(derived, "tag")).toBe(true);
        expect("tag" in obj).toBe(false);
        expect("defined" in obj).toBe(false);
    });

    // A JS-implemented dealloc replaces the class's own death hook, so it
    // reports the death itself, after the JS method ran.
    it("lets the JS state go when a JS-implemented dealloc ran", function (done) {
        var N = 8;
        var seen = [];
        var WithDealloc = TNSAllocLog.extend({
            dealloc: function () {
                seen.push(this.tag);
                this.super.dealloc();
            }
        }, { name: "WrapperLifetimeModesJSDealloc" });
        var owner = NSMutableArray.new();
        var payloads = [];
        settle(2, function () {
            var before = runtime.getWrapperLifetimeStats();
            (function () {
                for (var i = 0; i < N; i++) {
                    var obj = WithDealloc.new();
                    obj.tag = "state";
                    var payload = { index: i };
                    obj.payload = payload;
                    payloads.push(new WeakRef(payload));
                    owner.addObject(obj);
                }
            })();
            settle(2, function () {
                owner.removeAllObjects();
                settle(3, function () {
                    var after = runtime.getWrapperLifetimeStats();
                    expect(seen.length).toBe(N);
                    if (canary) {
                        // The JS dealloc still reads the object's JS state.
                        expect(seen.filter(function (tag) { return tag === "state"; }).length).toBe(N);
                        expect(after.canaryNativeDeaths - before.canaryNativeDeaths).not.toBeLessThan(N);
                        // The death count is isolate-wide; each fixture's own
                        // state must be gone.
                        expect(payloads.filter(function (ref) { return ref.deref() !== undefined; }).length).toBe(0);
                    }
                    done();
                });
            });
        });
    });

    // Inherited from the NSArray prototype, so like Array's it needs `this`.
    it("iterates an NSArray through its inherited Symbol.iterator and rejects an unbound call", function () {
        var array = NSArray.arrayWithArray(["a", "b"]);
        expect(Object.prototype.hasOwnProperty.call(array, Symbol.iterator)).toBe(false);
        expect(Array.from(array)).toEqual(["a", "b"]);
        var iterate = array[Symbol.iterator];
        expect(function () {
            iterate();
        }).toThrowError(TypeError, /non-NSArray/);
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
        var payload;
        (function () {
            var obj = Extended.new();
            obj.tag = "state";
            obj.payload = {};
            payload = new WeakRef(obj.payload);
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
                    expect(payload.deref()).toBeUndefined();
                }
                done();
            });
        });
    });

    // Plain objects have no class -dealloc of ours: an associated token or a
    // weak-reference sweep reports them.
    it("lets a plain native object's JS state go when the object is deallocated", function (done) {
        var owner = NSMutableArray.new();
        var before = runtime.getWrapperLifetimeStats();
        var watched;
        var payload;
        (function () {
            var obj = TNSAllocLog.new();
            obj.tag = "state";
            obj.payload = {};
            payload = new WeakRef(obj.payload);
            owner.addObject(obj);
            watched = watch(obj);
        })();
        settle(2, function () {
            owner.removeAllObjects();
            settle(3, function () {
                var after = runtime.getWrapperLifetimeStats();
                expect(alive(watched)).toBe(0);
                if (canary && scope === "all") {
                    expect(after.canaryNativeDeaths).toBeGreaterThan(before.canaryNativeDeaths);
                    expect(payload.deref()).toBeUndefined();
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

    // Third-party code can strip a live object's associations. Where an
    // associated token reports native death, the record goes with it, and the
    // next write seeds a new state from the canary's own properties.
    it("survives a live object's associations being removed", function (done) {
        if (typeof objc_removeAssociatedObjects !== "function") {
            done();
            return;
        }
        rewrap(function () {
            // Only objects outside JS-extended classes carry the token.
            var obj = scope === "all" ? TNSAllocLog.new() : Extended.new();
            obj.tag = "first";
            obj.other = "kept";
            objc_removeAssociatedObjects(obj);
            expect(obj.tag).toBe("first");
            obj.tag = "second";
            expect(obj.tag).toBe("second");
            return obj;
        }, function (obj) {
            if (keepsState) {
                expect(obj.tag).toBe("second");
                expect(obj.other).toBe("kept");
            }
            done();
        });
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
        expect(function () {
            Object.seal(Extended.new());
        }).toThrowError(TypeError);
        expect(function () {
            Object.preventExtensions(Extended.new());
        }).toThrowError(TypeError);
    });

    // Named interceptors see neither index keys nor private names: both live
    // on the canary only.
    it("drops index-keyed properties and #private brands with a canary", function (done) {
        var Stamp = (function () {
            var Base = function (target) {
                return target;
            };
            return class extends Base {
                #brand = 1;
                static has(o) {
                    return #brand in o;
                }
            };
        })();
        rewrap(function () {
            var obj = Extended.new();
            obj[0] = "index";
            obj.tag = "kept";
            new Stamp(obj);
            expect(obj[0]).toBe("index");
            expect(Stamp.has(obj)).toBe(true);
            return obj;
        }, function (obj) {
            if (canary) {
                expect(obj.tag).toBe("kept");
                expect(obj[0]).toBeUndefined();
                expect(Stamp.has(obj)).toBe(false);
            }
            done();
        });
    });

    describe("write handler", function () {
        function stats() {
            return runtime.getWrapperLifetimeStats();
        }

        function makeHost() {
            return (function (_super) {
                __extends(Host, _super);
                function Host() {
                    return (_super !== null && _super.apply(this, arguments)) || this;
                }
                return Host;
            })(TNSAccessorHost);
        }

        var Host = makeHost();
        var nativeName = Object.getOwnPropertyDescriptor(TNSAccessorHost.prototype, "name").get;

        it("runs the native setter of a native property on the receiver", function () {
            var obj = Host.new();
            var other = Host.new();
            obj.tag = "state";
            other.name = "other";
            var before = stats();
            obj.name = "direct";
            var after = stats();
            expect(nativeName.call(obj)).toBe("direct");
            expect(nativeName.call(other)).toBe("other");
            expect(hasOwn(obj, "name")).toBe(false);
            if (canary) {
                expect(after.canaryInterceptedWrites - before.canaryInterceptedWrites).toBe(1);
                expect(after.canaryStates).toBe(before.canaryStates);
            }
        });

        it("propagates what a native setter throws", function () {
            var obj = Host.new();
            obj.tag = "state";
            // NSObject's `hash` is read-only: its setter throws.
            expect(function () {
                obj.hash = 1;
            }).toThrowError(/readonly/);
            expect(function () {
                "use strict";
                obj.hash = 1;
            }).toThrowError(/readonly/);
            expect(hasOwn(obj, "hash")).toBe(false);
        });

        it("runs a JS accessor's setter with the canary as this", function (done) {
            var Labeled = makeHost();
            var receivers = [];
            Object.defineProperty(Labeled.prototype, "label", {
                get: function () {
                    return this._label;
                },
                set: function (value) {
                    receivers.push(this);
                    this._label = value;
                },
                configurable: true
            });
            Object.defineProperty(Labeled.prototype, "boom", {
                set: function () {
                    throw new RangeError("boom");
                },
                configurable: true
            });
            rewrap(function () {
                var obj = Labeled.new();
                var before = stats();
                obj.label = "set";
                expect(receivers.length).toBe(1);
                expect(receivers[0]).toBe(obj);
                expect(hasOwn(obj, "label")).toBe(false);
                expect(hasOwn(obj, "_label")).toBe(true);
                expect(function () {
                    obj.boom = 1;
                }).toThrowError(RangeError);
                expect(hasOwn(obj, "boom")).toBe(false);
                if (canary) {
                    expect(stats().canaryStates).toBe(before.canaryStates + 1);
                }
                receivers.length = 0;
                return obj;
            }, function (obj) {
                if (keepsState) {
                    expect(obj.label).toBe("set");
                }
                obj.label = "again";
                expect(receivers[0]).toBe(obj);
                expect(obj._label).toBe("again");
                done();
            });
        });

        it("rejects writes to a getter-only accessor and a read-only property", function () {
            var Fixed = makeHost();
            Object.defineProperty(Fixed.prototype, "getOnly", {
                get: function () {
                    return "get";
                },
                configurable: true
            });
            Object.defineProperty(Fixed.prototype, "fixed", { value: "fixed", writable: false, configurable: true });
            var obj = Fixed.new();
            obj.tag = "state";
            var before = stats();
            expect(function () {
                "use strict";
                obj.getOnly = 1;
            }).toThrowError(TypeError);
            expect(function () {
                "use strict";
                obj.fixed = 1;
            }).toThrowError(TypeError);
            obj.getOnly = 1;
            obj.fixed = 1;
            expect(obj.getOnly).toBe("get");
            expect(obj.fixed).toBe("fixed");
            expect(hasOwn(obj, "getOnly")).toBe(false);
            expect(hasOwn(obj, "fixed")).toBe(false);
            if (canary) {
                expect(stats().canaryStates).toBe(before.canaryStates);
            }
        });

        it("follows a prototype data property replaced by an accessor and back", function (done) {
            var Flip = makeHost();
            var set = [];
            Flip.prototype.flip = "data";
            var first = Flip.new();
            first.flip = "own";
            expect(hasOwn(first, "flip")).toBe(true);
            Object.defineProperty(Flip.prototype, "flip", {
                get: function () {
                    return "accessor";
                },
                set: function (value) {
                    set.push(value);
                },
                configurable: true
            });
            var second = Flip.new();
            second.flip = "through";
            expect(set).toEqual(["through"]);
            expect(hasOwn(second, "flip")).toBe(false);
            first.flip = "own2";
            expect(first.flip).toBe("own2");
            expect(set).toEqual(["through"]);
            Object.defineProperty(Flip.prototype, "flip", { value: "data2", writable: true, configurable: true });
            rewrap(function () {
                var third = Flip.new();
                third.flip = "own3";
                expect(hasOwn(third, "flip")).toBe(true);
                expect(set).toEqual(["through"]);
                return third;
            }, function (third) {
                if (keepsState) {
                    expect(third.flip).toBe("own3");
                }
                done();
            });
        });

        it("follows a native property shadowed and unshadowed on a JS prototype", function () {
            var Shadow = makeHost();
            var obj = Shadow.new();
            obj.name = "native";
            Object.defineProperty(Shadow.prototype, "name", { value: "js", writable: true, configurable: true });
            obj.name = "own";
            expect(hasOwn(obj, "name")).toBe(true);
            expect(nativeName.call(obj)).toBe("native");
            delete obj.name;
            delete Shadow.prototype.name;
            obj.name = "native2";
            expect(hasOwn(obj, "name")).toBe(false);
            expect(nativeName.call(obj)).toBe("native2");
        });

        it("follows a prototype chain changed after a write", function () {
            var obj = Host.new();
            obj.name = "native";
            var set = [];
            var proto = Object.create(Object.getPrototypeOf(obj), {
                name: {
                    set: function (value) {
                        set.push(this === obj ? value : "wrong this");
                    },
                    configurable: true
                }
            });
            Object.setPrototypeOf(obj, proto);
            obj.name = "swapped";
            expect(set).toEqual(["swapped"]);
            expect(nativeName.call(obj)).toBe("native");
            Object.setPrototypeOf(obj, Host.prototype);
            obj.name = "native2";
            expect(set).toEqual(["swapped"]);
            expect(nativeName.call(obj)).toBe("native2");
        });

        describe("native property setters", function () {
            function makeTarget() {
                return (function (_super) {
                    __extends(Target, _super);
                    function Target() {
                        return (_super !== null && _super.apply(this, arguments)) || this;
                    }
                    return Target;
                })(TNSCanaryWriteTarget);
            }

            function nativeGetter(name) {
                return Object.getOwnPropertyDescriptor(TNSCanaryWriteTarget.prototype, name).get;
            }

            var nativeLevel = nativeGetter("level");

            it("run on the receiver, in sloppy and strict mode", function () {
                var Target = makeTarget();
                var obj = Target.new();
                var other = Target.new();
                obj.tag = "state";
                var before = stats();
                obj.level = 3;
                expect(nativeLevel.call(obj)).toBe(3);
                (function () {
                    "use strict";
                    obj.level = 4;
                })();
                expect(nativeLevel.call(obj)).toBe(4);
                expect(nativeLevel.call(other)).toBe(0);
                expect(hasOwn(obj, "level")).toBe(false);
                if (canary) {
                    expect(stats().canaryInterceptedWrites - before.canaryInterceptedWrites).toBe(2);
                    expect(stats().canaryStates).toBe(before.canaryStates);
                }
            });

            it("propagate what the native setter raises", function () {
                var obj = makeTarget().new();
                obj.guarded = 2;
                var errors = [];
                try {
                    obj.guarded = -1;
                } catch (e) {
                    errors.push(e);
                }
                try {
                    (function () {
                        "use strict";
                        obj.guarded = -2;
                    })();
                } catch (e) {
                    errors.push(e);
                }
                expect(errors.length).toBe(2);
                errors.forEach(function (e) {
                    expect(e.nativeException instanceof NSException).toBe(true);
                    expect(e.nativeException.reason).toBe("guarded must not be negative");
                });
                expect(obj.guarded).toBe(2);
                expect(hasOwn(obj, "guarded")).toBe(false);
                obj.guarded = 5;
                expect(obj.guarded).toBe(5);
            });

            it("reject a write to a read-only native property", function () {
                var obj = makeTarget().new();
                obj.tag = "state";
                expect(function () {
                    obj.fixed = 1;
                }).toThrowError(/readonly/);
                expect(function () {
                    "use strict";
                    obj.fixed = 1;
                }).toThrowError(/readonly/);
                expect(obj.fixed).toBe(0);
                expect(hasOwn(obj, "fixed")).toBe(false);
            });

            it("give way to a JS accessor overriding the property, which gets the JS value", function () {
                var Over = makeTarget();
                var calls = [];
                Object.defineProperty(Over.prototype, "level", {
                    get: function () {
                        return -1;
                    },
                    set: function (value) {
                        calls.push({ self: this, value: value });
                    },
                    configurable: true
                });
                var obj = Over.new();
                var value = { not: "a number" };
                obj.level = value;
                expect(calls.length).toBe(1);
                expect(calls[0].self).toBe(obj);
                expect(calls[0].value).toBe(value);
                expect(nativeLevel.call(obj)).toBe(0);
            });

            it("give way to a JS accessor added to a JS prototype after a native write", function () {
                var Late = makeTarget();
                var obj = Late.new();
                obj.level = 1;
                expect(nativeLevel.call(obj)).toBe(1);
                var set = [];
                Object.defineProperty(Late.prototype, "level", {
                    set: function (value) {
                        set.push(this === obj ? value : "wrong this");
                    },
                    configurable: true
                });
                obj.level = 2;
                expect(set).toEqual([2]);
                expect(nativeLevel.call(obj)).toBe(1);
                delete Late.prototype.level;
                obj.level = 3;
                expect(set).toEqual([2]);
                expect(nativeLevel.call(obj)).toBe(3);
            });

            it("give way to an accessor defined on the instance", function () {
                var obj = makeTarget().new();
                obj.level = 1;
                var set = [];
                Object.defineProperty(obj, "level", {
                    set: function (value) {
                        set.push(this === obj ? value : "wrong this");
                    },
                    configurable: true
                });
                obj.level = 2;
                expect(set).toEqual([2]);
                expect(nativeLevel.call(obj)).toBe(1);
                delete obj.level;
                obj.level = 3;
                expect(set).toEqual([2]);
                expect(nativeLevel.call(obj)).toBe(3);
            });

            it("give way to an accessor redefined on the native prototype after a native write", function () {
                var proto = TNSCanaryWriteTarget.prototype;
                var redefine = {
                    viaDefineProperty: function (name, setter) {
                        Object.defineProperty(proto, name, { set: setter, configurable: true });
                    },
                    viaDefineProperties: function (name, setter) {
                        var descriptors = {};
                        descriptors[name] = { set: setter, configurable: true };
                        Object.defineProperties(proto, descriptors);
                    },
                    viaReflect: function (name, setter) {
                        expect(Reflect.defineProperty(proto, name, { set: setter, configurable: true })).toBe(true);
                    },
                    viaDefineSetter: function (name, setter) {
                        proto.__defineSetter__(name, setter);
                    }
                };
                var obj = makeTarget().new();
                Object.keys(redefine).forEach(function (name) {
                    var getter = nativeGetter(name);
                    obj[name] = 1;
                    expect(getter.call(obj)).toBe(1);
                    var set = [];
                    redefine[name](name, function (value) {
                        set.push(this === obj ? value : "wrong this");
                    });
                    var value = { name: name };
                    obj[name] = value;
                    expect(set.length).toBe(1);
                    expect(set[0]).toBe(value);
                    expect(hasOwn(obj, name)).toBe(false);
                });
            });

            it("follow a native accessor deleted from its prototype and replaced", function () {
                var proto = TNSCanaryWriteTarget.prototype;
                var getter = nativeGetter("dropped");
                var obj = makeTarget().new();
                obj.dropped = 1;
                expect(getter.call(obj)).toBe(1);
                expect(delete proto.dropped).toBe(true);
                obj.dropped = 2;
                expect(hasOwn(obj, "dropped")).toBe(true);
                expect(getter.call(obj)).toBe(1);
                delete obj.dropped;
                proto.dropped = "data";
                obj.dropped = 3;
                expect(hasOwn(obj, "dropped")).toBe(true);
                expect(obj.dropped).toBe(3);
                delete obj.dropped;
                var set = [];
                Object.defineProperty(proto, "dropped", {
                    set: function (value) {
                        set.push(this === obj ? value : "wrong this");
                    },
                    configurable: true
                });
                var value = { dropped: true };
                obj.dropped = value;
                expect(set.length).toBe(1);
                expect(set[0]).toBe(value);
                expect(hasOwn(obj, "dropped")).toBe(false);
                expect(getter.call(obj)).toBe(1);
            });

            it("give way to a proxy between the instance and the native prototype", function () {
                var obj = makeTarget().new();
                obj.level = 1;
                var trapped = [];
                // The target owns `level`, so attribute queries find it at the proxy.
                var target = Object.create(Object.getPrototypeOf(obj));
                Object.defineProperty(target, "level", { value: "target", writable: true, configurable: true });
                var proxy = new Proxy(target, {
                    set: function (target, key, value, receiver) {
                        trapped.push({ key: key, value: value, receiver: receiver });
                        return true;
                    }
                });
                Object.setPrototypeOf(obj, proxy);
                obj.level = 2;
                expect(trapped.length).toBe(1);
                expect(trapped[0].key).toBe("level");
                expect(trapped[0].value).toBe(2);
                expect(trapped[0].receiver).toBe(obj);
                expect(nativeLevel.call(obj)).toBe(1);
            });

            it("write through the native setter when JS no longer sees an override exposed to native code", function () {
                var calls = [];
                var Exposed = TNSCanaryWriteTarget.extend({
                    get level() {
                        return -1;
                    },
                    set level(value) {
                        calls.push(value);
                    }
                }, { name: "WrapperLifetimeExposedLevelSetter" });
                // The accessor lives on the implementation object Exposed.prototype
                // inherits from. -setLevel: stays overridden for native callers.
                var implementation = Object.getPrototypeOf(Exposed.prototype);
                expect(Object.getOwnPropertyDescriptor(implementation, "level")).toBeDefined();
                expect(delete implementation.level).toBe(true);
                expect(Exposed.prototype.__lookupSetter__("level")).toBe(Object.getOwnPropertyDescriptor(TNSCanaryWriteTarget.prototype, "level").set);
                var obj = Exposed.new();
                obj.tag = "state";
                // A JS write through the native accessor runs the base -setLevel:;
                // native callers reach the override.
                obj.level = 3;
                expect(calls).toEqual([]);
                expect(nativeLevel.call(obj)).toBe(3);
                expect(Object.prototype.hasOwnProperty.call(obj, "level")).toBe(false);
                obj.setValueForKey(5, "level");
                expect(calls).toEqual([5]);
                expect(nativeLevel.call(obj)).toBe(3);
            });
        });

        it("handles writes to JS-extended instances only, under scope extended", function () {
            var Ext = TNSAllocLog.extend({}, { name: "WrapperLifetimeWriteHandlerExt" });
            var before = stats();
            TNSAllocLog.new().tag = 1;
            new TNSAllocLog().tag = 1;
            TNSAllocLog.alloc().init().tag = 1;
            var plain = stats().canaryInterceptedWrites - before.canaryInterceptedWrites;
            Extended.new().tag = 1;
            new Ext().tag = 1;
            Ext.alloc().init().tag = 1;
            var extended = stats().canaryInterceptedWrites - before.canaryInterceptedWrites - plain;
            if (canary) {
                expect(plain).toBe(scope === "all" ? 3 : 0);
                expect(extended).toBe(3);
            } else {
                expect(plain + extended).toBe(0);
            }
        });

        it("handles writes to a key-value observed JS-extended instance on a new wrapper", function (done) {
            var observer = NSObject.new();
            var before;
            rewrap(function () {
                var obj = Host.new();
                // Observing a key with a setter swaps in the notifying subclass.
                obj.addObserverForKeyPathOptionsContext(observer, "name", 0, null);
                obj.tag = "kept";
                return obj;
            }, function (obj) {
                expect(obj.observationInfo).not.toBeNull();
                if (keepsState) {
                    expect(obj.tag).toBe("kept");
                }
                before = stats();
                obj.other = "new";
                if (canary) {
                    expect(stats().canaryInterceptedWrites - before.canaryInterceptedWrites).toBe(1);
                }
                obj.removeObserverForKeyPath(observer, "name");
                done();
            });
        });

        it("gives a native constructor's JS-extended result the write handler", function (done) {
            var owner = NSMutableArray.new();
            var handle;
            var released = stats().queuedReleases;
            (function () {
                var obj = Extended.new();
                obj.tag = "kept";
                owner.addObject(obj);
                handle = interop.handleof(obj);
            })();
            settle(2, function () {
                var before = stats();
                var again = new TNSAllocLog(handle);
                expect(again instanceof TNSAllocLog).toBe(true);
                if (canary) {
                    // The first wrapper died (a WeakRef can't show it: weak
                    // collections key a native object by its lifetime).
                    expect(before.queuedReleases).toBeGreaterThan(released);
                    expect(Object.getPrototypeOf(again)).toBe(TNSAllocLog.prototype);
                }
                if (keepsState) {
                    expect(again.tag).toBe("kept");
                }
                again.other = "new";
                if (canary) {
                    expect(stats().canaryInterceptedWrites - before.canaryInterceptedWrites).toBe(1);
                }
                rewrap(function () {
                    var made = again;
                    again = null;
                    return made;
                }, function (obj) {
                    if (keepsState) {
                        expect(obj.other).toBe("new");
                    }
                    done();
                });
            });
        });
    });
});
