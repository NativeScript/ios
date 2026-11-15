// Native code that introspects a method (KVC, NSMethodSignature) must see a
// JS-implemented property accessor with the property's own type.
describe("JS-implemented native property accessors", function () {
    var rect = { origin: { x: 1, y: 2 }, size: { width: 3, height: 4 } };
    var point = { x: 5, y: 6 };

    // Every TNSAccessorTypes property, with the value its JS getter answers.
    var answers = {
        boolProperty: true,
        unsignedProperty: 4000000000,
        integerProperty: -3,
        shortProperty: -2,
        unicharProperty: 65,
        charProperty: 7,
        unsignedCharProperty: 200,
        longLongProperty: -5,
        floatProperty: 1.5,
        doubleProperty: 2.5,
        rectProperty: rect,
        pointProperty: point,
        selectorProperty: "description",
        classProperty: NSObject,
        blockProperty: function () {},
        pointerProperty: null,
        functionPointerProperty: null,
        vectorProperty: [1, 2, 3, 4],
        objectProperty: "text",
        protocolObjectProperty: null
    };

    function typeString(cString) {
        return NSString.stringWithUTF8String(cString).toString();
    }

    function setterName(property) {
        return "set" + property[0].toUpperCase() + property.slice(1) + ":";
    }

    function accessorDescriptors(state) {
        var descriptors = {
            hash: {
                get: function () {
                    return 7;
                },
                configurable: true,
                enumerable: true
            }
        };
        Object.keys(answers).forEach(function (property) {
            descriptors[property] = {
                get: function () {
                    return answers[property];
                },
                set: function (value) {
                    state.received[property] = value;
                },
                configurable: true,
                enumerable: true
            };
        });
        return descriptors;
    }

    function makeExtended(name, state) {
        return TNSAccessorTypes.extend(Object.defineProperties({}, accessorDescriptors(state)), { name: name });
    }

    function makeTypeScript(name, state) {
        var Klass = (function (_super) {
            __extends(Klass, _super);
            function Klass() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            Object.defineProperties(Klass.prototype, accessorDescriptors(state));
            return Klass;
        })(TNSAccessorTypes);
        return Klass;
    }

    function expectRect(value, expected) {
        expect([value.origin.x, value.origin.y, value.size.width, value.size.height])
            .toEqual([expected.origin.x, expected.origin.y, expected.size.width, expected.size.height]);
    }

    [
        { title: ".extend()", make: makeExtended, name: "JSAccessorEncodingExtended" },
        { title: "__extends", make: makeTypeScript, name: "JSAccessorEncodingTypeScript" }
    ].forEach(function (variant) {
        describe("of a class made with " + variant.title, function () {
            var state = { received: {} };
            var Klass = variant.make(variant.name, state);

            beforeEach(function () {
                state.received = {};
            });

            it("answer valueForKey: with an NSUInteger", function () {
                var obj = Klass.new();
                expect(obj.valueForKey("hash")).toBe(7);
                expect(obj.valueForKey("unsignedProperty")).toBe(4000000000);
            });

            it("answer -[NSArray valueForKey:] with an NSUInteger", function () {
                var values = NSArray.arrayWithArray([Klass.new(), Klass.new()]).valueForKey("hash");
                expect(values.count).toBe(2);
                expect(values.objectAtIndex(0)).toBe(7);
                expect(values.objectAtIndex(1)).toBe(7);
            });

            it("answer valueForKey: with a BOOL", function () {
                expect(Klass.new().valueForKey("boolProperty")).toBe(true);
            });

            it("answer valueForKey: with a double", function () {
                expect(Klass.new().valueForKey("doubleProperty")).toBe(2.5);
            });

            it("answer valueForKey: with a struct", function () {
                var obj = Klass.new();
                expectRect(obj.valueForKey("rectProperty").CGRectValue, rect);
                var boxedPoint = obj.valueForKey("pointProperty").CGPointValue;
                expect([boxedPoint.x, boxedPoint.y]).toEqual([point.x, point.y]);
            });

            it("answer valueForKey: with an object", function () {
                expect(Klass.new().valueForKey("objectProperty")).toBe("text");
            });

            it("receive a number from setValue:forKey:", function () {
                var obj = Klass.new();
                obj.setValueForKey(4000000001, "unsignedProperty");
                expect(state.received.unsignedProperty).toBe(4000000001);
                obj.setValueForKey(-1.25, "doubleProperty");
                expect(state.received.doubleProperty).toBe(-1.25);
            });

            it("receive a BOOL from setValue:forKey:", function () {
                var obj = Klass.new();
                obj.setValueForKey(true, "boolProperty");
                expect(state.received.boolProperty).toBe(true);
                obj.setValueForKey(false, "boolProperty");
                expect(state.received.boolProperty).toBe(false);
            });

            it("receive a struct from setValue:forKey:", function () {
                var obj = Klass.new();
                var other = { origin: { x: 10, y: 20 }, size: { width: 30, height: 40 } };
                obj.setValueForKey(NSValue.valueWithCGRect(other), "rectProperty");
                expectRect(state.received.rectProperty, other);
            });

            it("receive an object from setValue:forKey:", function () {
                Klass.new().setValueForKey("other text", "objectProperty");
                expect(state.received.objectProperty).toBe("other text");
            });

            // The compiler's encoding of a vector type is not one the runtime
            // can reproduce, so vectorProperty is left out.
            it("report the property's own types in their method signatures", function () {
                var obj = Klass.new();
                var selectors = ["hash"];
                Object.keys(answers).forEach(function (property) {
                    if (property !== "vectorProperty") {
                        selectors.push(property, setterName(property));
                    }
                });
                selectors.forEach(function (selector) {
                    var expected = TNSAccessorTypes.instanceMethodSignatureForSelector(selector);
                    var registered = method_getTypeEncoding(class_getInstanceMethod(Klass.class(), selector));
                    var signatures = [
                        Klass.instanceMethodSignatureForSelector(selector),
                        obj.methodSignatureForSelector(selector),
                        NSMethodSignature.signatureWithObjCTypes(registered)
                    ];
                    signatures.forEach(function (signature) {
                        expect([selector, typeString(signature.methodReturnType)]).toEqual([selector, typeString(expected.methodReturnType)]);
                        expect([selector, signature.numberOfArguments]).toEqual([selector, expected.numberOfArguments]);
                        for (var i = 2; i < expected.numberOfArguments; i++) {
                            expect([selector, typeString(signature.getArgumentTypeAtIndex(i))])
                                .toEqual([selector, typeString(expected.getArgumentTypeAtIndex(i))]);
                        }
                    });
                });
            });
        });
    });

    // The replacement is installed for the rest of the run, on a class no other
    // spec uses.
    describe("replaced on a native class's prototype", function () {
        var installed = false;

        function install() {
            if (installed) {
                return;
            }
            installed = true;
            Object.defineProperty(TNSAccessorSwizzleDerived.prototype, "doubleProperty", {
                get: function () {
                    return 3.5;
                },
                configurable: true
            });
            Object.defineProperty(TNSAccessorSwizzleDerived.prototype, "boolProperty", {
                get: function () {
                    return true;
                },
                configurable: true
            });
        }

        it("answer valueForKey: with the property's own type when the class inherits the accessor", function () {
            install();
            var obj = TNSAccessorSwizzleDerived.new();
            expect(obj.valueForKey("doubleProperty")).toBe(3.5);
            expect(obj.valueForKey("boolProperty")).toBe(true);
        });

        it("report the property's own type in the method signature when the class inherits the accessor", function () {
            install();
            ["doubleProperty", "boolProperty"].forEach(function (selector) {
                var expected = TNSAccessorSwizzleBase.instanceMethodSignatureForSelector(selector).methodReturnType;
                var signature = TNSAccessorSwizzleDerived.instanceMethodSignatureForSelector(selector);
                expect([selector, typeString(signature.methodReturnType)]).toEqual([selector, typeString(expected)]);
            });
        });
    });

    // TNSDerivedInterface declares baseProperty through its base class and
    // through a protocol, so two property metadata entries name each accessor.
    it("run once per native call when the class and a protocol declare the property", function () {
        var counts = { get: 0, set: 0, value: 0 };
        var Klass = TNSDerivedInterface.extend({
            get baseProperty() {
                counts.get++;
                return 41;
            },
            set baseProperty(value) {
                counts.set++;
                counts.value = value;
            }
        }, { name: "JSAccessorEncodingSharedSelector" });
        var obj = Klass.new();
        expect(obj.valueForKey("baseProperty")).toBe(41);
        obj.setValueForKey(7, "baseProperty");
        expect([counts.get, counts.set, counts.value]).toEqual([1, 1, 7]);
        expect(typeString(Klass.instanceMethodSignatureForSelector("baseProperty").methodReturnType)).toBe("i");
    });

    // TNSInheritedSwizzleDerived lists members only its superclass implements.
    // The replacements stay installed for the rest of the run, on classes no
    // other spec uses.
    // The prototype of a class whose redeclaration keeps the accessor count of
    // its superclass's property does not define it again.
    function inheritedDescriptor(proto, name) {
        for (var current = proto; current !== null; current = Object.getPrototypeOf(current)) {
            var descriptor = Object.getOwnPropertyDescriptor(current, name);
            if (descriptor !== undefined) {
                return descriptor;
            }
        }
        return undefined;
    }

    describe("replaced on a native class that inherits them", function () {
        var installed = false;

        function install() {
            if (installed) {
                return;
            }
            installed = true;
            var proto = TNSInheritedSwizzleDerived.prototype;
            var objectOriginal = inheritedDescriptor(proto, "objectValue");
            Object.defineProperty(proto, "objectValue", {
                get: function () {
                    var value = objectOriginal.get.call(this);
                    return value === null ? null : "js " + value;
                },
                set: function (value) {
                    objectOriginal.set.call(this, value + "!");
                },
                configurable: true
            });
            var scalarOriginal = inheritedDescriptor(proto, "scalarValue");
            Object.defineProperty(proto, "scalarValue", {
                get: function () {
                    return scalarOriginal.get.call(this) * 2;
                },
                set: function (value) {
                    scalarOriginal.set.call(this, value + 1);
                },
                configurable: true
            });
            var describeOriginal = proto.describeValue;
            proto.describeValue = function (value) {
                return "js " + describeOriginal.call(this, value);
            };
        }

        it("reach the inherited implementation of a method from JS", function () {
            install();
            expect(TNSInheritedSwizzleDerived.new().describeValue(3)).toBe("js base 3");
            expect(TNSInheritedSwizzleSubclass.new().describeValue(4)).toBe("js base 4");
            expect(TNSInheritedSwizzleBase.new().describeValue(5)).toBe("base 5");
        });

        it("reach the inherited accessors of an object property from JS", function () {
            install();
            [TNSInheritedSwizzleDerived, TNSInheritedSwizzleSubclass].forEach(function (Klass) {
                var obj = Klass.new();
                obj.objectValue = "a";
                expect(obj.storedObjectValue()).toBe("a!");
                expect(obj.objectValue).toBe("js a!");
                expect(obj.valueForKey("objectValue")).toBe("js a!");
                obj.setValueForKey("b", "objectValue");
                expect(obj.storedObjectValue()).toBe("b!");
            });
            var base = TNSInheritedSwizzleBase.new();
            base.objectValue = "a";
            base.setValueForKey("b", "objectValue");
            expect([base.storedObjectValue(), base.objectValue, base.valueForKey("objectValue")]).toEqual(["b", "b", "b"]);
        });

        it("reach the inherited accessors of a scalar property from JS", function () {
            install();
            [TNSInheritedSwizzleDerived, TNSInheritedSwizzleSubclass].forEach(function (Klass) {
                var obj = Klass.new();
                obj.scalarValue = 5;
                expect(obj.storedScalarValue()).toBe(6);
                expect(obj.scalarValue).toBe(12);
                expect(obj.valueForKey("scalarValue")).toBe(12);
                obj.setValueForKey(7, "scalarValue");
                expect(obj.storedScalarValue()).toBe(8);
            });
            var base = TNSInheritedSwizzleBase.new();
            base.scalarValue = 5;
            base.setValueForKey(7, "scalarValue");
            expect([base.storedScalarValue(), base.scalarValue, base.valueForKey("scalarValue")]).toEqual([7, 7, 7]);
        });

        it("reach the inherited accessors after a second replacement", function () {
            var proto = TNSInheritedSwizzleTwice.prototype;
            var original = inheritedDescriptor(proto, "scalarValue");
            Object.defineProperty(proto, "scalarValue", {
                get: function () {
                    return original.get.call(this) * 2;
                },
                set: function (value) {
                    original.set.call(this, value + 1);
                },
                configurable: true
            });
            var first = Object.getOwnPropertyDescriptor(proto, "scalarValue");
            Object.defineProperty(proto, "scalarValue", {
                get: function () {
                    return first.get.call(this) * 10;
                },
                set: function (value) {
                    first.set.call(this, value + 100);
                },
                configurable: true
            });
            var obj = TNSInheritedSwizzleTwice.new();
            obj.scalarValue = 5;
            expect(obj.storedScalarValue()).toBe(106);
            expect(obj.scalarValue).toBe(2120);
            expect(obj.valueForKey("scalarValue")).toBe(2120);
        });
    });

    // Each family is replaced by one spec group for the rest of the run. A
    // replacement records its tag in `trace` and calls the original it looked
    // up when it was installed: describeValue wraps the result in "tag(...)",
    // the object accessors wrap what they read and write, the scalar ones
    // append the tag's digit.
    describe("replaced on a class and on its subclass", function () {
        var trace = [];

        function replaceMembers(Klass, tag, digit) {
            var proto = Klass.prototype;
            var describeOriginal = proto.describeValue;
            proto.describeValue = function (value) {
                trace.push(tag);
                return tag + "(" + describeOriginal.call(this, value) + ")";
            };
            var objectOriginal = inheritedDescriptor(proto, "objectValue");
            Object.defineProperty(proto, "objectValue", {
                get: function () {
                    trace.push(tag + " get");
                    return tag + "(" + objectOriginal.get.call(this) + ")";
                },
                set: function (value) {
                    trace.push(tag + " set");
                    objectOriginal.set.call(this, tag + "(" + value + ")");
                },
                configurable: true
            });
            var scalarOriginal = inheritedDescriptor(proto, "scalarValue");
            Object.defineProperty(proto, "scalarValue", {
                get: function () {
                    trace.push(tag + " get");
                    return scalarOriginal.get.call(this) * 10 + digit;
                },
                set: function (value) {
                    trace.push(tag + " set");
                    scalarOriginal.set.call(this, value * 10 + digit);
                },
                configurable: true
            });
            return { describe: describeOriginal, object: objectOriginal, scalar: scalarOriginal };
        }

        function installer(replace) {
            var originals = null;
            return function () {
                if (originals === null) {
                    originals = replace();
                }
                trace.length = 0;
                return originals;
            };
        }

        function traced(action) {
            trace.length = 0;
            var result = action();
            return { result: result, trace: trace.slice() };
        }

        // The subclass's replacements find native members as their originals,
        // which run the superclass's native implementation, not its
        // replacement.
        describe("the superclass first", function () {
            var install = installer(function () {
                return { base: replaceMembers(TNSSwizzleChainBase, "B", 1), derived: replaceMembers(TNSSwizzleChainDerived, "D", 2) };
            });

            it("reach the native method from both replacements", function () {
                var originals = install();
                var derived = TNSSwizzleChainDerived.new();
                expect(traced(function () { return derived.describeValue(1); })).toEqual({ result: "D(base 1)", trace: ["D"] });
                expect(traced(function () { return originals.base.describe.call(derived, 2); })).toEqual({ result: "base 2", trace: [] });
                expect(traced(function () { return TNSSwizzleChainBase.new().describeValue(3); })).toEqual({ result: "B(base 3)", trace: ["B"] });
            });

            it("reach the native accessors of an object property from both replacements", function () {
                var originals = install();
                var derived = TNSSwizzleChainDerived.new();
                expect(traced(function () { derived.objectValue = "x"; return derived.storedObjectValue(); }))
                    .toEqual({ result: "D(x)", trace: ["D set"] });
                expect(traced(function () { return derived.objectValue; })).toEqual({ result: "D(D(x))", trace: ["D get"] });
                expect(traced(function () { return derived.valueForKey("objectValue"); })).toEqual({ result: "D(D(x))", trace: ["D get"] });
                expect(traced(function () { return originals.base.object.get.call(derived); })).toEqual({ result: "D(x)", trace: [] });
                var base = TNSSwizzleChainBase.new();
                base.objectValue = "y";
                expect([base.storedObjectValue(), base.valueForKey("objectValue")]).toEqual(["B(y)", "B(B(y))"]);
            });

            it("reach the native accessors of a scalar property from both replacements", function () {
                var originals = install();
                var derived = TNSSwizzleChainDerived.new();
                expect(traced(function () { derived.scalarValue = 5; return derived.storedScalarValue(); }))
                    .toEqual({ result: 52, trace: ["D set"] });
                expect(traced(function () { return derived.valueForKey("scalarValue"); })).toEqual({ result: 522, trace: ["D get"] });
                expect(traced(function () { return originals.base.scalar.get.call(derived); })).toEqual({ result: 52, trace: [] });
                var base = TNSSwizzleChainBase.new();
                base.scalarValue = 5;
                expect([base.storedScalarValue(), base.valueForKey("scalarValue")]).toEqual([51, 511]);
            });
        });

        // The subclass's replacement finds the native implementation as its
        // original, so the superclass's later replacement is not part of it.
        describe("the subclass first", function () {
            var install = installer(function () {
                return { derived: replaceMembers(TNSSwizzleReverseDerived, "D", 2), base: replaceMembers(TNSSwizzleReverseBase, "B", 1) };
            });

            it("reach the native method", function () {
                install();
                expect(traced(function () { return TNSSwizzleReverseDerived.new().describeValue(1); })).toEqual({ result: "D(base 1)", trace: ["D"] });
                expect(traced(function () { return TNSSwizzleReverseBase.new().describeValue(2); })).toEqual({ result: "B(base 2)", trace: ["B"] });
            });

            it("reach the native accessors of an object property", function () {
                install();
                var derived = TNSSwizzleReverseDerived.new();
                derived.objectValue = "x";
                expect([derived.storedObjectValue(), derived.valueForKey("objectValue")]).toEqual(["D(x)", "D(D(x))"]);
                var base = TNSSwizzleReverseBase.new();
                base.objectValue = "y";
                expect([base.storedObjectValue(), base.valueForKey("objectValue")]).toEqual(["B(y)", "B(B(y))"]);
            });

            it("reach the native accessors of a scalar property", function () {
                install();
                var derived = TNSSwizzleReverseDerived.new();
                derived.scalarValue = 5;
                expect([derived.storedScalarValue(), derived.valueForKey("scalarValue")]).toEqual([52, 522]);
                var base = TNSSwizzleReverseBase.new();
                base.scalarValue = 5;
                expect([base.storedScalarValue(), base.valueForKey("scalarValue")]).toEqual([51, 511]);
            });
        });

        // TNSSwizzleMiddle overrides every member natively, between the
        // replaced superclass and the replaced leaf, whose originals are
        // native functions.
        describe("the superclass first, with a native override in between", function () {
            var install = installer(function () {
                return { base: replaceMembers(TNSSwizzleMiddleBase, "B", 1), leaf: replaceMembers(TNSSwizzleMiddleLeaf, "L", 3) };
            });

            it("reach the middle class's native method", function () {
                var originals = install();
                var leaf = TNSSwizzleMiddleLeaf.new();
                expect(traced(function () { return leaf.describeValue(1); })).toEqual({ result: "L(middle 1)", trace: ["L"] });
                expect(traced(function () { return originals.base.describe.call(leaf, 2); })).toEqual({ result: "middle 2", trace: [] });
            });

            it("reach the middle class's native accessors of an object property", function () {
                install();
                var leaf = TNSSwizzleMiddleLeaf.new();
                leaf.objectValue = "x";
                expect(leaf.storedObjectValue()).toBe("L(x) via middle");
                expect(leaf.valueForKey("objectValue")).toBe("L(middle L(x) via middle)");
            });

            it("reach the middle class's native accessors of a scalar property", function () {
                install();
                var leaf = TNSSwizzleMiddleLeaf.new();
                leaf.scalarValue = 5;
                expect(leaf.storedScalarValue()).toBe(159);
                expect(leaf.valueForKey("scalarValue")).toBe(11593);
            });
        });
    });

    // TNSLinkedNode refers to itself through a pointer field.
    describe("of self-referential struct types", function () {
        var state = {};
        var Klass = null;

        function linkedClass() {
            if (Klass === null) {
                Klass = TNSLinkedTypes.extend({
                    get nodeProperty() {
                        return state.node;
                    },
                    set nodeProperty(value) {
                        state.node = value;
                    },
                    get holderProperty() {
                        return { node: null, leaf: null, count: 3 };
                    },
                    set holderProperty(value) {
                        state.holder = value;
                    },
                    get leafProperty() {
                        return null;
                    },
                    set leafProperty(value) {
                        state.leaf = value;
                    },
                    nextOf: function (node) {
                        return null;
                    },
                    holderWithLeaf: function (leaf) {
                        return { node: null, leaf: leaf, count: 0 };
                    }
                }, { name: "JSAccessorEncodingLinked" });
            }
            return Klass;
        }

        function address(value) {
            return value ? interop.handleof(value).toNumber() : 0;
        }

        function outcome(action) {
            try {
                return { value: action() };
            } catch (e) {
                return { error: e.nativeException ? e.nativeException.name : String(e) };
            }
        }

        it("report the compiler's types in the signatures of JS accessors and methods", function () {
            var Linked = linkedClass();
            [
                "nodeProperty", "setNodeProperty:", "holderProperty", "setHolderProperty:",
                "leafProperty", "setLeafProperty:", "nextOf:", "holderWithLeaf:"
            ].forEach(function (selector) {
                var expected = TNSLinkedTypes.instanceMethodSignatureForSelector(selector);
                var registered = NSMethodSignature.signatureWithObjCTypes(method_getTypeEncoding(class_getInstanceMethod(Linked.class(), selector)));
                expect([selector, typeString(registered.methodReturnType)]).toEqual([selector, typeString(expected.methodReturnType)]);
                expect([selector, registered.numberOfArguments]).toEqual([selector, expected.numberOfArguments]);
                for (var i = 2; i < expected.numberOfArguments; i++) {
                    expect([selector, typeString(registered.getArgumentTypeAtIndex(i))])
                        .toEqual([selector, typeString(expected.getArgumentTypeAtIndex(i))]);
                }
            });
        });

        // KVC answers NSUnknownKeyException for pointer-typed keys.
        it("read and write a pointer property through KVC as the base class does", function () {
            var Linked = linkedClass();
            var node = interop.alloc(16);
            var base = TNSLinkedTypes.new();
            var obj = Linked.new();
            state.node = null;

            function read(target) {
                return outcome(function () {
                    var boxed = target.valueForKey("nodeProperty");
                    return [typeString(boxed.objCType), address(boxed.pointerValue)];
                });
            }
            expect(read(obj)).toEqual(read(base));

            var written = outcome(function () {
                base.setValueForKey(NSValue.valueWithPointer(node), "nodeProperty");
                return address(base.nodeProperty);
            });
            var writtenByJS = outcome(function () {
                obj.setValueForKey(NSValue.valueWithPointer(node), "nodeProperty");
                return address(state.node);
            });
            expect(writtenByJS).toEqual(written);
        });
    });
});
