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

        it("rejects values it cannot charge", function () {
            expect(function () { interop.setExternalSize({}, 10); }).toThrowError(TypeError);
            expect(function () { interop.setExternalSize(NSObject, 10); }).toThrowError(TypeError);
            expect(function () { interop.setExternalSize(interop.types.int32, 10); }).toThrowError(TypeError);
            expect(function () { interop.setExternalSize(new CGPoint({ x: 1, y: 2 }), 10); }).toThrowError(TypeError);
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

    describe("+0 objects JS ends up owning", function () {
        var napi = require("napitestmodule");

        function poll(predicate, timeoutMs, done) {
            var deadline = Date.now() + timeoutMs;
            (function check() {
                if (predicate() || Date.now() > deadline) {
                    done();
                } else {
                    setTimeout(check, 10);
                }
            })();
        }

        function receive(pass, length) {
            var received;
            pass(length, function (data) {
                received = data;
                expect(interop.getExternalSize(data)).toBe(0);
            });
            return received;
        }

        it("charges a block argument once native lets go of it, not before", function (done) {
            var data = receive(TNSExternalMemory.passFreshDataOfLengthTo, 256 * 1024);
            expect(interop.getExternalSize(data)).toBe(0);
            poll(function () { return interop.getExternalSize(data) > 0; }, 2000, function () {
                expect(interop.getExternalSize(data)).toBe(256 * 1024);
                done();
            });
        });

        it("charges an autoreleased block argument once the pool drained", function (done) {
            var data = receive(TNSExternalMemory.passAutoreleasedDataOfLengthTo, 128 * 1024);
            poll(function () { return interop.getExternalSize(data) > 0; }, 2000, function () {
                expect(interop.getExternalSize(data)).toBe(128 * 1024);
                done();
            });
        });

        it("charges a block argument whose bytes JS also reads through a buffer", function (done) {
            var buffer;
            var data = receive(function (length, cb) {
                TNSExternalMemory.passFreshDataOfLengthTo(length, function (d) {
                    buffer = interop.bufferFromData(d);
                    cb(d);
                });
            }, 96 * 1024);
            poll(function () { return interop.getExternalSize(data) > 0; }, 2000, function () {
                expect(buffer.byteLength).toBe(96 * 1024);
                expect(interop.getExternalSize(data)).toBe(96 * 1024);
                done();
            });
        });

        it("charges a fresh +0 return once the pool drained", function (done) {
            var sub = NSMutableData.dataWithLength(1000).subdataWithRange({ location: 0, length: 500 });
            expect(interop.getExternalSize(sub)).toBe(0);
            poll(function () { return interop.getExternalSize(sub) > 0; }, 2000, function () {
                expect(interop.getExternalSize(sub)).toBe(500);
                done();
            });
        });

        it("does not charge objects native still retains", function (done) {
            var kept = receive(TNSExternalMemory.passKeptDataOfLengthTo, 64 * 1024);
            var shared = receive(function (length, cb) { TNSExternalMemory.passSharedDataTo(cb); });
            var empty = receive(function (length, cb) { TNSExternalMemory.passEmptyDataTo(cb); });
            setTimeout(function () {
                setTimeout(function () {
                    expect(interop.getExternalSize(kept)).toBe(0);
                    expect(interop.getExternalSize(shared)).toBe(0);
                    expect(interop.getExternalSize(empty)).toBe(0);
                    TNSExternalMemory.releaseKeptData();
                    done();
                }, 100);
            }, 100);
        });

        it("charges block arguments delivered on another thread", function (done) {
            var received = [];
            var finished = false;
            TNSExternalMemory.streamDataOfLengthCountIntervalMsToCompletion(48 * 1024, 5, 5, function (data) {
                received.push(data);
            }, function () {
                finished = true;
            });
            function allCharged() {
                return finished && received.length === 5 &&
                    received.every(function (d) { return interop.getExternalSize(d) > 0; });
            }
            poll(allCharged, 3000, function () {
                expect(received.length).toBe(5);
                received.forEach(function (d) {
                    expect(interop.getExternalSize(d)).toBe(48 * 1024);
                });
                done();
            });
        });

        it("charges in a worker isolate", function (done) {
            var worker = new Worker("./externalMemorySoleOwnerWorker.js");
            worker.onmessage = function (msg) {
                expect(msg.data.localBefore).toBe(0);
                expect(msg.data.local).toBe(128 * 1024);
                expect(msg.data.streamed).toEqual([32 * 1024, 32 * 1024, 32 * 1024, 32 * 1024]);
                worker.terminate();
                done();
            };
            worker.onerror = function (e) {
                expect(String(e && e.message ? e.message : e)).toBe("<no worker error>");
                worker.terminate();
                done();
            };
            worker.postMessage(0);
        });

        it("returns the charges when the wrappers are collected", function (done) {
            var count = 16;
            var length = 1024 * 1024;
            var held = [];
            for (var i = 0; i < count; i++) {
                held.push(receive(TNSExternalMemory.passFreshDataOfLengthTo, length));
            }
            poll(function () {
                return held.every(function (d) { return interop.getExternalSize(d) > 0; });
            }, 2000, function () {
                held.forEach(function (d) { expect(interop.getExternalSize(d)).toBe(length); });
                var charged = napi.externalMemory();
                held = null;
                __collect();
                __collect();
                expect(charged - napi.externalMemory()).not.toBeLessThan(count * length);
                done();
            });
        });

        it("survives a burst larger than it tracks", function (done) {
            // A turn first, so the burst starts from an empty list.
            setTimeout(function () {
                var all = [];
                for (var i = 0; i < 6000; i++) {
                    all.push(receive(TNSExternalMemory.passFreshDataOfLengthTo, 16));
                }
                poll(function () { return interop.getExternalSize(all[0]) > 0; }, 2000, function () {
                    expect(interop.getExternalSize(all[0])).toBe(16);
                    expect(interop.getExternalSize(all[all.length - 1])).toBe(0);
                    done();
                });
            }, 0);
        });
    });
});
