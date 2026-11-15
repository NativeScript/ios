const { raisesGlobalErrors } = require("../Infrastructure/Jasmine/globalErrorSpy");

// JS accessors of native properties run with `this` bound to the instance
// native code called them on, whether or not JS had a wrapper for it yet.
describe("JS accessor receivers", function () {
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

    function hasOwn(object, key) {
        return Object.prototype.hasOwnProperty.call(object, key);
    }

    // `record.lastThis` is the receiver of the latest accessor call;
    // `record.onGet` runs inside the getter; `record.throws` makes both
    // accessors throw an Error with that message.
    function accessors(record) {
        return {
            get: function () {
                record.lastThis = this;
                if (record.onGet) {
                    record.onGet(this);
                }
                if (record.throws) {
                    throw new Error(record.throws);
                }
                return this._stored !== undefined ? this._stored : "name:" + this.name;
            },
            set: function (value) {
                record.lastThis = this;
                if (record.throws) {
                    throw new Error(record.throws);
                }
                this._stored = value;
            }
        };
    }

    function defineWithExtend(name, Base) {
        var record = {};
        var body = {};
        Object.defineProperty(body, "value", Object.assign({ enumerable: true, configurable: true }, accessors(record)));
        var Klass = Base.extend(body, { name: name });
        return { Klass: Klass, record: record, implementation: Object.getPrototypeOf(Klass.prototype) };
    }

    function defineWithTypeScript(Base) {
        var record = {};
        var Klass = (function (_super) {
            __extends(JSAccessorReceiverTSHost, _super);
            function JSAccessorReceiverTSHost() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            // Only enumerable accessors are exposed to native code.
            Object.defineProperty(JSAccessorReceiverTSHost.prototype, "value", Object.assign({ enumerable: true, configurable: true }, accessors(record)));
            return JSAccessorReceiverTSHost;
        })(Base);
        return { Klass: Klass, record: record, implementation: Klass.prototype };
    }

    // Neither the implementation object nor the prototype between it and the
    // instances ever holds per-instance state.
    function expectNoSharedState(def) {
        expect(hasOwn(def.implementation, "_stored")).toBe(false);
        expect(hasOwn(def.Klass.prototype, "_stored")).toBe(false);
        expect(hasOwn(Object.getPrototypeOf(def.Klass.prototype), "_stored")).toBe(false);
    }

    beforeEach(function (done) {
        settle(2, function () {
            TNSClearOutput();
            done();
        });
    });

    var variants = [
        {
            suffix: " (extend)",
            define: function (tag, Base) {
                return defineWithExtend("JSAccessorReceiver" + tag, Base || TNSAccessorHost);
            }
        },
        {
            suffix: " (__extends)",
            define: function (tag, Base) {
                return defineWithTypeScript(Base || TNSAccessorHost);
            }
        }
    ];

    variants.forEach(function (variant) {
        it("runs a getter read natively on a never-wrapped instance on that instance" + variant.suffix, function () {
            var def = variant.define("Read");
            var cls = def.Klass.class();
            expect(TNSAccessorDriver.valueOfNewHostOfName(cls, "first")).toBe("name:first");
            expect(TNSAccessorDriver.valueOfNewHostOfName(cls, "second")).toBe("name:second");
            expect(def.record.lastThis).not.toBe(def.implementation);
            expectNoSharedState(def);
            def.record.lastThis = null;
        });

        it("stores what a setter called natively on a never-wrapped instance writes on that instance" + variant.suffix, function () {
            var def = variant.define("Write");
            var cls = def.Klass.class();
            var first = TNSAccessorDriver.alloc().initWithNewHostOfName(cls, "first");
            var second = TNSAccessorDriver.alloc().initWithNewHostOfName(cls, "second");
            first.writeValue("written-first");
            expect(first.readValue()).toBe("written-first");
            expect(second.readValue()).toBe("name:second");
            second.writeValue("written-second");
            expect(first.readValue()).toBe("written-first");
            expect(second.readValue()).toBe("written-second");
            expectNoSharedState(def);

            var host = first.host();
            expect(host._stored).toBe("written-first");
            expect(host.value).toBe("written-first");
            expect(host.name).toBe("first");
            def.record.lastThis = null;
        });

        it("binds this in a native accessor call to the object JS later gets for that instance" + variant.suffix, function () {
            var def = variant.define("Identity");
            var driver = TNSAccessorDriver.alloc().initWithNewHostOfName(def.Klass.class(), "identity");
            def.record.onGet = function (self) {
                self.seenInGetter = true;
            };
            expect(driver.readValue()).toBe("name:identity");
            var receiver = def.record.lastThis;
            var host = driver.host();
            expect(receiver).toBe(host);
            expect(host instanceof def.Klass).toBe(true);
            expect(host.seenInGetter).toBe(true);
            expect(hasOwn(def.implementation, "seenInGetter")).toBe(false);
            def.record.lastThis = null;
        });

        it("keeps an instance an accessor call wrapped first while native code holds it, then frees it once" + variant.suffix, function (done) {
            var def = variant.define("Lifetime");
            var driver = TNSAccessorDriver.alloc().initWithNewHostOfName(def.Klass.class(), "kept");
            driver.writeValue("kept-value");
            def.record.lastThis = null;
            settle(3, function () {
                expect(deallocs()).toBe(0);
                expect(driver.readValue()).toBe("kept-value");
                def.record.lastThis = null;
                (function () {
                    var host = driver.host();
                    expect(host._stored).toBe("kept-value");
                })();
                driver.dropHost();
                settle(3, function () {
                    expect(deallocs()).toBe(1);
                    expectNoSharedState(def);
                    done();
                });
            });
        });

        it("frees once an instance whose only accessor call happened inside a native method" + variant.suffix, function (done) {
            var def = variant.define("Transient");
            expect(TNSAccessorDriver.valueOfNewHostOfName(def.Klass.class(), "transient")).toBe("name:transient");
            def.record.lastThis = null;
            settle(3, function () {
                expect(deallocs()).toBe(1);
                done();
            });
        });

        it("runs accessors of an instance JS already holds on its existing wrapper" + variant.suffix, function () {
            var def = variant.define("Existing");
            var host = def.Klass.alloc().init();
            host.name = "existing";
            var driver = TNSAccessorDriver.alloc().initWithHost(host);
            expect(driver.readValue()).toBe("name:existing");
            expect(def.record.lastThis).toBe(host);
            driver.writeValue("existing-value");
            expect(def.record.lastThis).toBe(host);
            expect(host._stored).toBe("existing-value");
            expect(driver.readValue()).toBe("existing-value");
            expectNoSharedState(def);
            def.record.lastThis = null;
        });

        it("reports a receiver kept from a getter run by -dealloc as released" + variant.suffix, function (done) {
            var def = variant.define("Dealloc", TNSAccessorDeallocHost);
            var nameInDealloc;
            def.record.onGet = function (self) {
                nameInDealloc = self.name;
            };
            TNSAccessorDriver.dropNewHostOfName(def.Klass.class(), "dying");
            var saved = def.record.lastThis;
            def.record.lastThis = null;
            expect(saved).toBeDefined();
            expect(saved).not.toBe(def.implementation);
            expect(nameInDealloc).toBe("dying");
            expect(deallocs()).toBe(1);
            settle(3, function () {
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
                expect(deallocs()).toBe(1);
                done();
            });
        });
    });

    describe("that throw", function () {
        var previousHook;
        var uncaught;

        beforeEach(function () {
            previousHook = global.__onUncaughtError;
            uncaught = [];
            global.__onUncaughtError = function (error) {
                uncaught.push(error);
            };
        });

        afterEach(function () {
            global.__onUncaughtError = previousHook;
        });

        function uncaughtCount(message) {
            return uncaught.filter(function (e) {
                return e && String(e.message !== undefined ? e.message : e).indexOf(message) > -1;
            }).length;
        }

        function pollUntil(predicate, callback) {
            var turns = 0;
            (function poll() {
                if (predicate() || turns >= 25) {
                    callback();
                    return;
                }
                turns++;
                setTimeout(poll, 10);
            })();
        }

        variants.forEach(function (variant) {
            it("report the error, answer nil and leave the instance to be freed once" + variant.suffix, raisesGlobalErrors(function (done) {
                var def = variant.define("Throws");
                var driver = TNSAccessorDriver.alloc().initWithNewHostOfName(def.Klass.class(), "throws");
                def.record.throws = "accessor-receiver-boom";
                expect(driver.readValue()).toBeNull();
                driver.writeValue("ignored");
                var receiver = def.record.lastThis;
                def.record.lastThis = null;
                def.record.throws = null;
                expect(receiver).toBe(driver.host());
                receiver = null;
                expect(driver.readValue()).toBe("name:throws");
                def.record.lastThis = null;
                expectNoSharedState(def);
                pollUntil(function () { return uncaughtCount("accessor-receiver-boom") >= 2; }, function () {
                    expect(uncaughtCount("accessor-receiver-boom")).toBe(2);
                    driver.dropHost();
                    settle(3, function () {
                        expect(deallocs()).toBe(1);
                        done();
                    });
                });
            }));

            it("report the error of a getter run by -dealloc and detach its receiver" + variant.suffix, raisesGlobalErrors(function (done) {
                var def = variant.define("ThrowsInDealloc", TNSAccessorDeallocHost);
                def.record.throws = "accessor-receiver-dealloc-boom";
                TNSAccessorDriver.dropNewHostOfName(def.Klass.class(), "dying");
                var saved = def.record.lastThis;
                def.record.lastThis = null;
                expect(saved).not.toBe(def.implementation);
                expect(deallocs()).toBe(1);
                pollUntil(function () { return uncaughtCount("accessor-receiver-dealloc-boom") >= 1; }, function () {
                    expect(uncaughtCount("accessor-receiver-dealloc-boom")).toBe(1);
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
            }));
        });
    });
});
