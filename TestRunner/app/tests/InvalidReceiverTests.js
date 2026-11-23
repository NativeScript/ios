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

    it("leaves the runtime usable after rejecting an invalid receiver", function () {
        expect(function () {
            NSMutableString.prototype.appendString.call(new interop.Pointer(1), "x");
        }).toThrowError(TypeError);

        var string = NSMutableString.alloc().init();
        string.appendString("ok");
        expect(string.toString()).toBe("ok");
    });
});
