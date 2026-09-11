// iOS-side regression specs for the messaging tier. The shared suites under
// app/shared cover the specified behavior; these pin runtime edges that need
// native wrappers, a worker that never settles, or a collection.
describe("Messaging runtime edges", function () {
    var parkedEntry = "./messaging/parkedWorker.mjs";
    // Delivery goes through the event loop; SETTLE is long enough that an
    // event which was going to arrive would have.
    var SETTLE = 400;

    describe("transfer lists", function () {
        it("rejects a buffer a getter detached while the graph was being written", function () {
            var buffer = new ArrayBuffer(16);
            var error = null;
            try {
                structuredClone({ get x() { buffer.transfer(); return 1; } }, { transfer: [buffer] });
            } catch (e) {
                error = e;
            }
            expect(error).not.toBeNull();
            expect(error.name).toBe("DataCloneError");
        });

        it("hands a listed port over through the cloned value", function (done) {
            var channel = new MessageChannel();
            var clone = structuredClone(channel.port2, { transfer: [channel.port2] });
            expect(clone instanceof MessagePort).toBe(true);
            expect(clone).not.toBe(channel.port2);
            clone.addEventListener("message", function (event) {
                expect(event.data).toBe("through");
                clone.close();
                channel.port1.close();
                done();
            });
            channel.port1.postMessage("through");
        });

        it("closes a listed port the cloned value never names", function (done) {
            var channel = new MessageChannel();
            var closed = false;
            channel.port1.addEventListener("close", function () { closed = true; });
            structuredClone({}, { transfer: [channel.port2] });
            setTimeout(function () {
                expect(closed).toBe(true);
                channel.port1.close();
                done();
            }, SETTLE);
        });

        it("closes a port transferred to a worker that is terminated before its entry settles", function (done) {
            var worker = new Worker(parkedEntry);
            var channel = new MessageChannel();
            var closed = false;
            channel.port1.addEventListener("close", function () { closed = true; });
            worker.postMessage(channel.port2, [channel.port2]);
            worker.terminate();
            setTimeout(function () {
                expect(closed).toBe(true);
                channel.port1.close();
                done();
            }, SETTLE);
        });
    });

    describe("handler attributes", function () {
        it("enables a port when onmessage is first set to null", function (done) {
            var channel = new MessageChannel();
            channel.port2.postMessage("consumed");
            channel.port1.onmessage = null;
            setTimeout(function () {
                var received = 0;
                channel.port1.addEventListener("message", function () { received++; });
                setTimeout(function () {
                    expect(received).toBe(0);
                    channel.port1.close();
                    channel.port2.close();
                    done();
                }, SETTLE);
            }, SETTLE);
        });

        it("keeps a port disabled until a handler or listener arrives", function (done) {
            var channel = new MessageChannel();
            channel.port2.postMessage("kept");
            setTimeout(function () {
                var received = 0;
                channel.port1.addEventListener("message", function () { received++; });
                setTimeout(function () {
                    expect(received).toBe(1);
                    channel.port1.close();
                    channel.port2.close();
                    done();
                }, SETTLE);
            }, SETTLE);
        });
    });

    describe("AbortSignal handler attribute accounting", function () {
        function pollGC(predicate, cb) {
            var turns = 0;
            (function poll() {
                __collect();
                if (predicate() || turns >= 100) {
                    cb();
                    return;
                }
                turns++;
                setTimeout(poll, 20);
            })();
        }

        it("a timeout signal whose onabort was only ever set to null is collectable", function (done) {
            var wr = (function () {
                var signal = AbortSignal.timeout(60000);
                signal.onabort = null;
                return new WeakRef(signal);
            })();
            pollGC(function () { return wr.deref() === undefined; }, function () {
                expect(wr.deref()).toBeUndefined();
                done();
            });
        });

        it("a timeout signal whose onabort was cleared again is collectable", function (done) {
            var wr = (function () {
                var signal = AbortSignal.timeout(60000);
                signal.onabort = function () {};
                signal.onabort = null;
                return new WeakRef(signal);
            })();
            pollGC(function () { return wr.deref() === undefined; }, function () {
                expect(wr.deref()).toBeUndefined();
                done();
            });
        });

        it("a timeout signal with an onabort handler survives GC and still aborts", function (done) {
            var reasonName = null;
            (function () {
                AbortSignal.timeout(300).onabort = function (event) {
                    reasonName = event.target.reason.name;
                };
            })();
            __collect();
            pollGC(function () { return reasonName !== null; }, function () {
                expect(reasonName).toBe("TimeoutError");
                done();
            });
        });
    });
});
