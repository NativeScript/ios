// Debug builds in the "rooted" and "canary" modes guard native instance
// methods, and the methods of JS-extended classes that native code calls:
// assigning one's name on a native object throws, since native code never
// calls that own property. The suite is a debug build; the resurrecting
// mode and "allowShadowingNativeMembers" keep plain data properties.
describe("Native member guard", function () {
    var runtime = require("ns:runtime");
    var mode = runtime.getConfig("wrapperLifetimeMode");
    var guarded = (mode === "rooted" || mode === "canary") &&
        !runtime.getConfig("wrapperLifetimeAllowShadowingNativeMembers");

    function replacement() {
        return "js";
    }

    function hasOwn(object, name) {
        return Object.prototype.hasOwnProperty.call(object, name);
    }

    function assignStrict(object, name, value) {
        "use strict";
        object[name] = value;
    }

    function assignSloppy(object, name, value) {
        object[name] = value;
    }

    // Guarded: the assignment throws and leaves no own property. Otherwise it
    // creates the own data property it always did.
    function expectShadowing(object, name, assign) {
        var target = Object(object);
        if (guarded) {
            var error = null;
            try {
                assign(object, name, replacement);
            } catch (e) {
                error = e;
            }
            expect(error instanceof TypeError).toBe(true);
            expect(String(error && error.message)).toContain("allowShadowingNativeMembers");
            expect(String(error && error.message)).toContain('mode "' + mode + '"');
            expect(hasOwn(target, name)).toBe(false);
            expect(object[name]).not.toBe(replacement);
        } else {
            assign(object, name, replacement);
            expect(hasOwn(target, name)).toBe(true);
            expect(object[name]).toBe(replacement);
            delete object[name];
        }
    }

    it("reports the shadowing config read-only", function () {
        expect(typeof runtime.getConfig("wrapperLifetimeAllowShadowingNativeMembers")).toBe("boolean");
        expect(function () {
            runtime.setConfig("wrapperLifetimeAllowShadowingNativeMembers", true);
        }).toThrowError(TypeError, /read-only/);
    });

    it("guards native instance methods against strict and sloppy instance writes", function () {
        var object = NSObject.new();
        var array = NSArray.arrayWithArray([1, 2]);
        expectShadowing(object, "isEqual", assignStrict);
        expectShadowing(object, "isEqual", assignSloppy);
        expectShadowing(array, "objectAtIndex", assignStrict);
        expectShadowing(array, "objectAtIndex", assignSloppy);
        expect(array.objectAtIndex(1)).toBe(2);
    });

    it("guards toString and NSArray's Symbol.iterator", function () {
        var object = NSObject.new();
        var array = NSArray.arrayWithArray([1, 2]);
        expectShadowing(object, "toString", assignStrict);
        expectShadowing(array, "toString", assignSloppy);
        expectShadowing(array, Symbol.iterator, assignStrict);
        expect(Array.from(array)).toEqual([1, 2]);
    });

    it("guards writes through a Proxy around a native object", function () {
        var object = NSObject.new();
        var proxy = new Proxy(object, {});
        if (guarded) {
            expect(function () {
                proxy.isEqual = replacement;
            }).toThrowError(TypeError, /isEqual/);
            expect(hasOwn(object, "isEqual")).toBe(false);
        } else {
            proxy.isEqual = replacement;
            expect(object.isEqual).toBe(replacement);
        }
    });

    it("names the method and the native class in the error", function () {
        if (!guarded) {
            return;
        }
        var view = UIView.new();
        expect(function () {
            view.setNeedsLayout = replacement;
        }).toThrowError(TypeError, /'setNeedsLayout' on an instance of UIView/);
    });

    it("guards JS-extended instances that inherit the native method", function () {
        var Extended = NSObject.extend({}, { name: "TNSNativeMemberGuardExtended" });
        expectShadowing(Extended.new(), "isEqual", assignStrict);
    });

    it("keeps reads of a guarded method unchanged", function () {
        var object = NSObject.new();
        var other = NSObject.new();
        var isEqual = object.isEqual;
        expect(object.isEqual).toBe(object.isEqual);
        expect(object.isEqual).toBe(NSObject.prototype.isEqual);
        expect(typeof isEqual).toBe("function");
        expect("isEqual" in object).toBe(true);
        expect(isEqual.call(object, object)).toBe(true);
        expect(isEqual.call(object, other)).toBe(false);
        expect(isEqual.bind(object)(object)).toBe(true);
        expect(Object.keys(NSObject.prototype)).toContain("isEqual");

        var view = UIView.new();
        UIView.prototype.setNeedsLayout.call(view);
        view.setNeedsLayout();
    });

    it("describes guarded methods as accessor pairs", function () {
        var descriptor = Object.getOwnPropertyDescriptor(UIView.prototype, "setNeedsLayout");
        expect(descriptor.enumerable).toBe(true);
        expect(descriptor.configurable).toBe(true);
        if (guarded) {
            expect(typeof descriptor.get).toBe("function");
            expect(typeof descriptor.set).toBe("function");
            expect(descriptor.value).toBeUndefined();
            expect(descriptor.get()).toBe(UIView.prototype.setNeedsLayout);
        } else {
            expect(typeof descriptor.value).toBe("function");
            expect(descriptor.writable).toBe(true);
        }
        // Not guarded: the constructor and statics.
        expect("value" in Object.getOwnPropertyDescriptor(UIView.prototype, "constructor")).toBe(true);
        expect("value" in Object.getOwnPropertyDescriptor(UIView, "alloc")).toBe(true);
    });

    it("lets Object.defineProperty define a JS-only own property", function () {
        var object = NSObject.new();
        Object.defineProperty(object, "isEqual", { value: replacement, writable: true, configurable: true });
        expect(hasOwn(object, "isEqual")).toBe(true);
        expect(object.isEqual).toBe(replacement);
        // Native code still calls the native implementation.
        expect(NSArray.arrayWithObject(object).containsObject(NSObject.new())).toBe(false);
    });

    it("lets objects inheriting from a native object assign the name", function () {
        var object = NSObject.new();
        var derived = Object.create(object);
        derived.isEqual = replacement;
        expect(hasOwn(derived, "isEqual")).toBe(true);
        expect(derived.isEqual).toBe(replacement);
        expect(object.isEqual).toBe(NSObject.prototype.isEqual);
    });

    it("lets a home object's super read and call the guarded method", function () {
        var array = NSArray.arrayWithArray([7, 8]);
        var home = {
            __proto__: NSArray.prototype,
            nativeObjectAtIndex() {
                return super.objectAtIndex;
            },
            at(index) {
                return super.objectAtIndex(index);
            }
        };
        expect(home.nativeObjectAtIndex()).toBe(NSArray.prototype.objectAtIndex);
        expect(home.at.call(array, 1)).toBe(8);
    });

    it("guards a released native object", function () {
        var object = NSObject.new();
        __releaseNativeCounterpart(object);
        if (guarded) {
            expect(function () {
                object.isEqual = replacement;
            }).toThrowError(TypeError, /'isEqual' on an instance of NSObject/);
            expect(hasOwn(object, "isEqual")).toBe(false);
        } else {
            object.isEqual = replacement;
            expect(object.isEqual).toBe(replacement);
        }
    });

    it("lets a native subclass's prototype override an inherited native method", function () {
        var base = TNSNativeMemberGuard.new();
        var child = TNSNativeMemberGuardChild.new();
        var childValue = function (x) {
            return 50 + x;
        };
        TNSNativeMemberGuardChild.prototype.value = childValue;

        var descriptor = Object.getOwnPropertyDescriptor(TNSNativeMemberGuardChild.prototype, "value");
        expect(descriptor.value).toBe(childValue);
        expect(descriptor.writable).toBe(true);
        expect(descriptor.enumerable).toBe(true);
        expect(descriptor.configurable).toBe(true);
        var baseDescriptor = Object.getOwnPropertyDescriptor(TNSNativeMemberGuard.prototype, "value");
        expect(typeof baseDescriptor.get).toBe(guarded ? "function" : "undefined");

        expect(child.value(1)).toBe(51);
        expect(base.value(1)).toBe(2);
        // The subclass declares no `value:` of its own: nothing is swizzled, in
        // any mode, so native callers keep the inherited implementation.
        expect(TNSNativeMemberGuard.callValueWith(child, 1)).toBe(2);
        expect(TNSNativeMemberGuard.callValueWith(base, 1)).toBe(2);
        expectShadowing(base, "value", assignStrict);
    });

    it("lets ES5 subclasses override a native method on their prototype", function () {
        var calls = 0;
        var Child = (function (_super) {
            __extends(Child, _super);
            function Child() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Child.prototype.value = function (x) {
                calls++;
                return 10 * _super.prototype.value.call(this, x);
            };
            return Child;
        })(TNSNativeMemberGuard);
        var child = Child.new();
        expect(hasOwn(Child.prototype, "value")).toBe(true);
        expect(child.value(1)).toBe(20);
        expect(TNSNativeMemberGuard.callValueWith(child, 2)).toBe(30);
        expect(calls).toBe(2);
        expectShadowing(child, "other", assignStrict);
    });

    it("lets extend() override a native method and native code dispatch to it", function () {
        var Extended = TNSNativeMemberGuard.extend({
            value: function (x) {
                return 100 + TNSNativeMemberGuard.prototype.value.call(this, x);
            }
        }, { name: "TNSNativeMemberGuardOverride" });
        var object = Extended.new();
        expect(object.value(1)).toBe(102);
        expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(102);
        // Native code calls the override the class captured, so it is
        // guarded like the inherited native method.
        expectShadowing(object, "value", assignSloppy);
        expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(102);
        expectShadowing(object, "other", assignSloppy);
    });

    // A JS-extended class's methods that native code calls through the
    // function the class captured (exposed methods, overrides of native
    // methods, protocol implementations) are guarded like native methods. Its
    // other methods stay plain data properties.
    describe("JS-extended classes' methods native code calls", function () {
        var tapped = [];
        var Guarded = TNSNativeMemberGuard.extend({
            value: function (x) {
                return 1000 + TNSNativeMemberGuard.prototype.value.call(this, x);
            },
            tapped: function () {
                tapped.push(this);
            },
            baseProtocolMethod1: function () {
                TNSLog("guarded baseProtocolMethod1");
            },
            helper: function () {
                return "helper";
            }
        }, {
            name: "TNSNativeMemberGuardJSMethods",
            protocols: [TNSBaseProtocol1],
            exposedMethods: { tapped: { returns: interop.types.void, params: [] } }
        });
        var implementation = Object.getPrototypeOf(Guarded.prototype);

        var Subclass = (function (_super) {
            __extends(Subclass, _super);
            function Subclass() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Subclass.prototype.value = function (x) {
                return 10 * _super.prototype.value.call(this, x);
            };
            Subclass.prototype.tapped = function () {
                tapped.push("subclass");
            };
            Subclass.prototype.helper = function () {
                return "subclass helper";
            };
            Subclass.ObjCExposedMethods = { tapped: { returns: interop.types.void, params: [] } };
            return Subclass;
        })(TNSNativeMemberGuard);

        beforeEach(function () {
            tapped.length = 0;
            TNSClearOutput();
        });

        it("guards exposed methods, native overrides and protocol implementations in strict and sloppy code", function () {
            var object = Guarded.new();
            ["value", "tapped", "baseProtocolMethod1"].forEach(function (name) {
                expectShadowing(object, name, assignStrict);
                expectShadowing(object, name, assignSloppy);
            });
            var sub = Subclass.new();
            expectShadowing(sub, "value", assignStrict);
            expectShadowing(sub, "tapped", assignSloppy);
        });

        it("names the method, the class, the mode and the escape hatch", function () {
            if (!guarded) {
                return;
            }
            var object = Guarded.new();
            var error = null;
            try {
                object.tapped = replacement;
            } catch (e) {
                error = e;
            }
            expect(error instanceof TypeError).toBe(true);
            var message = String(error && error.message);
            expect(message).toContain("'tapped' on an instance of TNSNativeMemberGuardJSMethods");
            expect(message).toContain("native code calls the class's implementation");
            expect(message).toContain('mode "' + mode + '"');
            expect(message).toContain("allowShadowingNativeMembers");
        });

        it("leaves JS-only methods writable data properties", function () {
            var object = Guarded.new();
            var descriptor = Object.getOwnPropertyDescriptor(implementation, "helper");
            expect(typeof descriptor.value).toBe("function");
            expect(descriptor.writable).toBe(true);
            object.helper = replacement;
            expect(hasOwn(object, "helper")).toBe(true);
            expect(object.helper()).toBe("js");
            var sub = Subclass.new();
            sub.helper = replacement;
            expect(sub.helper()).toBe("js");
            expect(typeof Object.getOwnPropertyDescriptor(Subclass.prototype, "helper").value).toBe("function");
        });

        it("describes guarded methods as accessor pairs on their prototype", function () {
            Subclass.new();
            [[implementation, "value"], [implementation, "tapped"], [implementation, "baseProtocolMethod1"],
                [Subclass.prototype, "value"], [Subclass.prototype, "tapped"]].forEach(function (entry) {
                var descriptor = Object.getOwnPropertyDescriptor(entry[0], entry[1]);
                expect(descriptor.enumerable).toBe(true);
                expect(descriptor.configurable).toBe(true);
                if (guarded) {
                    expect(typeof descriptor.get).toBe("function");
                    expect(typeof descriptor.set).toBe("function");
                    expect(descriptor.get()).toBe(entry[0][entry[1]]);
                } else {
                    expect(typeof descriptor.value).toBe("function");
                }
            });
            expect("value" in Object.getOwnPropertyDescriptor(Subclass.prototype, "constructor")).toBe(true);
        });

        it("keeps native dispatch to the class's implementations", function () {
            var object = Guarded.new();
            expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(1002);
            object.performSelector("tapped");
            expect(tapped).toEqual([object]);
            TNSTestNativeCallbacks.protocolImplementationMethods(object);
            expect(TNSGetOutput()).toContain("guarded baseProtocolMethod1");
            var sub = Subclass.new();
            expect(TNSNativeMemberGuard.callValueWith(sub, 1)).toBe(20);
            sub.performSelector("tapped");
            expect(tapped).toEqual([object, "subclass"]);
        });

        it("keeps super and _super.prototype calls", function () {
            var sub = Subclass.new();
            expect(sub.value(2)).toBe(30);
            expect(TNSNativeMemberGuard.prototype.value.call(sub, 2)).toBe(3);
            expect(Subclass.prototype.value.call(sub, 2)).toBe(30);
            var home = {
                __proto__: Subclass.prototype,
                value(x) {
                    return super.value(x) + 1;
                }
            };
            expect(home.value.call(sub, 2)).toBe(31);
            var object = Guarded.new();
            expect(implementation.value.call(object, 1)).toBe(1002);
        });

        it("lets objects inheriting from an instance assign the name", function () {
            var object = Guarded.new();
            var derived = Object.create(object);
            derived.tapped = replacement;
            expect(hasOwn(derived, "tapped")).toBe(true);
            expect(derived.tapped).toBe(replacement);
            expect(hasOwn(object, "tapped")).toBe(false);
            expect(object.tapped).toBe(implementation.tapped);
        });

        // Runs last in this block: the replacement stays installed.
        it("lets the prototype replace a guarded method, which native code then keeps calling the captured one of", function () {
            var Late = (function (_super) {
                __extends(Late, _super);
                function Late() {
                    return (_super !== null && _super.apply(this, arguments)) || this;
                }
                Late.prototype.value = function (x) {
                    return 7 * x;
                };
                return Late;
            })(TNSNativeMemberGuard);
            var object = Late.new();
            var later = function (x) {
                return 9 * x;
            };
            Late.prototype.value = later;
            var descriptor = Object.getOwnPropertyDescriptor(Late.prototype, "value");
            expect(descriptor.value).toBe(later);
            expect(descriptor.writable).toBe(true);
            expect(object.value(1)).toBe(9);
            expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(7);
            // A data property from then on: instance writes are no longer guarded.
            object.value = replacement;
            expect(hasOwn(object, "value")).toBe(true);
        });
    });

    it("swizzles a prototype assignment made from a Proxy trap a guarded write runs", function () {
        var object = TNSNativeMemberGuard.new();
        var prototype = TNSNativeMemberGuard.prototype;
        var original = prototype.nested;
        var descriptor = Object.getOwnPropertyDescriptor(prototype, "nested");
        var replaced = function (x) {
            return 10 * original.call(this, x);
        };
        var target = Object.create(prototype);
        var proxy = new Proxy(target, {
            defineProperty: function (definedOn, key, definition) {
                if (key === "value") {
                    prototype.nested = replaced;
                }
                return Reflect.defineProperty(definedOn, key, definition);
            }
        });
        try {
            proxy.value = replacement;
            expect(hasOwn(target, "value")).toBe(true);
            expect(object.nested(1)).toBe(40);
            expect(TNSNativeMemberGuard.callNestedWith(object, 1)).toBe(40);
        } finally {
            prototype.nested = original;
            Object.defineProperty(prototype, "nested", descriptor);
        }
        expect(TNSNativeMemberGuard.callNestedWith(object, 1)).toBe(4);
        expect(Object.getOwnPropertyDescriptor(prototype, "nested")).toEqual(descriptor);
    });

    // Runs last among the specs that use TNSNativeMemberGuard: the replacement
    // stays installed.
    it("swizzles a guarded method assigned on its class's prototype", function () {
        var object = TNSNativeMemberGuard.new();
        var original = TNSNativeMemberGuard.prototype.other;
        var calls = 0;
        var swizzled = function (x) {
            calls++;
            return 3 * original.call(this, x);
        };
        TNSNativeMemberGuard.prototype.other = swizzled;

        var descriptor = Object.getOwnPropertyDescriptor(TNSNativeMemberGuard.prototype, "other");
        expect(descriptor.value).toBe(swizzled);
        expect(descriptor.writable).toBe(true);
        expect(descriptor.enumerable).toBe(true);
        expect(descriptor.configurable).toBe(true);
        expect(object.other(1)).toBe(9);
        expect(TNSNativeMemberGuard.callOtherWith(object, 2)).toBe(12);
        expect(calls).toBe(2);

        // The rest of the class stays guarded.
        expectShadowing(object, "value", assignStrict);
        expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(2);
    });
});
