// WeakMap, WeakSet, WeakRef and FinalizationRegistry keyed on native objects.
// The expectations hold in every wrapper lifetime mode; under "canary" they
// depend on the weak collections keying a native object by its lifetime key
// rather than by its current wrapper.
describe("Weak collections of native objects", function () {
    var runtime = require("ns:runtime");
    var canary = runtime.getConfig("wrapperLifetimeMode") === "canary";
    // Under "extended" a plain object's wrapper is no canary, and the weak
    // collections give the object a key-only state when they first key it.
    var plainKeys = canary && runtime.getConfig("wrapperLifetimeScope") === "extended";
    // The engine's WeakRef, which keys the wrapper itself.
    var WrapperWeakRef = canary ? Object.getPrototypeOf(WeakRef) : WeakRef;

    var Extended = (function (_super) {
        __extends(Extended, _super);
        function Extended() {
            return (_super !== null && _super.apply(this, arguments)) || this;
        }
        return Extended;
    })(TNSAllocLog);

    // Release semantics hold for both: a JS-extended object is a canary in
    // canary mode, and a plain one is a canary under "all" and keyed by a
    // key-only state under "extended".
    var kinds = [
        { name: "a JS-extended object", make: function () { return Extended.new(); } },
        { name: "a plain object", make: function () { return NSObject.new(); } }
    ];

    function canaryStates() {
        return runtime.getWrapperLifetimeStats().canaryStates;
    }

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
        var first;
        (function () {
            var obj = Extended.new();
            map.set(obj, "value");
            owner.addObject(obj);
            first = new WrapperWeakRef(obj);
        })();
        settle(2, function () {
            if (canary) {
                // The first wrapper died; the entry belongs to the native object.
                expect(first.deref()).toBeUndefined();
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

    // Uses every collection, and a deref, on a canary in an earlier job, so
    // whatever they keep for it would still be there.
    function keyEverywhere(obj, collections) {
        collections.map.set(obj, "value");
        collections.set.add(obj);
        collections.registry.register(obj, "held", obj);
        var ref = new WeakRef(obj);
        ref.deref();
        collections.map.get(obj);
        collections.set.has(obj);
        collections.refs.push(ref);
        collections.wrappers.push(new WrapperWeakRef(obj));
    }

    function collections() {
        return {
            map: new WeakMap(),
            set: new WeakSet(),
            registry: new FinalizationRegistry(function () {}),
            refs: [],
            wrappers: []
        };
    }

    // The objects a weak table still holds. The array allObjects returns
    // retains them until its wrapper is released and the autorelease pool
    // drains; a "rooted" collection before that counts the retain as native
    // ownership and roots their wrappers.
    function watchedCount(table) {
        var all = table.allObjects;
        var count = all.count;
        __releaseNativeCounterpart(all);
        return count;
    }

    it("lets a keyed wrapper nothing references die and its JS-owned native object go", function (done) {
        var watch = NSHashTable.weakObjectsHashTable();
        var keyed = collections();
        (function () {
            var obj = Extended.new();
            watch.addObject(obj);
            keyEverywhere(obj, keyed);
        })();
        var attempts = 15;
        (function poll() {
            settle(1, function () {
                var gone = watchedCount(watch) === 0;
                if (gone || --attempts === 0) {
                    expect(gone).toBe(true);
                    if (canary) {
                        expect(keyed.wrappers[0].deref() === undefined).toBe(true);
                        expect(keyed.refs[0].deref() === undefined).toBe(true);
                    }
                    done();
                    return;
                }
                // Collects only after the run loop drained the probe's array.
                setTimeout(poll, 10);
            });
        })();
    });

    it("lets a keyed canary nothing references die while native code owns its object", function (done) {
        if (!canary) {
            done();
            return;
        }
        var owner = NSMutableArray.new();
        var keyed = collections();
        (function () {
            var obj = Extended.new();
            owner.addObject(obj);
            keyEverywhere(obj, keyed);
        })();
        settle(2, function () {
            expect(keyed.wrappers[0].deref() === undefined).toBe(true);
            var later = owner.objectAtIndex(0);
            expect(keyed.map.get(later)).toBe("value");
            expect(keyed.set.has(later)).toBe(true);
            expect(keyed.refs[0].deref() === later).toBe(true);
            expect(keyed.registry.unregister(later)).toBe(true);
            done();
        });
    });

    // The next collection runs in a later job than `condition`: a WeakRef
    // target that condition dereferences is kept alive until its job ends.
    function pollUntil(condition, callback) {
        var attempts = 15;
        (function poll() {
            settle(1, function () {
                if (condition() || --attempts === 0) {
                    callback();
                    return;
                }
                setTimeout(poll, 0);
            });
        })();
    }

    it("keys a natively owned plain object by its lifetime across a wrapper change", function (done) {
        if (!plainKeys) {
            done();
            return;
        }
        var owner = NSMutableArray.new();
        var map = new WeakMap();
        var set = new WeakSet();
        var held = [];
        var registry = new FinalizationRegistry(function (value) {
            held.push(value);
        });
        var ref;
        var first;
        (function () {
            var obj = NSObject.new();
            owner.addObject(obj);
            map.set(obj, "value");
            set.add(obj);
            ref = new WeakRef(obj);
            registry.register(obj, "held");
            first = new WrapperWeakRef(obj);
        })();
        pollUntil(function () {
            return first.deref() === undefined;
        }, function () {
            expect(first.deref() === undefined).toBe(true);
            var later = owner.objectAtIndex(0);
            expect(map.get(later)).toBe("value");
            expect(set.has(later)).toBe(true);
            expect(ref.deref() === later).toBe(true);
            expect(held.length).toBe(0);
            later = null;
            settle(2, function () {
                expect(held.length).toBe(0);
                owner.removeAllObjects();
                pollUntil(function () {
                    return held.length > 0;
                }, function () {
                    expect(held).toEqual(["held"]);
                    expect(ref.deref() === undefined).toBe(true);
                    done();
                });
            });
        });
    });

    it("lets a keyed plain object JS owned alone go with its wrapper", function (done) {
        if (!plainKeys) {
            done();
            return;
        }
        var watch = NSHashTable.weakObjectsHashTable();
        var map = new WeakMap();
        var held = [];
        var registry = new FinalizationRegistry(function (value) {
            held.push(value);
        });
        var ref;
        (function () {
            var obj = NSObject.new();
            watch.addObject(obj);
            map.set(obj, "value");
            ref = new WeakRef(obj);
            registry.register(obj, "held");
        })();
        pollUntil(function () {
            return watch.allObjects.count === 0 && held.length > 0;
        }, function () {
            expect(watch.allObjects.count).toBe(0);
            expect(held).toEqual(["held"]);
            expect(ref.deref() === undefined).toBe(true);
            done();
        });
    });

    it("gives a plain object a key-only state only when a weak collection keys it", function () {
        if (!plainKeys) {
            return;
        }
        var map = new WeakMap();
        var set = new WeakSet();
        var registry = new FinalizationRegistry(function () {});
        var obj = NSObject.new();
        var before = canaryStates();
        expect(map.has(obj)).toBe(false);
        expect(map.get(obj)).toBeUndefined();
        expect(map.delete(obj)).toBe(false);
        expect(set.has(obj)).toBe(false);
        expect(set.delete(obj)).toBe(false);
        expect(registry.unregister(obj)).toBe(false);
        expect(canaryStates()).toBe(before);
        map.set(obj, 1);
        expect(canaryStates()).toBe(before + 1);
        set.add(obj);
        new WeakRef(obj);
        registry.register({}, "held", obj);
        expect(canaryStates()).toBe(before + 1);
        expect(registry.unregister(obj)).toBe(true);
    });

    kinds.forEach(function (kind) {
        it("dereferences no wrapper of a released object a WeakRef returned before the release (" + kind.name + ")", function () {
            if (!canary) {
                return;
            }
            var owner = NSMutableArray.new();
            var obj = kind.make();
            owner.addObject(obj);
            var ref = new WeakRef(obj);
            expect(ref.deref() === obj).toBe(true);
            __releaseNativeCounterpart(obj);
            expect(ref.deref() === undefined).toBe(true);
            var later = owner.objectAtIndex(0);
            expect(ref.deref() === later).toBe(true);
        });
    });

    // Only objects outside JS-extended classes carry the token the removal
    // releases: canaries under scope "all", key-only states under "extended".
    it("keys a live object again after its associations are removed", function (done) {
        if (!canary || typeof objc_removeAssociatedObjects !== "function") {
            done();
            return;
        }
        var owner = NSMutableArray.new();
        var before = new WeakMap();
        var after = new WeakMap();
        (function () {
            var obj = TNSAllocLog.new();
            owner.addObject(obj);
            before.set(obj, "before");
            expect(before.get(obj)).toBe("before");
            var ref = new WeakRef(obj);
            expect(ref.deref() === obj).toBe(true);
            objc_removeAssociatedObjects(obj);
            // The WeakRef loses the object exactly when the WeakMap does: the
            // token death signal retires the key, the weak sweep keeps it.
            expect((ref.deref() === undefined) === (before.get(obj) === undefined)).toBe(true);
            after.set(obj, "after");
            expect(after.get(obj)).toBe("after");
        })();
        settle(2, function () {
            expect(after.get(owner.objectAtIndex(0))).toBe("after");
            done();
        });
    });

    it("finds what was keyed on an object through its JS dealloc's receiver", function (done) {
        var map = new WeakMap();
        var seen = [];
        var Keyed = TNSAllocLog.extend({
            dealloc: function () {
                seen.push(map.get(this));
                this.super.dealloc();
            }
        }, { name: "WrapperLifetimeWeakCollectionsDeallocGet" });
        var owner = NSMutableArray.new();
        (function () {
            var obj = Keyed.new();
            map.set(obj, "value");
            owner.addObject(obj);
        })();
        settle(2, function () {
            owner.removeAllObjects();
            settle(2, function () {
                expect(seen.length).toBe(1);
                if (canary) {
                    expect(seen[0]).toBe("value");
                }
                done();
            });
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

    it("rejects a FinalizationRegistry registration whose target is its held value", function () {
        var registry = new FinalizationRegistry(function () {});
        var obj = Extended.new();
        expect(function () {
            registry.register(obj, obj);
        }).toThrowError(TypeError);
    });

    it("lets a JS dealloc key a weak collection on its receiver", function (done) {
        var map = new WeakMap();
        var ran = 0;
        var Keyed = TNSAllocLog.extend({
            dealloc: function () {
                map.set(this, "dying");
                ran++;
                this.super.dealloc();
            }
        }, { name: "WrapperLifetimeWeakCollectionsDeallocKey" });
        var owner = NSMutableArray.new();
        (function () {
            var obj = Keyed.new();
            obj.tag = "state";
            owner.addObject(obj);
        })();
        settle(2, function () {
            owner.removeAllObjects();
            settle(2, function () {
                expect(ran).toBe(1);
                done();
            });
        });
    });

    // Under canary mode such an object gets no state: the token that would
    // report its deallocation cannot be associated with it.
    it("keys an object whose class forbids associated objects by its wrapper", function () {
        var obj = TNSAssociationForbidder.forbiddingInstance();
        expect(TNSAssociationForbidder.forbidsAssociatedObjects(obj)).toBe(true);
        var before = runtime.getWrapperLifetimeStats();
        var map = new WeakMap();
        map.set(obj, "value");
        expect(map.get(obj)).toBe("value");
        var set = new WeakSet();
        set.add(obj);
        expect(set.has(obj)).toBe(true);
        expect(new WeakRef(obj).deref()).toBe(obj);
        var registry = new FinalizationRegistry(function () {});
        registry.register(obj, "held", obj);
        expect(registry.unregister(obj)).toBe(true);
        obj.tag = "kept";
        Object.defineProperty(obj, "defined", { value: 1, configurable: true });
        expect(obj.tag).toBe("kept");
        expect(obj.defined).toBe(1);
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

    it("keys the entries given to the WeakMap and WeakSet constructors by the native object", function (done) {
        var owner = NSMutableArray.new();
        var map;
        var set;
        var first;
        (function () {
            var obj = Extended.new();
            map = new WeakMap([[obj, "constructed"]]);
            set = new WeakSet([obj]);
            owner.addObject(obj);
            first = new WrapperWeakRef(obj);
        })();
        settle(2, function () {
            if (canary) {
                expect(first.deref()).toBeUndefined();
            }
            var obj = owner.objectAtIndex(0);
            expect(map.get(obj)).toBe("constructed");
            expect(set.has(obj)).toBe(true);
            done();
        });
    });

    it("keys a native object in a subclass of WeakMap", function (done) {
        class TaggedMap extends WeakMap {
            set(key, value) {
                return super.set(key, "tagged:" + value);
            }
        }
        var owner = NSMutableArray.new();
        var map = new TaggedMap();
        var first;
        (function () {
            var obj = Extended.new();
            map.set(obj, "value");
            owner.addObject(obj);
            first = new WrapperWeakRef(obj);
        })();
        settle(2, function () {
            if (canary) {
                expect(first.deref()).toBeUndefined();
            }
            expect(map.get(owner.objectAtIndex(0))).toBe("tagged:value");
            expect(map instanceof WeakMap).toBe(true);
            done();
        });
    });

    // In canary mode what was keyed on a native object follows the object, not
    // a released wrapper of it; elsewhere the standard collections key the
    // wrapper itself. Only booleans reach expect(), which could otherwise keep
    // a wrapper alive.
    function pollCleaned(isCleaned, registry, callback) {
        var attempts = 15;
        (function poll() {
            settle(1, function () {
                // A collected registry runs no callbacks.
                if ((isCleaned() && registry !== null) || --attempts === 0) {
                    callback();
                    return;
                }
                poll();
            });
        })();
    }

    // A wrapper released before anything keyed its object is a key of its own,
    // which nothing keyed on the object can find.
    function releasedNeverKeyed(kind) {
        var obj = kind.make();
        __releaseNativeCounterpart(obj);
        return obj;
    }

    function releasedAccesses() {
        return runtime.getWrapperLifetimeStats().releasedAccesses;
    }

    kinds.forEach(function (kind) {
        it("keeps what was keyed on a natively retained object after a wrapper of it is released (" + kind.name + ")", function (done) {
            if (!canary) {
                done();
                return;
            }
            var owner = NSMutableArray.new();
            var map = new WeakMap();
            var set = new WeakSet();
            var cleaned = false;
            var registry = new FinalizationRegistry(function (held) {
                cleaned = held === "released";
            });
            var obj = kind.make();
            owner.addObject(obj);
            map.set(obj, "value");
            set.add(obj);
            var ref = new WeakRef(obj);
            registry.register(obj, "released");
            __releaseNativeCounterpart(obj);

            expect(map.get(obj)).toBe("value");
            expect(set.has(obj)).toBe(true);
            expect(ref.deref() === undefined).toBe(true);
            settle(2, function () {
                expect(map.get(obj)).toBe("value");
                expect(set.has(obj)).toBe(true);
                expect(ref.deref() === undefined).toBe(true);
                var later = owner.objectAtIndex(0);
                expect(later === obj).toBe(false);
                expect(map.get(later)).toBe("value");
                expect(set.has(later)).toBe(true);
                expect(ref.deref() === later).toBe(true);
                later = null;
                obj = null;
                settle(3, function () {
                    expect(cleaned).toBe(false);
                    owner.removeAllObjects();
                    pollCleaned(function () {
                        return cleaned;
                    }, registry, function () {
                        expect(cleaned).toBe(true);
                        done();
                    });
                });
            });
        });

        it("keeps what was keyed on a native object JS owned alone while its released wrapper lives (" + kind.name + ")", function (done) {
            if (!canary) {
                done();
                return;
            }
            var map = new WeakMap();
            var cleaned = false;
            var registry = new FinalizationRegistry(function (held) {
                cleaned = held === "released";
            });
            var obj = kind.make();
            map.set(obj, "value");
            var ref = new WeakRef(obj);
            registry.register(obj, "released");
            __releaseNativeCounterpart(obj);

            expect(ref.deref() === undefined).toBe(true);
            expect(map.get(obj)).toBe("value");
            settle(2, function () {
                expect(map.get(obj)).toBe("value");
                expect(ref.deref() === undefined).toBe(true);
                expect(cleaned).toBe(false);
                obj = null;
                pollCleaned(function () {
                    return cleaned;
                }, registry, function () {
                    expect(cleaned).toBe(true);
                    done();
                });
            });
        });

        // __releaseNativeCounterpart frees a heavy native object early: in every
        // mode, neither its keys nor its released wrapper may keep it alive. The
        // weak table sees the object without retaining it.
        it("deallocates a keyed native object JS owned alone at its release (" + kind.name + ")", function () {
            var watch = NSHashTable.weakObjectsHashTable();
            var map = new WeakMap();
            var set = new WeakSet();
            var registry = new FinalizationRegistry(function () {});
            var obj = kind.make();
            watch.addObject(obj);
            map.set(obj, "value");
            set.add(obj);
            var ref = new WeakRef(obj);
            registry.register(obj, "held");
            __releaseNativeCounterpart(obj);

            expect(watch.allObjects.count).toBe(0);
            expect(map.get(obj)).toBe("value");
            expect(set.has(obj)).toBe(true);
            expect(ref.deref() === (canary ? undefined : obj)).toBe(true);
        });

        it("deallocates a released natively retained object once native code lets go, while its wrapper is held and dereferenced (" + kind.name + ")", function (done) {
            var watch = NSHashTable.weakObjectsHashTable();
            var owner = NSMutableArray.new();
            var map = new WeakMap();
            var set = new WeakSet();
            var obj = kind.make();
            owner.addObject(obj);
            watch.addObject(obj);
            map.set(obj, "value");
            set.add(obj);
            var ref = new WeakRef(obj);
            __releaseNativeCounterpart(obj);
            var expected = canary ? undefined : obj;

            // Whether every dereference gave the mode's expected target.
            function poke() {
                var matched = true;
                for (var i = 0; i < 10; i++) {
                    matched = ref.deref() === expected && matched;
                    map.get(obj);
                    set.has(obj);
                }
                return matched;
            }
            expect(poke()).toBe(true);
            settle(2, function () {
                expect(poke()).toBe(true);
                owner.removeAllObjects();
                expect(poke()).toBe(true);
                expect(watch.allObjects.count).toBe(0);
                expect(ref.deref() === expected).toBe(true);
                expect(map.get(obj)).toBe("value");
                expect(set.has(obj)).toBe(true);
                done();
            });
        });

        it("reports a weak collection operation on a wrapper released before anything keyed its object (" + kind.name + ")", function (done) {
            if (!canary) {
                done();
                return;
            }
            var messages = [];
            var onReleased = function (e) {
                if (/weak collection/.test(e.error.message)) {
                    messages.push(e.error.message);
                }
            };
            global.addEventListener("releasednativeaccess", onReleased);
            try {
                var map = new WeakMap();
                var before = releasedAccesses();
                var kept = releasedNeverKeyed(kind);
                map.set(kept, 1);
                expect(releasedAccesses()).toBe(before + 1);
                expect(map.get(kept) === 1).toBe(true);
                expect(releasedAccesses()).toBe(before + 1);
                new WeakRef(releasedNeverKeyed(kind));
                expect(releasedAccesses()).toBe(before + 2);
                expect(map.get(releasedNeverKeyed(kind))).toBeUndefined();
                expect(releasedAccesses()).toBe(before + 3);
            } catch (e) {
                global.removeEventListener("releasednativeaccess", onReleased);
                throw e;
            }
            setTimeout(function () {
                global.removeEventListener("releasednativeaccess", onReleased);
                expect(messages.length).toBe(3);
                for (var i = 0; i < messages.length; i++) {
                    expect(messages[i]).toMatch(/released by __releaseNativeCounterpart \(weak collection key/);
                }
                done();
            });
        });

        it("throws for a weak collection operation on a wrapper released before anything keyed its object under the throw policy (" + kind.name + ")", function () {
            if (!canary) {
                return;
            }
            var policy = runtime.getConfig("releasedObjectPolicy");
            runtime.setConfig("releasedObjectPolicy", "throw");
            try {
                var map = new WeakMap();
                expect(function () {
                    map.set(releasedNeverKeyed(kind), 1);
                }).toThrowError(ReferenceError, /weak collection key/);
                expect(function () {
                    new WeakRef(releasedNeverKeyed(kind));
                }).toThrowError(ReferenceError, /weak collection key/);
                expect(function () {
                    map.get(releasedNeverKeyed(kind));
                }).toThrowError(ReferenceError, /weak collection key/);
            } finally {
                runtime.setConfig("releasedObjectPolicy", policy);
            }
        });

        it("gets an undefined value stored on a wrapper released before anything keyed its object (" + kind.name + ")", function (done) {
            if (!canary) {
                done();
                return;
            }
            var map = new WeakMap();
            var obj = releasedNeverKeyed(kind);
            map.set(obj, undefined);
            var policy = runtime.getConfig("releasedObjectPolicy");
            runtime.setConfig("releasedObjectPolicy", "throw");
            try {
                var before = releasedAccesses();
                expect(map.get(obj) === undefined).toBe(true);
                expect(map.has(obj)).toBe(true);
                expect(releasedAccesses()).toBe(before);
            } finally {
                runtime.setConfig("releasedObjectPolicy", policy);
            }
            // Lets the report of the set() above be delivered within this spec.
            setTimeout(done);
        });

        it("does not report a weak collection operation on a released wrapper whose object was keyed (" + kind.name + ")", function () {
            var policy = runtime.getConfig("releasedObjectPolicy");
            runtime.setConfig("releasedObjectPolicy", "throw");
            try {
                var obj = kind.make();
                var map = new WeakMap();
                map.set(obj, 1);
                __releaseNativeCounterpart(obj);
                var before = releasedAccesses();
                var other = new WeakMap();
                expect(map.get(obj)).toBe(1);
                expect(other.get(obj)).toBeUndefined();
                other.set(obj, 2);
                expect(other.get(obj)).toBe(2);
                new WeakRef(obj);
                new WeakSet().add(obj);
                expect(releasedAccesses()).toBe(before);
            } finally {
                runtime.setConfig("releasedObjectPolicy", policy);
            }
        });
    });

    it("makes no key for a call the standard collection rejects", function () {
        var obj = Extended.new();
        var registry = new FinalizationRegistry(function () {});
        var map = new WeakMap();
        var states = runtime.getWrapperLifetimeStats().canaryStates;
        expect(function () {
            WeakMap.prototype.set.call({}, obj, 1);
        }).toThrowError(TypeError);
        expect(function () {
            WeakSet.prototype.add.call({}, obj);
        }).toThrowError(TypeError);
        expect(function () {
            registry.register(obj, "held", 1);
        }).toThrowError(TypeError);
        expect(function () {
            FinalizationRegistry.prototype.register.call({}, obj, "held");
        }).toThrowError(TypeError);
        if (typeof map.getOrInsertComputed === "function") {
            expect(function () {
                WeakMap.prototype.getOrInsert.call({}, obj, 1);
            }).toThrowError(TypeError);
            var computed = false;
            expect(function () {
                WeakMap.prototype.getOrInsertComputed.call({}, obj, function () {
                    computed = true;
                    return 1;
                });
            }).toThrowError(TypeError);
            expect(computed).toBe(false);
            expect(function () {
                map.getOrInsertComputed(obj, function () {
                    throw new Error("callback");
                });
            }).toThrowError("callback");
        }
        expect(runtime.getWrapperLifetimeStats().canaryStates).toBe(states);
    });

    it("hands getOrInsertComputed's callback the key it was given", function () {
        var map = new WeakMap();
        if (typeof map.getOrInsertComputed !== "function") {
            return;
        }
        var obj = Extended.new();
        var seen;
        expect(map.getOrInsertComputed(obj, function (key) {
            seen = key;
            return "computed";
        })).toBe("computed");
        expect(seen === obj).toBe(true);
        expect(map.get(obj)).toBe("computed");
    });

    it("matches the standard FinalizationRegistry.prototype.register signature and errors", function () {
        var registry = new FinalizationRegistry(function () {});
        expect(FinalizationRegistry.prototype.register.length).toBe(2);
        expect(function () {
            registry.register(1, 1);
        }).toThrowError(TypeError, /invalid target/);
    });

    it("installs the canary collections only in canary mode", function () {
        var native = WeakMap.toString().indexOf("[native code]") !== -1;
        expect(native).toBe(!canary);
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

    // With no native enumeration to inherit, an inherited JS iterator still
    // backs native enumeration.
    it("enumerates natively a JS class whose iterator comes from its implementation's prototype", function () {
        var Iterated = NSObject.extend(Object.create({
            [Symbol.iterator]: function* () {
                yield "only";
            }
        }), { name: "WrapperLifetimeWeakCollectionsInheritedIterator" });
        var obj = Iterated.alloc().init();
        TNSClearOutput();
        TNSObjCTypes.alloc().init().methodWithNSArray(obj);
        expect(TNSGetOutput()).toBe("only");
        TNSClearOutput();
    });
});
