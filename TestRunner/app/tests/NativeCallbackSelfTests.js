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

    // The JS init runs from native code on an object JS has no wrapper for
    // yet; wrapping it must not send it a message its JS class implements.
    function expectRespondsToSelectorOverrideWorks(Responder, counter) {
        var creators = [
            function () {
                return Responder.alloc().init();
            },
            function () {
                return Responder.new();
            }
        ];
        creators.forEach(function (create) {
            counter.inits = 0;
            counter.responds = 0;
            counter.voidCalls = 0;
            var obj = create();
            expect(obj instanceof Responder).toBe(true);
            expect(counter.inits).toBe(1);
            TNSTestNativeCallbacks.inheritanceVoidSelector(obj);
            expect(counter.responds).toBeGreaterThan(0);
            expect(counter.voidCalls).toBe(1);
        });
    }

    it("wraps objects of an extend() class that implements respondsToSelector", function () {
        var counter = {};
        var Responder = NSObject.extend({
            init: function () {
                counter.inits++;
                return NSObject.prototype.init.call(this);
            },
            respondsToSelector: function (selector) {
                counter.responds++;
                return NSObject.prototype.respondsToSelector.call(this, selector);
            },
            voidSelector: function () {
                counter.voidCalls++;
            }
        }, {
            name: "NativeCallbackSelfResponder",
            exposedMethods: {
                voidSelector: { returns: interop.types.void }
            }
        });
        expectRespondsToSelectorOverrideWorks(Responder, counter);
    });

    it("wraps objects of an __extends class that implements respondsToSelector", function () {
        var counter = {};
        var Responder = (function (_super) {
            __extends(Responder, _super);
            function Responder() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Responder.prototype.init = function () {
                counter.inits++;
                return _super.prototype.init.call(this);
            };
            Responder.prototype.respondsToSelector = function (selector) {
                counter.responds++;
                return _super.prototype.respondsToSelector.call(this, selector);
            };
            Responder.prototype.voidSelector = function () {
                counter.voidCalls++;
            };
            Responder.ObjCExposedMethods = {
                voidSelector: { returns: interop.types.void }
            };
            return Responder;
        })(NSObject);
        expectRespondsToSelectorOverrideWorks(Responder, counter);
    });

    // Native callers own what an init-family method returns, including an
    // object a JS initializer answers in place of its receiver.
    function expectInitializerResultOwnedByCaller(create, done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = create();
            expect(obj instanceof TNSAllocLog).toBe(true);
            owner.addObject(obj);
        })();
        settle(3, function () {
            expect(initCalls).toBe(1);
            expect(deallocs()).toBe(0);
            var obj = owner.objectAtIndex(0);
            expect(obj instanceof TNSAllocLog).toBe(true);
            expect(obj.hash > 0).toBe(true);
            obj = null;
            owner.removeAllObjects();
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    }

    var initResult = null;
    var InitReturnsOther = NSObject.extend({
        init: function () {
            initCalls++;
            return initResult;
        }
    }, { name: "NativeCallbackSelfInitReturnsOther" });

    function createThroughInitReturningOther(construct) {
        initResult = TNSAllocLog.new();
        var obj = construct();
        expect(obj).toBe(initResult);
        initResult = null;
        return obj;
    }

    it("keeps a wrapped object a JS initializer returns instead of its receiver (+new)", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return createThroughInitReturningOther(function () {
                return InitReturnsOther.new();
            });
        }, done);
    });

    it("keeps a wrapped object a JS initializer returns instead of its receiver (new)", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return createThroughInitReturningOther(function () {
                return new InitReturnsOther();
            });
        }, done);
    });

    var InitReturnsSubstitute = TNSSubstitutingInit.extend({
        init: function () {
            initCalls++;
            return TNSSubstitutingInit.prototype.init.call(this);
        }
    }, { name: "NativeCallbackSelfInitReturnsSubstitute" });

    it("keeps the substitute a super initializer returned through a JS initializer (+new)", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return InitReturnsSubstitute.new();
        }, done);
    });

    it("keeps the substitute a super initializer returned through a JS initializer (new)", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return new InitReturnsSubstitute();
        }, done);
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
            var error = null;
            try {
                value = saved.hash;
            } catch (e) {
                error = e;
            }
            if (error !== null) {
                expect(error.message).toContain("disposed native object");
            } else {
                expect(value).toBeUndefined();
            }
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

    it("leaves the retain count of an immutable object whose -copy answers itself unchanged", function (done) {
        var array = NSArray.arrayWithArray([1, 2, 3]);
        settle(2, function () {
            var before = array.retainCount();
            var same = 0;
            for (var i = 0; i < 50; i++) {
                if (array.copy() === array) {
                    same++;
                }
            }
            expect(same).toBe(50);
            settle(2, function () {
                expect(array.retainCount()).toBe(before);
                done();
            });
        });
    });

    it("frees an object JS alone holds after alloc().init() ran its JS initializer", function (done) {
        var obj = JSInit.alloc().init();
        obj.state = { i: 3 };
        settle(2, function () {
            expect(initCalls).toBe(1);
            expect(obj.state.i).toBe(3);
            expect(deallocs()).toBe(0);
            obj = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("keeps the JS state of a natively owned object whose JS initializer ran from alloc().init(), then frees it once", function (done) {
        var owner = NSMutableArray.new();
        (function () {
            var obj = JSInit.alloc().init();
            obj.state = { i: 4 };
            owner.addObject(obj);
        })();
        settle(3, function () {
            var obj = owner.objectAtIndex(0);
            expect(initCalls).toBe(1);
            expect(obj.initialized).toBe(true);
            expect(obj.state && obj.state.i).toBe(4);
            obj = null;
            expect(deallocs()).toBe(0);
            owner.removeAllObjects();
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    it("keeps a wrapped object a JS initializer returns instead of its receiver (alloc().init())", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return createThroughInitReturningOther(function () {
                return InitReturnsOther.alloc().init();
            });
        }, done);
    });

    it("keeps the substitute a super initializer returned through a JS initializer (alloc().init())", function (done) {
        expectInitializerResultOwnedByCaller(function () {
            return InitReturnsSubstitute.alloc().init();
        }, done);
    });

    it("does not release a wrapped receiver that is initialized again", function (done) {
        var plain = TNSAllocLog.new();
        var jsInit = JSInit.new();
        expect(plain.init()).toBe(plain);
        expect(TNSAllocLog.prototype.init.call(plain)).toBe(plain);
        expect(TNSAllocLog.prototype.init.apply(plain, [])).toBe(plain);
        expect(jsInit.init()).toBe(jsInit);
        expect(JSInit.prototype.init.call(jsInit)).toBe(jsInit);
        expect(JSInit.prototype.init.apply(jsInit, [])).toBe(jsInit);
        expect(TNSAllocLog.prototype.init.call(jsInit)).toBe(jsInit);
        settle(3, function () {
            var freed = deallocs();
            expect(freed).toBe(0);
            if (freed === 0) {
                expect(plain.hash > 0).toBe(true);
                expect(jsInit.initialized).toBe(true);
            }
            plain = null;
            jsInit = null;
            settle(3, function () {
                expect(deallocs()).toBe(2);
                done();
            });
        });
    });

    // Native code that owns what an owned-return method answers drops it. The
    // object a JS implementation answered must outlive that, and be freed
    // exactly once after JS lets go. TNSOwnedReturns and TNSAllocLog log their
    // deallocation; `freedAfterwards` counts those among receiver and result.
    function expectKeptThroughNativeDrop(state, drop, freedAfterwards, done) {
        drop(state.receiver);
        settle(3, function () {
            var freed = deallocs();
            expect(freed).toBe(0);
            if (freed === 0) {
                expect(state.receiver.hash > 0).toBe(true);
                expect(state.result.hash > 0).toBe(true);
            }
            state.receiver = null;
            state.result = null;
            settle(3, function () {
                expect(deallocs()).toBe(freedAfterwards);
                done();
            });
        });
    }

    function ownedReturnState(base, name, method, protocols, answersReceiver, extra) {
        var state = {};
        var implementation = {};
        var answer = function () {
            return answersReceiver ? this : state.result;
        };
        // `extra.getter` implements `method` as a property getter;
        // `extra.exposedMethods` declares it to a class that has no metadata
        // for it.
        extra = extra || {};
        if (extra.getter) {
            Object.defineProperty(implementation, method, { get: answer, enumerable: true, configurable: true });
        } else {
            implementation[method] = answer;
        }
        var Klass = base.extend(implementation, { name: name, protocols: protocols, exposedMethods: extra.exposedMethods });
        state.receiver = Klass.new();
        state.result = answersReceiver ? state.receiver : TNSAllocLog.new();
        return state;
    }

    it("hands a native -copy the receiver a JS copyWithZone answers at +1", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfCopySelf", "copyWithZone", [NSCopying], true);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.copyAndDrop(receiver);
        }, 1, done);
    });

    it("hands a native -copy the other object a JS copyWithZone answers at +1", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfCopyOther", "copyWithZone", [NSCopying], false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.copyAndDrop(receiver);
        }, 2, done);
    });

    it("hands a native -mutableCopy the object a JS mutableCopyWithZone answers at +1", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfMutableCopy", "mutableCopyWithZone", [NSMutableCopying], false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.mutableCopyAndDrop(receiver);
        }, 2, done);
    });

    it("hands a native caller the object a JS new-family method answers at +1", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfNewOther", "newChild", [], false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newChildAndDrop(receiver);
        }, 2, done);
    });

    it("hands a native caller the receiver a JS new-family method answers at +1", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfNewSelf", "newChild", [], true);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newChildAndDrop(receiver);
        }, 1, done);
    });

    it("hands a native caller back the receiver a JS awakeAfterUsingCoder answers", function (done) {
        var state = ownedReturnState(TNSOwnedReturns, "NativeCallbackSelfAwakeSelf", "awakeAfterUsingCoder", [], true);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.awakeAndDrop(receiver);
        }, 1, done);
    });

    // The receiver is not a TNSAllocLog: its reference, consumed by the call,
    // is not given back when the JS method answers another object.
    it("hands a native caller the other object a JS awakeAfterUsingCoder answers at +1", function (done) {
        var state = ownedReturnState(NSObject, "NativeCallbackSelfAwakeOther", "awakeAfterUsingCoder", [], false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.awakeAndDrop(receiver);
        }, 1, done);
    });

    function expectBalancedJsCopies(answersReceiver, name, done) {
        var state = ownedReturnState(TNSOwnedReturns, name, "copyWithZone", [NSCopying], answersReceiver);
        for (var i = 0; i < 20; i++) {
            expect(state.receiver.copy()).toBe(state.result);
        }
        settle(3, function () {
            var freed = deallocs();
            expect(freed).toBe(0);
            if (freed === 0) {
                expect(state.receiver.hash > 0).toBe(true);
                expect(state.result.hash > 0).toBe(true);
            }
            state.receiver = null;
            state.result = null;
            settle(3, function () {
                expect(deallocs()).toBe(answersReceiver ? 1 : 2);
                done();
            });
        });
    }

    it("balances copy() called from JS on a JS copyWithZone that answers its receiver", function (done) {
        expectBalancedJsCopies(true, "NativeCallbackSelfJsCopySelf", done);
    });

    it("balances copy() called from JS on a JS copyWithZone that answers another object", function (done) {
        expectBalancedJsCopies(false, "NativeCallbackSelfJsCopyOther", done);
    });

    it("hands a native caller the object a JS new-family method without metadata answers at +1", function (done) {
        var state = ownedReturnState(TNSAllocLog, "NativeCallbackSelfExposedNew", "newChild", [], false, {
            exposedMethods: { newChild: { returns: NSObject, params: [] } }
        });
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newChildAndDrop(receiver);
        }, 2, done);
    });

    function ownedGetterState(answersReceiver, name) {
        return ownedReturnState(TNSOwnedReturns, name, "newItem", [], answersReceiver, { getter: true });
    }

    it("hands a native caller the other object a JS new-family getter answers at +1", function (done) {
        var state = ownedGetterState(false, "NativeCallbackSelfGetterOther");
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newItemAndDrop(receiver);
        }, 2, done);
    });

    it("hands a native caller the receiver a JS new-family getter answers at +1", function (done) {
        var state = ownedGetterState(true, "NativeCallbackSelfGetterSelf");
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newItemAndDrop(receiver);
        }, 1, done);
    });

    function expectBalancedGetterReads(answersReceiver, name, done) {
        var state = ownedGetterState(answersReceiver, name);
        for (var i = 0; i < 20; i++) {
            expect(state.receiver.newItem).toBe(state.result);
            expect(TNSOwnedReturns.readNewItemOf(state.receiver)).toBe(state.result);
        }
        expectKeptThroughNativeDrop(state, function () {}, answersReceiver ? 1 : 2, done);
    }

    it("balances reads of a JS new-family getter that answers another object", function (done) {
        expectBalancedGetterReads(false, "NativeCallbackSelfGetterReadsOther", done);
    });

    it("balances reads of a JS new-family getter that answers its receiver", function (done) {
        expectBalancedGetterReads(true, "NativeCallbackSelfGetterReadsSelf", done);
    });

    // The replacements stay installed for the rest of the run, on a class no
    // other spec uses, and answer what `swizzled.answer` gives them.
    var swizzled = { installed: false, answer: null };

    function swizzledState(answersReceiver) {
        if (!swizzled.installed) {
            swizzled.installed = true;
            TNSSwizzledOwnedReturns.prototype.newChild = function () {
                return swizzled.answer(this);
            };
            Object.defineProperty(TNSSwizzledOwnedReturns.prototype, "newItem", {
                get: function () {
                    return swizzled.answer(this);
                },
                configurable: true
            });
        }
        var state = { receiver: TNSSwizzledOwnedReturns.new() };
        state.result = answersReceiver ? state.receiver : TNSAllocLog.new();
        swizzled.answer = function (self) {
            return answersReceiver ? self : state.result;
        };
        return state;
    }

    it("hands a native caller the other object a JS replacement of a new-family method answers at +1", function (done) {
        var state = swizzledState(false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newChildAndDrop(receiver);
        }, 2, done);
    });

    it("hands a native caller the receiver a JS replacement of a new-family method answers at +1", function (done) {
        var state = swizzledState(true);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newChildAndDrop(receiver);
        }, 1, done);
    });

    it("hands a native caller the other object a JS replacement of a new-family getter answers at +1", function (done) {
        var state = swizzledState(false);
        expectKeptThroughNativeDrop(state, function (receiver) {
            TNSOwnedReturns.newItemAndDrop(receiver);
            expect(TNSOwnedReturns.readNewItemOf(receiver)).toBe(state.result);
        }, 2, done);
    });

    it("frees once an object whose native -init ran a JS method on it (alloc().init())", function (done) {
        var hooks = 0;
        var Hooked = TNSInitCallsHook.extend({
            initHook: function () {
                hooks++;
                this.hooked = true;
            }
        }, { name: "NativeCallbackSelfInitHook" });
        var obj = Hooked.alloc().init();
        expect(hooks).toBe(1);
        expect(obj.hooked).toBe(true);
        settle(3, function () {
            expect(deallocs()).toBe(0);
            expect(obj.hash > 0).toBe(true);
            obj = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    // -unarchiver:didDecodeObject: takes over the object it is given
    // (NS_RELEASES_ARGUMENT) and answers an owned one.
    var decodeAnswer = null;
    var decodeCalls = 0;
    var DecodeDelegate = NSObject.extend({
        unarchiverDidDecodeObject: function (unarchiver, object) {
            decodeCalls++;
            return decodeAnswer(object);
        }
    }, { name: "NativeCallbackSelfDecodeDelegate", protocols: [NSKeyedUnarchiverDelegate] });

    // The same method with no metadata to describe it.
    var ExposedDecodeDelegate = NSObject.extend({
        "unarchiver:didDecodeObject:": function (unarchiver, object) {
            decodeCalls++;
            return decodeAnswer(object);
        }
    }, {
        name: "NativeCallbackSelfExposedDecodeDelegate",
        exposedMethods: {
            "unarchiver:didDecodeObject:": { returns: NSObject, params: [NSObject, NSObject] }
        }
    });

    // Decodes an array of two TNSCodingAllocLogs through a `Delegate`
    // answering `answer(object)`, or through none when `answer` is null.
    // `freedAfterDecode` TNSAllocLogs are gone once the unarchiver is,
    // `freedAtEnd` once JS drops the decoded root too.
    function expectBalancedDecode(Delegate, answer, freedAfterDecode, freedAtEnd, checkRoot, done) {
        var data = (function () {
            var root = NSMutableArray.new();
            root.addObject(TNSCodingAllocLog.new());
            root.addObject(TNSCodingAllocLog.new());
            return NSKeyedArchiver.archivedDataWithRootObjectRequiringSecureCodingError(root, false);
        })();
        settle(3, function () {
            expect(deallocs()).toBe(2);
            TNSClearOutput();
            var state = {};
            (function () {
                var delegate = answer ? Delegate.new() : null;
                decodeAnswer = answer;
                decodeCalls = 0;
                var unarchiver = NSKeyedUnarchiver.alloc().initForReadingFromDataError(data);
                unarchiver.requiresSecureCoding = false;
                unarchiver.delegate = delegate;
                state.root = unarchiver.decodeObjectForKey(NSKeyedArchiveRootObjectKey);
                unarchiver.finishDecoding();
                unarchiver.delegate = null;
                decodeAnswer = null;
            })();
            expect(decodeCalls).toBe(answer ? 3 : 0);
            settle(3, function () {
                expect(deallocs()).toBe(freedAfterDecode);
                checkRoot(state.root);
                state.root = null;
                settle(3, function () {
                    expect(deallocs()).toBe(freedAtEnd);
                    done();
                });
            });
        });
    }

    function expectDecodedRoot(elementClass) {
        return function (root) {
            expect(root instanceof NSArray).toBe(true);
            expect(root.count).toBe(2);
            for (var i = 0; i < root.count; i++) {
                var element = root.objectAtIndex(i);
                expect(element instanceof elementClass).toBe(true);
                expect(element.hash > 0).toBe(true);
            }
        };
    }

    it("decodes without an unarchiver delegate", function (done) {
        expectBalancedDecode(null, null, 0, 2, expectDecodedRoot(TNSCodingAllocLog), done);
    });

    [
        { Delegate: DecodeDelegate, suffix: "" },
        { Delegate: ExposedDecodeDelegate, suffix: " (exposedMethods, no protocol)" }
    ].forEach(function (variant) {
        var Delegate = variant.Delegate;

        it("hands an unarchiver back the objects a JS delegate answers unchanged" + variant.suffix, function (done) {
            expectBalancedDecode(Delegate, function (object) {
                return object;
            }, 0, 2, expectDecodedRoot(TNSCodingAllocLog), done);
        });

        it("releases the objects a JS unarchiver delegate replaces" + variant.suffix, function (done) {
            expectBalancedDecode(Delegate, function (object) {
                return object instanceof TNSCodingAllocLog ? TNSAllocLog.new() : object;
            }, 2, 4, function (root) {
                expectDecodedRoot(TNSAllocLog)(root);
                expect(root.objectAtIndex(0) instanceof TNSCodingAllocLog).toBe(false);
            }, done);
        });

        // The unarchiver keeps an object its delegate answers nil for.
        it("releases the objects a JS unarchiver delegate answers nil for" + variant.suffix, function (done) {
            expectBalancedDecode(Delegate, function (object) {
                return null;
            }, 0, 2, expectDecodedRoot(TNSCodingAllocLog), done);
        });
    });

    it("gives a native unarchiver delegate called from JS the reference it takes over", function (done) {
        var delegate = TNSDecodeDelegate.new();
        var object = TNSAllocLog.new();
        var i;
        for (i = 0; i < 20; i++) {
            expect(delegate.unarchiverDidDecodeObject(null, object)).toBe(object);
        }
        delegate.substitutes = true;
        for (i = 0; i < 20; i++) {
            var other = delegate.unarchiverDidDecodeObject(null, object);
            expect(other instanceof TNSAllocLog).toBe(true);
            expect(other).not.toBe(object);
        }
        other = null;
        settle(3, function () {
            var freed = deallocs();
            expect(freed).toBe(20);
            if (freed === 20) {
                expect(object.hash > 0).toBe(true);
            }
            object = null;
            settle(3, function () {
                expect(deallocs()).toBe(21);
                done();
            });
        });
    });

    // JS receives these as primitives, so only the native side sees their
    // reference counts.
    var primitiveText = "an owned string long enough to live on the heap";
    var primitiveDateTime = (700000000.5 + 978307200) * 1000;

    function expectPrimitiveAt(index, value) {
        if (index === 0) {
            expect(value).toBe(primitiveText);
        } else if (index === 1) {
            expect(value).toBe(Math.PI);
        } else {
            expect(value instanceof Date).toBe(true);
            expect(value.getTime()).toBe(primitiveDateTime);
        }
    }

    function expectPrimitivesRetainedAsBefore(read, done) {
        var holder = TNSOwnedPrimitives.new();
        for (var i = 0; i < 3; i++) {
            expect([i, holder.isTaggedPointerAt(i)]).toEqual([i, false]);
        }
        settle(2, function () {
            var before = [];
            for (var i = 0; i < 3; i++) {
                before.push(holder.retainCountAt(i));
                for (var k = 0; k < 20; k++) {
                    expectPrimitiveAt(i, read(holder, i));
                }
            }
            settle(2, function () {
                for (var i = 0; i < 3; i++) {
                    expect([i, holder.retainCountAt(i)]).toEqual([i, before[i]]);
                }
                done();
            });
        });
    }

    it("releases owned results JS receives as a string, a number and a date", function (done) {
        expectPrimitivesRetainedAsBefore(function (holder, index) {
            return holder.newObjectAt(index);
        }, done);
    });

    it("leaves unowned results JS receives as primitives retained as they were", function (done) {
        expectPrimitivesRetainedAsBefore(function (holder, index) {
            return holder.objectAt(index);
        }, done);
    });

    function copiesAsStringState(name, answer) {
        var state = { answer: answer };
        var Copyable = TNSAllocLog.extend({
            copyWithZone: function () {
                return state.answer;
            }
        }, { name: name, protocols: [NSCopying] });
        state.receiver = Copyable.new();
        return state;
    }

    it("releases the string a native -copy answers for a JS copyWithZone returning an NSString", function (done) {
        var text = primitiveText + ", wrapped";
        var state = copiesAsStringState("NativeCallbackSelfCopyToWrappedString", NSString.alloc().initWithString(text));
        settle(2, function () {
            var before = state.answer.retainCount();
            for (var i = 0; i < 20; i++) {
                expect(state.receiver.copy()).toBe(text);
            }
            settle(2, function () {
                expect(state.answer.retainCount()).toBe(before);
                done();
            });
        });
    });

    // The NSString made for the JS string is never visible to JS, so only the
    // answers are checked.
    it("answers the string a JS copyWithZone returns through a native -copy", function () {
        var state = copiesAsStringState("NativeCallbackSelfCopyToString", primitiveText);
        for (var i = 0; i < 20; i++) {
            expect(state.receiver.copy()).toBe(primitiveText);
        }
    });
});
