describe("External memory accounting", function () {
    describe("interop.setExternalSize", function () {
        it("charges, replaces and clears the size of a native object", function () {
            var obj = NSObject.alloc().init();
            expect(interop.getExternalSize(obj)).toBe(0);

            interop.setExternalSize(obj, 1024 * 1024);
            expect(interop.getExternalSize(obj)).toBe(1024 * 1024);

            interop.setExternalSize(obj, 4096);
            expect(interop.getExternalSize(obj)).toBe(4096);

            interop.setExternalSize(obj, 0);
            expect(interop.getExternalSize(obj)).toBe(0);
        });

        it("accepts pointers and references", function () {
            var ptr = new interop.Pointer(0x1000);
            interop.setExternalSize(ptr, 100);
            expect(interop.getExternalSize(ptr)).toBe(100);

            var ref = new interop.Reference(interop.types.int32, 5);
            interop.setExternalSize(ref, 200);
            expect(interop.getExternalSize(ref)).toBe(200);
        });

        it("rejects values that do not die with their JS object", function () {
            expect(function () { interop.setExternalSize({}, 10); }).toThrowError(TypeError);
            expect(function () { interop.setExternalSize(NSObject, 10); }).toThrowError(TypeError);
            expect(function () { interop.setExternalSize(interop.types.int32, 10); }).toThrowError(TypeError);
        });

        it("rejects byte counts outside the accepted range", function () {
            var obj = NSObject.alloc().init();
            expect(function () { interop.setExternalSize(obj, -1); }).toThrowError(RangeError);
            expect(function () { interop.setExternalSize(obj, NaN); }).toThrowError(RangeError);
            expect(function () { interop.setExternalSize(obj, "10"); }).toThrowError(RangeError);
            expect(function () { interop.setExternalSize(obj, Math.pow(2, 40)); }).toThrowError(RangeError);
            expect(interop.getExternalSize(obj)).toBe(0);
        });

        it("returns charges to V8 when the wrappers are collected", function () {
            // A leaked charge only shows up as V8 scheduling ever more
            // collections, so this guards the release paths against crashing:
            // finalizers, explicit release, and both after a re-charge.
            for (var i = 0; i < 200; i++) {
                var obj = NSObject.alloc().init();
                interop.setExternalSize(obj, 256 * 1024);
                interop.setExternalSize(obj, 512 * 1024);
                if (i % 2 === 0) {
                    __releaseNativeCounterpart(obj);
                }
            }
            __collect();
            __collect();
            expect(true).toBe(true);
        });
    });

    describe("interop.alloc", function () {
        it("charges the allocated size to the returned pointer", function () {
            var ptr = interop.alloc(64 * 1024);
            expect(interop.getExternalSize(ptr)).toBe(64 * 1024);
        });
    });

    describe("estimated sizes", function () {
        it("charges NSData created by a class factory", function () {
            var data = NSMutableData.dataWithLength(8192);
            expect(interop.getExternalSize(data)).toBe(8192);
        });

        it("charges NSData created by a JS constructor", function () {
            var data = new NSMutableData({ length: 4096 });
            expect(interop.getExternalSize(data)).toBe(4096);
        });

        it("charges NSData returned at +1", function () {
            var data = NSMutableData.dataWithLength(1000);
            var copy = data.mutableCopy();
            expect(interop.getExternalSize(copy)).toBe(1000);
        });

        it("does not charge objects returned by instance getters", function () {
            var data = NSMutableData.dataWithLength(1000);
            var sub = data.subdataWithRange({ location: 0, length: 500 });
            expect(interop.getExternalSize(sub)).toBe(0);
        });

        it("charges a native copy of a JS buffer", function () {
            var data = NSData.dataWithData(new ArrayBuffer(2048));
            expect(interop.getExternalSize(data)).toBe(2048);
        });

        it("charges the bitmap of images", function () {
            var width = 64;
            var height = 32;
            var colorSpace = CGColorSpaceCreateDeviceRGB();
            var context = CGBitmapContextCreate(null, width, height, 8, width * 4, colorSpace,
                CGImageAlphaInfo.kCGImageAlphaPremultipliedLast);
            var cgImage = CGBitmapContextCreateImage(context);
            var bytes = CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage);
            expect(bytes).toBeGreaterThan(0);
            expect(interop.getExternalSize(cgImage)).toBe(bytes);

            var image = UIImage.imageWithCGImage(cgImage);
            expect(interop.getExternalSize(image)).toBe(bytes);
        });
    });
});
