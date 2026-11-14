// `this.super` on an extend() class: an alias that dispatches to the
// superclass implementation and reads its receiver's native object, never a
// copy of it.
describe("this.super aliases", function () {
    function scrub(n) {
        return n > 0 ? scrub(n - 1) + n : 0;
    }

    // Collect, then give autorelease pools and posted retain/release work a
    // turn of the run loop.
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

    function deallocs() {
        return (TNSGetOutput().match(/TNSAllocLog dealloc/g) || []).length;
    }

    function expectReleased(obj) {
        var value;
        var error = null;
        try {
            value = obj.hash;
        } catch (e) {
            error = e;
        }
        if (error !== null) {
            expect(error.message).toContain("disposed native object");
        } else {
            expect(value).toBeUndefined();
        }
    }

    var superInits = 0;
    var SuperAliasLog = TNSAllocLog.extend({
        init: function () {
            var self = this.super.init();
            superInits++;
            return self;
        },
        get description() {
            return "js:" + this.super.description;
        }
    }, { name: "SuperAliasLog" });

    // Objects earlier specs dropped are collected first, so the dealloc log
    // only counts this spec's objects.
    beforeEach(function (done) {
        settle(2, function () {
            TNSClearOutput();
            superInits = 0;
            done();
        });
    });

    it("dispatches initializers, methods and properties to the superclass", function (done) {
        (function () {
            var constructed = new SuperAliasLog();
            var created = SuperAliasLog.new();
            expect(superInits).toBe(2);
            [constructed, created].forEach(function (obj) {
                expect(obj instanceof SuperAliasLog).toBe(true);
                expect(obj.description).toMatch(/^js:<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
                expect(obj.super.description).toMatch(/^<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
                expect(obj.super.hash).toBe(obj.hash);
                expect(obj.super.isEqual(obj)).toBe(true);
            });
        })();
        settle(3, function () {
            expect(deallocs()).toBe(2);
            done();
        });
    });

    it("reports an alias as released once its receiver was released with __releaseNativeCounterpart", function (done) {
        var obj = SuperAliasLog.new();
        var alias = obj.super;
        expect(alias.hash).toBe(obj.hash);
        __releaseNativeCounterpart(obj);
        settle(3, function () {
            expect(deallocs()).toBe(1);
            expectReleased(alias);
            expectReleased(obj);
            obj = null;
            alias = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("keeps its receiver alive while the alias is reachable, then frees it once", function (done) {
        var watch = NSHashTable.weakObjectsHashTable();
        var alias = null;
        var hash = 0;
        (function () {
            var obj = SuperAliasLog.new();
            hash = obj.hash;
            watch.addObject(obj);
            alias = obj.super;
        })();
        settle(4, function () {
            expect(deallocs()).toBe(0);
            expect(watch.allObjects.count).toBe(1);
            expect(alias.hash).toBe(hash);
            settle(2, function () {
                expect(deallocs()).toBe(0);
                expect(alias.description).toMatch(/^<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
                alias = null;
                settle(4, function () {
                    expect(deallocs()).toBe(1);
                    expect(watch.allObjects.count).toBe(0);
                    settle(2, function () {
                        expect(deallocs()).toBe(1);
                        done();
                    });
                });
            });
        });
    });

    it("reports an alias saved from a JS method run by -dealloc as released", function (done) {
        var saved = null;
        var Keeper = TNSApi.extend({
            methodCalledInDealloc: function () {
                saved = this.super;
            }
        }, { name: "SuperAliasDeallocKeeper" });
        (function () {
            var holder = NSMutableArray.alloc().init();
            holder.addObject(Keeper.alloc().init());
        })();
        settle(4, function () {
            expect(saved).not.toBeNull();
            expectReleased(saved);
            saved = null;
            done();
        });
    });

    it("releases the receiver when __releaseNativeCounterpart is given an alias", function (done) {
        var obj = SuperAliasLog.new();
        var alias = obj.super;
        __releaseNativeCounterpart(alias);
        settle(3, function () {
            expect(deallocs()).toBe(1);
            expectReleased(obj);
            expectReleased(alias);
            expectReleased(obj.super);
            obj = null;
            alias = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("resolves the alias of a Proxy over the receiver to the receiver", function (done) {
        (function () {
            var obj = SuperAliasLog.new();
            var alias = new Proxy(obj, {}).super;
            expect(alias.hash).toBe(obj.hash);
            expect(alias.description).toMatch(/^<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
        })();
        settle(3, function () {
            expect(deallocs()).toBe(1);
            done();
        });
    });

    it("throws a TypeError when the accessor is called on an object that is not a native instance", function () {
        var implementation = Object.getPrototypeOf(SuperAliasLog.prototype);
        var getter = Object.getOwnPropertyDescriptor(implementation, "super").get;
        expect(function () {
            getter.call({});
        }).toThrowError(TypeError);
    });
});
