// End-to-end Swift interop: the SwiftDemo fixture
// (metadata-generator/TestFixtures/SwiftDemo) is linked into TestRunner with
// the thunks the metadata generator emits for it, and reached through ns:swift.
describe("ns:swift", function () {
    var swift = require("ns:swift");
    var SwiftDemo = swift.module("SwiftDemo");

    describe("modules", function () {
        it("exports a frozen loader", function () {
            expect(Object.isFrozen(swift)).toBe(true);
            expect(Object.keys(swift).sort()).toEqual(["abiVersion", "info", "module"]);
            expect(swift.abiVersion).toBe(3);
        });

        it("returns one frozen namespace per module", function () {
            expect(swift.module("SwiftDemo")).toBe(SwiftDemo);
            expect(Object.isFrozen(SwiftDemo)).toBe(true);
        });

        it("describes the linked module", function () {
            var info = swift.info("SwiftDemo");
            expect(info.name).toBe("SwiftDemo");
            expect(info.abiVersion).toBe(3);
            expect(info.fingerprint).toMatch(/^[0-9a-f]{16}$/);
            expect(info.members).toBeGreaterThan(0);
        });

        it("reports modules that are not linked", function () {
            expect(function () { swift.module("NoSuchSwiftModule"); })
                .toThrowError(/NoSuchSwiftModule.*not linked/);
            expect(function () { swift.module("bad name"); }).toThrowError(TypeError);
        });

        it("resolves ns:swift/<Module> to the module's exports", function () {
            expect(require("ns:swift/SwiftDemo")).toBe(SwiftDemo);
            expect(function () { require("ns:swift/NoSuchSwiftModule"); })
                .toThrowError(/not linked/);
        });

        it("imports ns:swift/<Module> as an ES module", function (done) {
            import("ns:swift/SwiftDemo").then(function (namespace) {
                expect(namespace.Demo).toBe(SwiftDemo.Demo);
                expect(namespace.default).toBe(SwiftDemo);
                expect(new namespace.Demo().greet("esm")).toBe("Hello, esm");
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("exposes only the generated surface", function () {
            // Unsupported declarations (async, generic, closures, ...) are absent.
            expect(SwiftDemo.Loader.prototype.update).toBeUndefined();
            expect(SwiftDemo.Loader.prototype.transform).toBeUndefined();
            expect(SwiftDemo.ShapeError).toBeUndefined();
        });
    });

    describe("classes", function () {
        it("constructs and calls instance methods", function () {
            var demo = new SwiftDemo.Demo();
            expect(demo instanceof SwiftDemo.Demo).toBe(true);
            expect(demo.greet("NativeScript")).toBe("Hello, NativeScript");
        });

        it("dispatches overloads by arity", function () {
            var demo = new SwiftDemo.Demo();
            expect(demo.greet("a", 2)).toBe("Hello, aHello, a");
            expect(demo["greet(name:times:)"]("b", 1)).toBe("Hello, b");
        });

        it("reads static properties", function () {
            expect(SwiftDemo.Demo.version).toBe("1.0");
        });

        it("requires new", function () {
            expect(function () { SwiftDemo.Demo(); }).toThrowError(TypeError);
        });

        it("models inheritance", function () {
            var square = new SwiftDemo.Square(3);
            expect(square instanceof SwiftDemo.Square).toBe(true);
            expect(square instanceof SwiftDemo.Polygon).toBe(true);
            expect(square.area).toBe(9);
            expect(square.name).toBe("square");
            expect(square.vertexCount).toBe(4);
            expect(SwiftDemo.Square.sides).toBe(4);
            // Square overrides scale(by: Double) and inherits scale(by: Int)
            // and scale(x:y:).
            expect(function () { square.scale(2); }).toThrowError(TypeError, /Ambiguous/);
            square["scale(by: Double)"](2);
            expect(square.side).toBe(6);
            square.scale(1, 1);
        });

        it("wraps returned objects with their dynamic type", function () {
            var made = SwiftDemo.Polygon.make();
            expect(made instanceof SwiftDemo.Polygon).toBe(true);
            expect(made.vertexCount).toBe(3);
            expect(SwiftDemo.Polygon.describe(made)).toBe("made");
            expect(SwiftDemo.Polygon.describe(new SwiftDemo.Square(1))).toBe("square");
            expect(SwiftDemo.Polygon.describe(null)).toBe("none");
        });

        it("accepts labeled initializer arguments", function () {
            var polygon = new SwiftDemo.Polygon({ name: "tri", vertexCount: 3 });
            expect(polygon.name).toBe("tri");
            expect(polygon.vertexCount).toBe(3);
        });

        it("reports failed failable initializers", function () {
            expect(new SwiftDemo.Polygon("hex").name).toBe("hex");
            expect(function () { new SwiftDemo.Polygon(""); }).toThrowError(/failed/);
        });

        it("rejects calls it cannot resolve", function () {
            var polygon = new SwiftDemo.Polygon("p");
            // scale(by: Double) and scale(by: Int) both accept a number.
            expect(function () { polygon.scale(2); }).toThrowError(TypeError, /Ambiguous.*scale\(by: Int\)/);
            polygon["scale(by: Int)"](2);
            polygon["scale(by: Double)"](2.5);
            polygon.scale(1, 2);
            expect(function () { polygon.scale("x"); }).toThrowError(TypeError, /No overload/);
        });

        it("rejects receivers of the wrong type", function () {
            var greet = SwiftDemo.Demo.prototype.greet;
            expect(function () { greet.call({}, "x"); }).toThrowError(TypeError, /Illegal invocation/);
            expect(function () { greet.call(new SwiftDemo.Loader(), "x"); }).toThrowError(TypeError);
        });

        it("calls nonisolated actor members", function () {
            expect(new SwiftDemo.Counter().label()).toBe("counter");
        });

        it("calls deprecated and availability-gated members", function () {
            var loader = new SwiftDemo.Loader();
            expect(loader.legacyFetch()).toBeUndefined();
            expect(loader.modernOnly()).toBeUndefined();
        });
    });

    describe("structs", function () {
        it("constructs positionally and by label", function () {
            var a = new SwiftDemo.Point(2, 3);
            var b = new SwiftDemo.Point({ x: 2, y: 3 });
            expect(a.x).toBe(2);
            expect(b.y).toBe(3);
            expect(a.length).toBeCloseTo(Math.sqrt(13), 10);
            expect(a.description).toBe("(2.0, 3.0)");
        });

        it("mutates its own copy", function () {
            var point = new SwiftDemo.Point(1, 1);
            point.x = 5;
            expect(point.x).toBe(5);

            var ring = new SwiftDemo.Ring(new SwiftDemo.Point(0, 0), new SwiftDemo.Point(1, 1));
            var outer = ring.outer;
            outer.x = 100;
            // `outer` is a copy; the ring's value is unchanged.
            expect(ring.outer.x).toBe(1);
            ring.expand(2);
            expect(ring.outer.x).toBe(3);
            expect(outer.x).toBe(100);
        });

        it("passes structs by value", function () {
            var inner = new SwiftDemo.Point(0, 0);
            var ring = new SwiftDemo.Ring(inner, new SwiftDemo.Point(1, 1));
            inner.x = 9;
            expect(ring.inner.x).toBe(0);
        });
    });

    describe("enums", function () {
        it("represents cases by name", function () {
            expect(SwiftDemo.Flavor.vanilla).toBe("vanilla");
            expect(SwiftDemo.Flavor.chocolate).toBe("chocolate");
            expect(Object.isFrozen(SwiftDemo.Flavor)).toBe(true);
            expect(SwiftDemo.defaultFlavor).toBe("vanilla");
        });

        it("initializes from raw values", function () {
            expect(SwiftDemo.Flavor.init(1)).toBe("chocolate");
            expect(SwiftDemo.Flavor.init(7)).toBe(null);
            expect(SwiftDemo.Precipitation.init("snow")).toBe("snow");
        });

        it("keeps a case named none distinct from nil", function () {
            expect(SwiftDemo.Precipitation.none).toBe("none");
            expect(SwiftDemo.Precipitation.init("none")).toBe("none");
            expect(SwiftDemo.Precipitation.init("hail")).toBe(null);
        });

        it("calls instance members with the case as receiver", function () {
            expect(SwiftDemo.Flavor.description("chocolate")).toBe("chocolate");
            expect(function () { SwiftDemo.Flavor.description("mint"); }).toThrowError(TypeError);
        });
    });

    describe("values", function () {
        it("calls module functions and variables", function () {
            var point = SwiftDemo.makeDefaultPoint();
            expect(point instanceof SwiftDemo.Point).toBe(true);
            expect(point.x).toBe(0);

            var before = SwiftDemo.globalCounter;
            SwiftDemo.globalCounter = before + 41;
            expect(SwiftDemo.globalCounter).toBe(before + 41);
        });

        it("checks integer ranges", function () {
            expect(SwiftDemo.echoInt8(-128)).toBe(-128);
            expect(function () { SwiftDemo.echoInt8(128); }).toThrowError(RangeError);
            expect(function () { SwiftDemo.echoInt8(1.5); }).toThrowError(TypeError);
            expect(SwiftDemo.echoUInt64(5n)).toBe(5);
            expect(function () { SwiftDemo.echoUInt64(-1); }).toThrowError(RangeError);
            // Int.max has no exact JS number.
            expect(function () { SwiftDemo.largestInt(); }).toThrowError(RangeError);
        });

        it("maps optionals to null", function () {
            expect(SwiftDemo.shout("hi")).toBe("HI");
            expect(SwiftDemo.shout(null)).toBe(null);
            expect(SwiftDemo.shout(undefined)).toBe(null);
        });

        it("checks argument types", function () {
            var demo = new SwiftDemo.Demo();
            expect(function () { demo.greet(5); }).toThrowError(TypeError);
            expect(function () { new SwiftDemo.Ring(1, 2); }).toThrowError(TypeError);
        });

        it("turns Swift errors into JS errors", function () {
            expect(SwiftDemo.checkedSide(2)).toBe(2);
            try {
                SwiftDemo.checkedSide(-1);
                fail("expected a throw");
            } catch (e) {
                expect(e instanceof Error).toBe(true);
                expect(e.name).toBe("SwiftError");
                expect(e.swiftType).toBe("SwiftDemo.ShapeError");
                expect(e.message).toContain("invalidSide(-1.0)");
            }
        });
    });

    describe("nested types", function () {
        it("hangs nested types off their parent", function () {
            expect(SwiftDemo.Polygon.Style.dashed).toBe("dashed");
            expect(SwiftDemo.Polygon.Style.init("solid")).toBe("solid");
            expect(new SwiftDemo.Polygon("tri").style).toBe("solid");
            expect(new SwiftDemo.Polygon({ name: "quad", vertexCount: 4 }).style).toBe("dashed");

            var metrics = new SwiftDemo.Polygon.Metrics({ perimeter: 3 });
            expect(metrics instanceof SwiftDemo.Polygon.Metrics).toBe(true);
            expect(metrics.perimeter).toBe(3);
            var computed = new SwiftDemo.Polygon({ name: "tri", vertexCount: 3 }).metrics(2);
            expect(computed instanceof SwiftDemo.Polygon.Metrics).toBe(true);
            expect(computed.perimeter).toBe(6);
        });

        it("gives an unbridged parent a frozen namespace", function () {
            // Measurement (an enum with associated values) is not bridged.
            expect(typeof SwiftDemo.Measurement).toBe("object");
            expect(Object.isFrozen(SwiftDemo.Measurement)).toBe(true);
            expect(Object.keys(SwiftDemo.Measurement)).toEqual(["Unit"]);
            expect(new SwiftDemo.Measurement.Unit("m").symbol).toBe("m");
        });
    });

    describe("collections and Foundation values", function () {
        it("copies arrays both ways", function () {
            expect(SwiftDemo.names(3)).toEqual(["n0", "n1", "n2"]);
            expect(SwiftDemo.total([1, 2, 3.5])).toBe(6.5);
            expect(SwiftDemo.mirrored([[1, 2], [3]])).toEqual([[2, 1], [3]]);
            expect(SwiftDemo.allFlavors()).toEqual(["vanilla", "chocolate"]);
            var center = SwiftDemo.centroid([new SwiftDemo.Point(0, 0), new SwiftDemo.Point(2, 2)]);
            expect(center instanceof SwiftDemo.Point).toBe(true);
            expect(center.x).toBe(1);
            var trackers = SwiftDemo.trackers([4, 5]);
            expect(trackers.length).toBe(2);
            expect(trackers[0] instanceof SwiftDemo.Tracker).toBe(true);
            expect(trackers[1].id).toBe(5);
        });

        it("copies [String: T] to and from plain objects", function () {
            expect(SwiftDemo.wordCounts(["a", "b", "a"])).toEqual({ a: 2, b: 1 });
            expect(SwiftDemo.lengths({ x: "abc", y: "" })).toEqual({ x: 3, y: 0 });
            var loader = new SwiftDemo.Loader();
            expect(loader.lookup({ a: 1 }, "a")).toBe(1);
            expect(loader.lookup({}, "z")).toBe(null);
        });

        it("checks collection elements", function () {
            expect(function () { SwiftDemo.total("x"); }).toThrowError(TypeError);
            expect(function () { SwiftDemo.total([1, "x"]); }).toThrowError(TypeError);
            expect(function () { SwiftDemo.mirrored([[1.5]]); }).toThrowError(TypeError);
            expect(function () { SwiftDemo.lengths({ x: 1 }); }).toThrowError(TypeError);
        });

        it("maps Date to JS Date", function () {
            var next = SwiftDemo.nextDay(new Date(0));
            expect(next instanceof Date).toBe(true);
            expect(next.getTime()).toBe(86400000);
            expect(function () { SwiftDemo.nextDay(0); }).toThrowError(TypeError);
        });

        it("maps URL to JS URL and accepts strings", function () {
            expect(SwiftDemo.host("https://example.com/x")).toBe("example.com");
            expect(SwiftDemo.host(new URL("https://a.example/"))).toBe("a.example");
            var resolved = SwiftDemo.resolve("c", "https://x.example/a/");
            expect(resolved instanceof URL).toBe(true);
            expect(resolved.href).toBe("https://x.example/a/c");
        });

        it("maps Data to Uint8Array and accepts any buffer", function () {
            expect(SwiftDemo.checksum(new Uint8Array([1, 2, 3]))).toBe(6);
            expect(SwiftDemo.checksum(new Uint8Array([1, 2, 3]).buffer)).toBe(6);
            expect(SwiftDemo.checksum(new Uint8Array([9, 1, 2]).subarray(1))).toBe(3);
            var bytes = SwiftDemo.ramp(4);
            expect(bytes instanceof Uint8Array).toBe(true);
            expect(Array.prototype.slice.call(bytes)).toEqual([0, 1, 2, 3]);
        });

        it("resolves async collections", function (done) {
            SwiftDemo.namesLater(2).then(function (names) {
                expect(names).toEqual(["n0", "n1"]);
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });
    });

    describe("async", function () {
        it("resolves async functions with their result", function (done) {
            var loader = new SwiftDemo.Loader();
            var waited = loader.wait(0.001);
            expect(waited instanceof Promise).toBe(true);
            waited.then(function (value) {
                expect(value).toBeUndefined();
                return SwiftDemo.delayedEcho("later", 0.001);
            }).then(function (text) {
                expect(text).toBe("later");
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("rejects with the Swift error", function (done) {
            SwiftDemo.delayedEcho("x", -1).then(function () {
                fail("expected a rejection");
                done();
            }, function (error) {
                expect(error.name).toBe("SwiftError");
                expect(error.swiftType).toBe("SwiftDemo.ShapeError");
                done();
            });
        });

        it("resolves to wrapped Swift objects", function (done) {
            SwiftDemo.makeTrackerLater(7).then(function (tracker) {
                expect(tracker instanceof SwiftDemo.Tracker).toBe(true);
                expect(tracker.id).toBe(7);
                expect(tracker.same()).toBe(tracker);
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("awaits actor members from outside the actor", function (done) {
            var counter = new SwiftDemo.Counter();
            expect(counter.label()).toBe("counter");
            counter.increment().then(function (value) {
                expect(value).toBe(1);
                return counter.value;
            }).then(function (value) {
                expect(value).toBe(1);
                return counter.step;
            }).then(function (step) {
                expect(step).toBe(1);
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("runs main-actor members on the main thread", function (done) {
            var palette = new SwiftDemo.Palette();
            expect(palette.stroke()).toBe(1);
            expect(palette.strokes).toBe(1);
            palette.strokeLater().then(function (strokes) {
                expect(strokes).toBe(2);
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("serves worker isolates their own objects", function (done) {
            var worker = new Worker("./swiftInteropWorker.js");
            worker.onmessage = function (event) {
                expect(event.data.greeting).toBe("Hello, worker");
                expect(event.data.palette).toMatch(/isolated to the main actor/);
                expect(event.data.trackerId).toBe(5);
                expect(event.data.echo).toBe("from worker");
                worker.terminate();
                done();
            };
            worker.onerror = function (event) {
                worker.terminate();
                fail("worker error: " + event.message);
                done();
            };
        });
    });

    describe("identity and lifetime", function () {
        it("returns the same wrapper for the same object", function () {
            expect(SwiftDemo.Polygon.shared).toBe(SwiftDemo.Polygon.shared);
            var tracker = new SwiftDemo.Tracker(1);
            expect(tracker.same()).toBe(tracker);
        });

        it("releases Swift objects when their wrappers are collected", function () {
            // Settle trackers left by earlier tests before taking the baseline.
            for (var settle = 0; settle < 3; settle++) {
                gc();
            }
            var baseline = SwiftDemo.Tracker.liveCount;
            (function () {
                for (var i = 0; i < 100; i++) {
                    new SwiftDemo.Tracker(i);
                }
            })();
            expect(SwiftDemo.Tracker.liveCount).toBe(baseline + 100);
            for (var attempt = 0; attempt < 5 && SwiftDemo.Tracker.liveCount > baseline; attempt++) {
                gc();
            }
            expect(SwiftDemo.Tracker.liveCount).toBe(baseline);
        });

        it("keeps objects alive while referenced", function () {
            var tracker = new SwiftDemo.Tracker(42);
            gc();
            gc();
            expect(tracker.id).toBe(42);
            expect(tracker.same()).toBe(tracker);
        });

        it("rewraps an object after its wrapper was collected", function () {
            (function () { SwiftDemo.Polygon.shared.name; })();
            gc();
            gc();
            expect(SwiftDemo.Polygon.shared.name).toBe("shared");
        });
    });
});
