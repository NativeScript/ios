// Wrappers created for objects that native code hands to JS-implemented
// methods, and the native objects attached to errors: kept while native code
// owns them, released exactly once afterwards.
describe("Native callback self wrappers", function () {
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

    var initCalls = 0;
    var JSInit = (function (_super) {
        __extends(JSInit, _super);
        function JSInit() {
            return (_super !== null && _super.apply(this, arguments)) || this;
        }
        JSInit.prototype.init = function () {
            var self = _super.prototype.init.call(this);
            initCalls++;
            self.initialized = true;
            return self;
        };
        return JSInit;
    })(TNSAllocLog);

    // Objects earlier specs dropped are collected first, so the dealloc log
    // only counts this spec's objects.
    beforeEach(function (done) {
        settle(2, function () {
            TNSClearOutput();
            initCalls = 0;
            done();
        });
    });

    // +new runs the JS-implemented init from native code, before JS has a
    // wrapper for the object.
    it("keeps the JS state of a natively owned object whose JS initializer created its wrapper, then frees it once", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = JSInit.new();
            obj.state = { i: 1 };
            owner.addObject(obj);
        })();
        settle(3, function () {
            var obj = owner.objectAtIndex(0);
            expect(initCalls).toBe(1);
            expect(obj.initialized).toBe(true);
            expect(obj.state && obj.state.i).toBe(1);
            obj = null;
            expect(deallocs()).toBe(0);
            owner.removeAllObjects();
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("frees an object JS alone holds after +new ran its JS initializer", function (done) {
        var obj = JSInit.new();
        obj.state = { i: 2 };
        settle(2, function () {
            expect(obj.state.i).toBe(2);
            expect(deallocs()).toBe(0);
            obj = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("keeps the JS state of cells UIKit creates from a registered class until their superview lets them go", function (done) {
        var cellInits = 0;
        var Cell = UITableViewCell.extend({
            initWithStyleReuseIdentifier: function (style, reuseIdentifier) {
                var cell = UITableViewCell.prototype.initWithStyleReuseIdentifier.call(this, style, reuseIdentifier);
                cellInits++;
                cell.fromInitializer = true;
                return cell;
            }
        }, { name: "NativeCallbackSelfCell" });
        var watch = NSHashTable.weakObjectsHashTable();
        var host = UIView.new();
        (function () {
            var table = UITableView.new();
            table.registerClassForCellReuseIdentifier(Cell.class(), "cell");
            for (var i = 0; i < 4; i++) {
                var cell = table.dequeueReusableCellWithIdentifier("cell");
                cell.owner = { row: i };
                host.addSubview(cell);
                watch.addObject(cell);
            }
        })();
        settle(3, function () {
            expect(cellInits).toBe(4);
            var subviews = host.subviews;
            expect(subviews.count).toBe(4);
            for (var i = 0; i < subviews.count; i++) {
                var cell = subviews.objectAtIndex(i);
                expect(cell.fromInitializer).toBe(true);
                expect(cell.owner && cell.owner.row).toBe(i);
            }
            subviews = null;
            cell = null;
            (function () {
                var views = host.subviews;
                for (var j = views.count - 1; j >= 0; j--) {
                    views.objectAtIndex(j).removeFromSuperview();
                }
            })();
            settle(4, function () {
                expect(host.subviews.count).toBe(0);
                expect(watch.allObjects.count).toBe(0);
                done();
            });
        });
    });

    it("frees a managed wrapper's object once when __releaseNativeCounterpart runs on it", function (done) {
        var owner = NSMutableArray.new();
        var natively = JSInit.new();
        owner.addObject(natively);
        var jsOnly = JSInit.new();
        settle(2, function () {
            __releaseNativeCounterpart(natively);
            __releaseNativeCounterpart(jsOnly);
            natively = null;
            jsOnly = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                owner.removeAllObjects();
                settle(3, function () {
                    expect(deallocs()).toBe(2);
                    done();
                });
            });
        });
    });

    it("does not release an instance method's owned return that is its receiver", function (done) {
        var obj = TNSAllocLog.alloc().init();
        var same = obj.awakeAfterUsingCoder(null);
        expect(same).toBe(obj);
        settle(3, function () {
            expect(deallocs()).toBe(0);
            expect(obj.hash > 0).toBe(true);
            done();
        });
    });

    it("does not release what a JS copyWithZone hands to a native -copy", function (done) {
        var target = TNSAllocLog.alloc().init();
        var Copyable = TNSAllocLog.extend({
            copyWithZone: function (zone) {
                return target;
            }
        }, { name: "NativeCallbackSelfCopyable", protocols: [NSCopying] });
        var original = Copyable.alloc().init();
        var copy = original.copy();
        expect(copy).toBe(target);
        copy = null;
        settle(3, function () {
            expect(deallocs()).toBe(0);
            expect(target.hash > 0).toBe(true);
            expect(original.hash > 0).toBe(true);
            done();
        });
    });

    it("reports a receiver kept from a JS method run by -dealloc as released", function (done) {
        var saved = null;
        var Keeper = TNSApi.extend({
            methodCalledInDealloc: function () {
                saved = this;
            }
        }, { name: "NativeCallbackSelfDeallocKeeper" });
        (function () {
            var holder = NSMutableArray.alloc().init();
            holder.addObject(Keeper.alloc().init());
        })();
        settle(4, function () {
            expect(saved).not.toBeNull();
            var value;
            var threw = false;
            try {
                value = saved.hash;
            } catch (e) {
                threw = e instanceof ReferenceError;
            }
            expect(threw || value === undefined).toBe(true);
            saved = null;
            done();
        });
    });

    it("keeps an error's NSError while the error lives and frees it afterwards", function (done) {
        var watch = NSHashTable.weakObjectsHashTable();
        var error = null;
        try {
            NSFileManager.defaultManager.contentsOfDirectoryAtPathError("/nonexistent-native-callback-self");
        } catch (e) {
            error = e;
        }
        expect(error).not.toBeNull();
        expect(error.nativeException).toBeDefined();
        watch.addObject(error.nativeException);
        settle(3, function () {
            expect(watch.allObjects.count).toBe(1);
            expect(error.nativeException.code).toBe(error.code);
            error = null;
            settle(3, function () {
                expect(watch.allObjects.count).toBe(0);
                done();
            });
        });
    });

    it("keeps an error's NSException while the error lives and frees it afterwards", function (done) {
        var watch = NSHashTable.weakObjectsHashTable();
        var error = null;
        try {
            NSArray.array().objectAtIndex(3);
        } catch (e) {
            error = e;
        }
        expect(error).not.toBeNull();
        expect(error.nativeException).toBeDefined();
        watch.addObject(error.nativeException);
        settle(3, function () {
            expect(watch.allObjects.count).toBe(1);
            expect(error.nativeException.name).toBe("NSRangeException");
            error = null;
            settle(3, function () {
                expect(watch.allObjects.count).toBe(0);
                done();
            });
        });
    });
});
