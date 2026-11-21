// Debug builds in the "rooted" and "canary" modes guard native instance
// methods: assigning one's name on a native object throws, since native code
// never calls that own property. The suite is a debug build; the resurrecting
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
        // The override is a JS method, not guarded; the inherited native one is.
        object.value = replacement;
        expect(object.value).toBe(replacement);
        expect(TNSNativeMemberGuard.callValueWith(object, 1)).toBe(102);
        delete object.value;
        expectShadowing(object, "other", assignSloppy);
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
