// Objects whose declared type adds protocols to their class (id<P>, T<P>*)
// get a binding with the protocols' members on top of the class's own.
describe("Protocol-qualified object bindings", function () {
    it("reuses one binding per class and protocol set", function () {
        var a = TNSPseudoDataType.getId();
        var b = TNSPseudoDataType.getId();
        expect(Object.getPrototypeOf(a)).toBe(Object.getPrototypeOf(b));

        var c = TNSPseudoDataType.getType();
        var d = TNSPseudoDataType.getType();
        expect(Object.getPrototypeOf(c)).toBe(Object.getPrototypeOf(d));
    });

    it("does not build new bindings for repeated objects", function () {
        var prototype = Object.getPrototypeOf(TNSPseudoDataType.getId());
        var distinct = 0;
        for (var i = 0; i < 500; i++) {
            if (Object.getPrototypeOf(TNSPseudoDataType.getId()) !== prototype) {
                distinct++;
            }
        }
        expect(distinct).toBe(0);
    });

    it("leaves the global class constructors in place", function () {
        var nsObject = NSObject;
        var tnsType = TNSType;
        TNSPseudoDataType.getId();
        TNSPseudoDataType.getType();
        expect(NSObject).toBe(nsObject);
        expect(TNSType).toBe(tnsType);
        expect(NSDate.date() instanceof NSObject).toBe(true);
        expect(NSObject.prototype.isPrototypeOf(UIView.prototype)).toBe(true);
    });

    it("keeps such objects instances of their class", function () {
        // getId() answers a private TNSType subclass, so its binding is TNSType's.
        var id = TNSPseudoDataType.getId();
        var type = TNSPseudoDataType.getType();
        expect(id instanceof TNSType).toBe(true);
        expect(id instanceof NSObject).toBe(true);
        expect(id.constructor).toBe(TNSType);
        expect(type instanceof TNSType).toBe(true);
        expect(type instanceof NSObject).toBe(true);
        expect(type.constructor).toBe(TNSType);
        expect(NSObject.alloc().init().methodFromProto1).toBeUndefined();
    });

    it("shares one binding across NSNotificationCenter observer tokens", function () {
        var center = NSNotificationCenter.defaultCenter;
        var nsObject = NSObject;
        var make = function () {
            return center.addObserverForNameObjectQueueUsingBlock("ProtocolBindingProbe", null, null, function () {});
        };
        var a = make();
        var b = make();
        try {
            expect(Object.getPrototypeOf(a)).toBe(Object.getPrototypeOf(b));
            expect(a.constructor).toBe(b.constructor);
            expect(NSObject).toBe(nsObject);
            expect(a instanceof NSObject).toBe(true);
        } finally {
            center.removeObserver(a);
            center.removeObserver(b);
        }
    });
});
