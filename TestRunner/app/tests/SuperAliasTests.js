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
        var error = null;
        try {
            obj.hash;
        } catch (e) {
            error = e;
        }
        expect(error === null ? "<no error>" : String(error.message)).toContain("disposed native object");
    }

    function superGetter(cls) {
        return Object.getOwnPropertyDescriptor(Object.getPrototypeOf(cls.prototype), "super").get;
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
                expect(typeof obj.hash).toBe("number");
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
        expect(typeof obj.hash).toBe("number");
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
            expect(typeof hash).toBe("number");
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
            expect(typeof obj.hash).toBe("number");
            expect(alias.hash).toBe(obj.hash);
            expect(alias.description).toMatch(/^<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
        })();
        settle(3, function () {
            expect(deallocs()).toBe(1);
            done();
        });
    });

    it("resolves the alias of an alias to the original receiver", function (done) {
        var getter = superGetter(SuperAliasLog);
        var obj = SuperAliasLog.new();
        var alias = obj.super;
        var hash = obj.hash;
        expect(typeof hash).toBe("number");
        [getter.call(alias), getter.call(new Proxy(alias, {}))].forEach(function (aliasOfAlias) {
            expect(Object.getPrototypeOf(aliasOfAlias)).toBe(Object.getPrototypeOf(alias));
            expect(aliasOfAlias.hash).toBe(hash);
            expect(aliasOfAlias.description).toMatch(/^<SuperAliasLog\w*: 0x[0-9a-f]+>$/);
        });
        var aliasOfAlias = getter.call(alias);
        __releaseNativeCounterpart(aliasOfAlias);
        expect(function () {
            __releaseNativeCounterpart(aliasOfAlias);
        }).toThrowError(/not a native wrapper/);
        settle(3, function () {
            expect(deallocs()).toBe(1);
            expectReleased(obj);
            expectReleased(alias);
            expectReleased(aliasOfAlias);
            obj = null;
            alias = null;
            aliasOfAlias = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    // `super` is an enumerable accessor of the implementation object.
    it("reads undefined when the accessor's receiver is not a native instance", function () {
        var SuperAliasPlain = NSObject.extend({
            init: function () {
                return this.super.init();
            }
        }, { name: "SuperAliasPlain" });
        var implementation = Object.getPrototypeOf(SuperAliasPlain.prototype);
        expect(superGetter(SuperAliasPlain).call({})).toBeUndefined();
        expect(implementation.super).toBeUndefined();
        expect(SuperAliasPlain.prototype.super).toBeUndefined();
        var copy = null;
        expect(function () {
            copy = Object.assign({}, implementation);
        }).not.toThrow();
        expect(Object.prototype.hasOwnProperty.call(copy, "super")).toBe(true);
        expect(copy.super).toBeUndefined();
    });
});

// Teardown disposes the worker's registered objects newest first, so an alias
// is disposed before its receiver while both still read the same wrapper. An
// alias that is not kept stays registered until a major collection finalizes
// it, so the one the initializer evaluates counts too.
describe("this.super aliases at worker teardown", function () {
    var originalTimeout;
    beforeEach(function () {
        originalTimeout = jasmine.DEFAULT_TIMEOUT_INTERVAL;
        jasmine.DEFAULT_TIMEOUT_INTERVAL = 10000;
    });
    afterEach(function () {
        jasmine.DEFAULT_TIMEOUT_INTERVAL = originalTimeout;
    });

    function terminateWhenReady(source, done) {
        var worker = new Worker("~/shared/Workers/EvalWorker.js");
        worker.onmessage = function (msg) {
            expect(msg.data).toBe("ready");
            worker.terminate();
            setTimeout(done, 600);
        };
        worker.onerror = function (e) {
            expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
            done();
        };
        worker.postMessage({
            eval: "var Ext = NSObject.extend({" +
                "    init: function () { return this.super.init(); }" +
                "}, { name: 'SuperAliasTeardownObject' });" +
                "globalThis.superAliasObject = Ext.new();" +
                source +
                "postMessage('ready');"
        });
    }

    it("disposes an object and a kept alias of it", function (done) {
        terminateWhenReady("globalThis.superAlias = globalThis.superAliasObject.super;", done);
    });

    it("disposes an object whose only alias was its initializer's", function (done) {
        terminateWhenReady("", done);
    });
});
