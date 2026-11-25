describe(module.id, function () {
    function findAccessor(proto, name) {
        while (proto) {
            var descriptor = Object.getOwnPropertyDescriptor(proto, name);
            if (descriptor) {
                return descriptor;
            }
            proto = Object.getPrototypeOf(proto);
        }
        return undefined;
    }

    // Objects with internal fields that hold no native object wrapper.
    function receiversWithoutNativeObject() {
        return [
            new URL("https://example.com/"),
            NSArray.arrayWithArray([1])[Symbol.iterator]()
        ];
    }

    // Objects whose wrapper is not an Objective-C instance.
    function receiversOfOtherWrapperTypes() {
        return [
            new interop.Pointer(1),
            new interop.Reference(interop.types.int32, 1)
        ];
    }

    it("throws a TypeError when a native method is called on a receiver without a native object", function () {
        receiversWithoutNativeObject().forEach(function (receiver) {
            expect(function () {
                NSMutableString.prototype.appendString.call(receiver, "x");
            }).toThrowError(TypeError, /Cannot call method 'appendString' on a receiver that has no native object \(class: NSMutableString, selector: appendString:\)/);
            expect(function () {
                findAccessor(NSString.prototype, "length").get.call(receiver);
            }).toThrowError(TypeError, /receiver that has no native object \(class: NSString, selector: length\)/);
        });
    });

    it("throws a TypeError when a native method is called on a receiver that is not a native object instance", function () {
        receiversOfOtherWrapperTypes().forEach(function (receiver) {
            expect(function () {
                NSMutableString.prototype.appendString.call(receiver, "x");
            }).toThrowError(TypeError, /Cannot call method 'appendString' on a receiver that is not a native object instance \(wrapper type \d+\) \(class: NSMutableString, selector: appendString:\)/);
            expect(function () {
                findAccessor(NSOperation.prototype, "name").set.call(receiver, "x");
            }).toThrowError(TypeError, /receiver that is not a native object instance .*selector: setName:\)/);
        });
    });

    it("throws a TypeError when a native instance method is called on a plain object", function () {
        [{}, Object.create(NSObject.prototype), function () {}].forEach(function (receiver) {
            expect(function () {
                NSObject.prototype.isEqual.call(receiver, null);
            }).toThrowError(TypeError, /Cannot call method 'isEqual' on a receiver that is not a native object \(class: NSObject, selector: isEqual:\)/);
        });
        expect(function () {
            Object.create(NSMutableString.prototype).appendString("x");
        }).toThrowError(TypeError, /receiver that is not a native object \(class: NSMutableString, selector: appendString:\)/);
    });

    it("throws a TypeError when a native instance property is read or written on a plain object", function () {
        [{}, Object.create(NSOperation.prototype)].forEach(function (receiver) {
            expect(function () {
                findAccessor(NSObject.prototype, "description").get.call(receiver);
            }).toThrowError(TypeError, /receiver that is not a native object \(class: NSObject, selector: description\)/);
            expect(function () {
                findAccessor(NSOperation.prototype, "name").set.call(receiver, "x");
            }).toThrowError(TypeError, /receiver that is not a native object \(class: NSOperation, selector: setName:\)/);
        });
        expect(function () {
            return NSOperation.prototype.name;
        }).toThrowError(TypeError, /receiver that is not a native object/);
    });

    it("calls a native instance member on a native class constructor as a class-side call", function () {
        expect(NSObject.prototype.isEqual.call(NSString, NSString)).toBe(true);
        expect(NSObject.prototype.isEqual.call(NSString, NSNumber)).toBe(false);
        expect(NSObject.prototype.isEqual.call(new Proxy(NSString, {}), NSString)).toBe(true);
        expect(findAccessor(NSObject.prototype, "description").get.call(NSString)).toBe("NSString");
    });

    it("keeps class methods callable on native, extended and unbound constructors", function () {
        expect(NSString.stringWithString("a").toString()).toBe("a");
        var unbound = NSString.stringWithString;
        expect(unbound("b").toString()).toBe("b");
        expect(NSString.stringWithString.call({}, "c").toString()).toBe("c");

        var Extended = NSObject.extend({ answer: function () { return 42; } });
        var extended = Extended.new();
        expect(extended instanceof Extended).toBe(true);
        expect(extended.answer()).toBe(42);
        expect(extended.isEqual(extended)).toBe(true);

        class ESSubclass extends NSMutableArray {}
        expect(ESSubclass.arrayWithArray([1, 2]).count).toBe(2);
    });

    it("leaves the runtime usable after rejecting an invalid receiver", function () {
        expect(function () {
            NSMutableString.prototype.appendString.call(new interop.Pointer(1), "x");
        }).toThrowError(TypeError);

        var string = NSMutableString.alloc().init();
        string.appendString("ok");
        expect(string.toString()).toBe("ok");
    });
});
