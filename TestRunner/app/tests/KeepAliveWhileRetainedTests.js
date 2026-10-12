describe("interop.keepAliveWhileRetained", function () {
    // Only the TypeScript __extends path installs the retain/release swizzles
    // that observe native retains.
    function makeExtendedClass() {
        return (function (_super) {
            __extends(KeepAliveParent, _super);
            function KeepAliveParent() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return KeepAliveParent;
        })(NSObject);
    }

    // Overwrites the stack region that held the creation locals so
    // conservative stack scanning cannot keep dead wrappers alive.
    function scrubStack() {
        return (function scrub(n) {
            return n > 0 ? scrub(n - 1) + n : 0;
        })(300);
    }

    it("keeps what a natively retained instance references alive", function () {
        var Parent = makeExtendedClass();
        var N = 16;
        var holder = NSMutableArray.alloc().init();

        (function create() {
            for (var i = 0; i < N; i++) {
                var parent = Parent.alloc().init();
                // Before and after the native retain: both orders must root.
                if (i % 2 === 0) {
                    interop.keepAliveWhileRetained(parent);
                    holder.addObject(parent);
                } else {
                    holder.addObject(parent);
                    interop.keepAliveWhileRetained(parent);
                }
                // Owned only by JS, reachable only through the parent.
                parent.child = NSMutableArray.alloc().init();
                parent.child.addObject(i);
                parent.__mine = true;
            }
        })();

        scrubStack();
        __collect();
        __collect();

        for (var i = 0; i < N; i++) {
            var parent = holder.objectAtIndex(i);
            expect(parent.__mine).toBe(true);
            expect(parent.child.count).toBe(1);
            expect(parent.child.objectAtIndex(0)).toBe(i);
        }
    });

    it("lets the instance be collected once native lets go", function (done) {
        var Parent = makeExtendedClass();
        var holder = NSMutableArray.alloc().init();
        var ref;

        (function create() {
            var parent = Parent.alloc().init();
            interop.keepAliveWhileRetained(parent);
            holder.addObject(parent);
            ref = new WeakRef(parent);
        })();

        scrubStack();
        __collect();
        setTimeout(function () {
            __collect();
            // A boolean, not the object: Jasmine must not hold a reference.
            expect(ref.deref() !== undefined).toBe(true);

            holder.removeAllObjects();
            scrubStack();
            setTimeout(function () {
                __collect();
                setTimeout(function () {
                    __collect();
                    expect(ref.deref()).toBeUndefined();
                    done();
                }, 0);
            }, 0);
        }, 0);
    });

    it("throws a TypeError for objects whose retains are not observed", function () {
        expect(function () {
            interop.keepAliveWhileRetained(NSObject.alloc().init());
        }).toThrowError(TypeError);

        var PlainExtended = NSObject.extend({}, { name: "KeepAlivePlainExtended" });
        expect(function () {
            interop.keepAliveWhileRetained(PlainExtended.alloc().init());
        }).toThrowError(TypeError);

        expect(function () {
            interop.keepAliveWhileRetained({});
        }).toThrowError(TypeError);
        expect(function () {
            interop.keepAliveWhileRetained();
        }).toThrowError(TypeError);
    });

    // Retiring a registration whose handle is strong has to take its parked
    // weak-callback state back; otherwise the handle stays a root forever.
    it("frees the handle when an instance kept alive is retired by __releaseNativeCounterpart", function (done) {
        var Parent = makeExtendedClass();
        var holder = NSMutableArray.alloc().init();
        var ref;

        (function create() {
            var parent = Parent.alloc().init();
            interop.keepAliveWhileRetained(parent);
            holder.addObject(parent);
            ref = new WeakRef(parent);
            __releaseNativeCounterpart(parent);
        })();

        scrubStack();
        __collect();
        setTimeout(function () {
            __collect();
            expect(ref.deref()).toBeUndefined();
            holder.removeAllObjects();
            done();
        }, 0);
    });
});
