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
});
