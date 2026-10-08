// Stubs come from TestRunner/AOT/aot-config.json. Members asserted as generic
// here must stay out of that config.
describe(module.id, function () {
    function stats() {
        return __native_call_profiler.aotStats();
    }

    function measure(fn) {
        var before = stats();
        var value, error;
        try {
            value = fn();
        } catch (e) {
            error = e;
        }
        var after = stats();
        return {
            value: value,
            error: error,
            served: after.served - before.served,
            declined: after.declined - before.declined
        };
    }

    // The counters only move while the profiler runs.
    beforeEach(function () {
        __native_call_profiler.start();
    });

    afterEach(function () {
        __native_call_profiler.stop();
        TNSClearOutput();
    });

    describe("aotStats", function () {
        it("returns served and declined counters", function () {
            var r = measure(function () { return TNSPrimitives.methodWithDouble(1); });
            expect(r.served).toBe(1);
            var s = stats();
            expect(Object.keys(s).sort()).toEqual(["declined", "served"]);
            expect(Number.isInteger(s.served)).toBe(true);
            expect(Number.isInteger(s.declined)).toBe(true);
            expect(s.served).toBeGreaterThan(0);
        });

        it("does not count itself", function () {
            var r = measure(function () { return stats(); });
            expect(r.served).toBe(0);
            expect(r.declined).toBe(0);
        });
    });

    describe("members", function () {
        it("instance method", function () {
            var instance = TNSBaseInterface.alloc().init();
            var r = measure(function () { instance.callBaseMethod(false); });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("instance baseMethod called");
        });

        it("inherited method on a derived instance", function () {
            var instance = TNSDerivedInterface.alloc().init();
            var r = measure(function () { instance.callBaseMethod(true); });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("derived overloaded instance baseMethod: called");
        });

        it("NSObject members on a fixture instance", function () {
            var instance = TNSPrimitives.alloc().init();
            var r = measure(function () {
                return [
                    instance.description,
                    instance.isKindOfClass(NSObject),
                    instance.isKindOfClass(NSString),
                    instance.respondsToSelector("methodWithInt:"),
                    instance.respondsToSelector("noSuchSelector")
                ];
            });
            expect(r.served).toBe(5);
            expect(r.value[0]).toMatch(/^<TNSPrimitives: 0x[0-9a-f]+>$/);
            expect(r.value.slice(1)).toEqual([true, false, true, false]);
        });

        it("ancestor stub binds where a protocol re-registers the member", function () {
            var screen = UIScreen.mainScreen;
            var r = measure(function () { return screen.respondsToSelector("scale"); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(true);
        });

        it("NSObject member on a derived fixture instance", function () {
            var instance = TNSDerivedInterface.alloc().init();
            var r = measure(function () { return instance.description; });
            expect(r.served).toBe(1);
            expect(r.value).toMatch(/^<TNSDerivedInterface: 0x[0-9a-f]+>$/);
        });

        it("static method", function () {
            var r = measure(function () { return TNSPrimitives.methodWithDouble(1.7976931348623157e+308); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(1.7976931348623157e+308);
        });

        it("instance property getter", function () {
            var instance = TNSBaseInterface.alloc().init();
            var r = measure(function () {
                instance.baseProperty = 1;
                return instance.baseProperty;
            });
            expect(r.served).toBe(1);
            expect(r.value).toBe(0);
            expect(TNSGetOutput()).toBe("instance setBaseProperty: calledinstance baseProperty called");
        });

        it("custom-named property getter", function () {
            var object = new TNSApi();
            object.property = 3;
            var r = measure(function () { return object.property; });
            expect(r.served).toBe(1);
            expect(r.value).toBe(3);
        });

        it("static property getter", function () {
            var r = measure(function () { return TNSBaseInterface.baseProperty; });
            expect(r.served).toBe(1);
            expect(r.value).toBe(0);
            expect(TNSGetOutput()).toBe("static baseProperty called");
        });

        it("static property getter through a derived constructor", function () {
            var r = measure(function () { return TNSDerivedInterface.baseProperty; });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("static baseProperty called");
        });

        it("UIScreen class property and instance getters", function () {
            var r = measure(function () {
                var screen = UIScreen.mainScreen;
                return { screen: screen, scale: screen.scale, nativeScale: screen.nativeScale, bounds: screen.bounds };
            });
            expect(r.served).toBe(4);
            expect(r.value.screen instanceof UIScreen).toBe(true);
            expect(r.value.scale).toBeGreaterThan(0);
            expect(r.value.nativeScale).toBeGreaterThan(0);
            expect(r.value.bounds.size.width).toBeGreaterThan(0);
            expect(r.value.bounds.size.height).toBeGreaterThan(0);
        });
    });

    describe("structs", function () {
        it("argument and return round trip from a literal", function () {
            var r = measure(function () { return TNSTestNativeCallbacks.recordsSimpleStruct({ x: 7, y: 8 }); });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("7 8");
            expect(r.value.x).toBe(7);
            expect(r.value.y).toBe(8);
        });

        it("argument from a struct wrapper", function () {
            var record = new TNSSimpleStruct();
            record.x = 7;
            record.y = 8;
            var r = measure(function () { return TNSTestNativeCallbacks.recordsSimpleStruct(record); });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("7 8");
            expect(r.value.x).toBe(7);
            expect(r.value.y).toBe(8);
        });

        it("nested struct round trip", function () {
            var record = new TNSNestedStruct({ a: { x: 1, y: 2 }, b: { x: 3, y: 4 } });
            var r = measure(function () { return TNSTestNativeCallbacks.recordsNestedStruct(record); });
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("1 2 3 4");
            expect(r.value.b.y).toBe(4);
        });

        it("struct return from a protocol method", function () {
            var object = RectClass.new();
            var r = measure(function () { return object.getRect(); });
            expect(r.served).toBe(1);
            expect(r.value.origin.x).toBe(1);
            expect(r.value.origin.y).toBe(2);
            expect(r.value.size.width).toBe(3);
            expect(r.value.size.height).toBe(4);
        });
    });

    describe("arguments", function () {
        var primitives;
        beforeEach(function () {
            primitives = TNSPrimitives.alloc().init();
        });

        it("object", function () {
            var r = measure(function () { return primitives.methodWithNSNumber(0); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(0);
            expect(TNSGetOutput()).toBe("0");
        });

        it("object returned as the same wrapper", function () {
            var object = NSObject.new();
            var r = measure(function () { return TNSPrimitives.methodWithId(object); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(object);
        });

        it("NSDate", function () {
            var objcTypes = TNSObjCTypes.alloc().init();
            var r = measure(function () { return objcTypes.methodWithNSDate(new Date(1e12)); });
            expect(r.served).toBe(1);
            expect(r.value).toEqual(new Date(1e12));
        });

        it("SEL", function () {
            var r = measure(function () { return primitives.methodWithSelector("init"); });
            expect(r.served).toBe(1);
            expect(r.value).toBe("init");
            expect(TNSGetOutput()).toBe("init");
        });

        it("Class", function () {
            var r = measure(function () { return primitives.methodWithClass(NSObject); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(NSObject);
            expect(TNSGetOutput()).toBe("NSObject");
        });

        it("integers", function () {
            var r = measure(function () {
                return [primitives.methodWithChar(-128), primitives.methodWithUChar(255),
                        primitives.methodWithInt(-2147483648)];
            });
            expect(r.served).toBe(3);
            expect(r.value).toEqual([-128, 255, -2147483648]);
            expect(TNSGetOutput()).toBe("-128255-2147483648");
        });

        it("float", function () {
            var r = measure(function () { return primitives.methodWithFloat(3.40282347e+38); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(3.4028234663852886e+38);
        });

        it("booleans", function () {
            var r = measure(function () {
                return [primitives.methodWithBool2(true), primitives.methodWithBool3(false)];
            });
            expect(r.served).toBe(2);
            expect(r.value).toEqual([true, false]);
            expect(TNSGetOutput()).toBe("10");
        });
    });

    describe("exceptions", function () {
        it("NSException matches the generic path", function () {
            var api = TNSApi.alloc().init();
            var stubbed = measure(function () { api.methodThrowsException(); });
            var generic = measure(function () { TNSApi.methodThrowsException(); });

            expect(stubbed.served).toBe(1);
            expect(generic.served + generic.declined).toBe(0);

            expect(stubbed.error instanceof Error).toBe(true);
            expect(generic.error instanceof Error).toBe(true);
            expect(stubbed.error.name).toBe("NSGenericException");
            expect(stubbed.error.message).toBe("No reason");
            expect(stubbed.error.name).toBe(generic.error.name);
            expect(stubbed.error.message).toBe(generic.error.message);
            expect(Object.keys(stubbed.error).sort()).toEqual(Object.keys(generic.error).sort());

            var nativeException = stubbed.error.nativeException;
            expect(nativeException instanceof NSException).toBe(true);
            expect(nativeException.name).toBe("NSGenericException");
            expect(nativeException.reason).toBe("No reason");
        });
    });

    describe("JS-extended classes", function () {
        it("override calling super reaches the native method once", function () {
            var overrideCalls = 0;
            var JSBase = TNSBaseInterface.extend({
                callBaseMethod: function (withArgs) {
                    overrideCalls++;
                    return TNSBaseInterface.prototype.callBaseMethod.call(this, withArgs);
                }
            });
            var instance = JSBase.alloc().init();
            var r = measure(function () { instance.callBaseMethod(false); });
            expect(r.error).toBeUndefined();
            expect(overrideCalls).toBe(1);
            expect(r.served).toBe(1);
            expect(TNSGetOutput()).toBe("instance baseMethod called");
        });

        it("getter override calling the base getter", function () {
            var JSApi = TNSApi.extend({
                get property() {
                    return -Object.getOwnPropertyDescriptor(TNSApi.prototype, "property").get.call(this);
                },
                set property(x) {
                    Object.getOwnPropertyDescriptor(TNSApi.prototype, "property").set.call(this, x * 2);
                }
            });
            var object = new JSApi();
            object.property = 3;
            var r = measure(function () { return object.property; });
            expect(r.served).toBe(1);
            expect(r.value).toBe(-6);
        });

        it("non-overridden method on an extended instance", function () {
            var instance = TNSPrimitives.extend({}).alloc().init();
            var r = measure(function () { return instance.methodWithInt(5); });
            expect(r.served).toBe(1);
            expect(r.value).toBe(5);
        });
    });

    describe("declines", function () {
        it("missing argument throws the generic error", function () {
            var primitives = TNSPrimitives.alloc().init();
            var stubbed = measure(function () { return primitives.methodWithInt(); });
            var generic = measure(function () { return primitives.methodWithShort(); });
            expect(stubbed.declined).toBe(1);
            expect(stubbed.served).toBe(0);
            expect(generic.served + generic.declined).toBe(0);
            expect(stubbed.error).toBeDefined();
            expect(String(stubbed.error)).toBe(String(generic.error));
        });

        it("extra argument throws the generic error", function () {
            var primitives = TNSPrimitives.alloc().init();
            var stubbed = measure(function () { return primitives.methodWithInt(1, 2); });
            var generic = measure(function () { return primitives.methodWithShort(1, 2); });
            expect(stubbed.declined).toBe(1);
            expect(stubbed.error).toBeDefined();
            expect(String(stubbed.error)).toBe(String(generic.error));
        });

        it("overload with another argument count resolves on the generic path", function () {
            var instance = TNSDerivedInterface.alloc().init();
            var oneArg = measure(function () { instance.methodWithParam(1); });
            expect(oneArg.declined).toBe(1);
            expect(oneArg.served).toBe(0);
            expect(TNSGetOutput()).toBe("instance methodWithParam: called with 1 param");

            TNSClearOutput();
            var twoArgs = measure(function () { instance.methodWithParam(1, 2); });
            expect(twoArgs.served).toBe(1);
            expect(TNSGetOutput()).toBe("instance methodWith:param: called with 2 params");
        });

        it("getter with a non-native receiver returns undefined", function () {
            var stubbedGet = Object.getOwnPropertyDescriptor(TNSApi.prototype, "property").get;
            var genericGet = Object.getOwnPropertyDescriptor(TNSBaseInterface.prototype, "baseReadOnlyProperty").get;
            [{}, 5].forEach(function (receiver) {
                var stubbed = measure(function () { return stubbedGet.call(receiver); });
                var generic = measure(function () { return genericGet.call(receiver); });
                expect(stubbed.declined).toBe(1);
                expect(stubbed.error).toBeUndefined();
                expect(stubbed.value).toBeUndefined();
                expect(generic.error).toBeUndefined();
                expect(generic.value).toBeUndefined();
            });
        });

        it("static method with a non-class receiver", function () {
            var method = TNSPrimitives.methodWithDouble;
            var r = measure(function () { return method.call({}, 1.5); });
            expect(r.declined).toBe(1);
            expect(r.served).toBe(0);
            expect(r.error).toBeUndefined();
            expect(r.value).toBe(1.5);
        });
    });
});
