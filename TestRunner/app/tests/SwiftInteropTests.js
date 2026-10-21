// End-to-end Swift interop: the SwiftDemo fixture
// (metadata-generator/TestFixtures/SwiftDemo) is linked into TestRunner with
// the thunks the metadata generator emits for it, and reached through ns:swift.
describe("ns:swift", function () {
    var swift = require("ns:swift");
    var SwiftDemo = swift.module("SwiftDemo");

    describe("modules", function () {
        it("exports a frozen loader", function () {
            expect(Object.isFrozen(swift)).toBe(true);
            expect(Object.keys(swift).sort()).toEqual(["abiVersion", "info", "module", "observe", "track"]);
            expect(swift.abiVersion).toBe(12);
        });

        it("returns one frozen namespace per module", function () {
            expect(swift.module("SwiftDemo")).toBe(SwiftDemo);
            expect(Object.isFrozen(SwiftDemo)).toBe(true);
        });

        it("describes the linked module", function () {
            var info = swift.info("SwiftDemo");
            expect(info.name).toBe("SwiftDemo");
            expect(info.abiVersion).toBe(12);
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
            expect(SwiftDemo.Loader.prototype.transform).toBeUndefined();
            expect(SwiftDemo.Loader.prototype.withCompletion).toBeUndefined();
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
            // Job (whose case carries a closure) is not bridged.
            expect(typeof SwiftDemo.Job).toBe("object");
            expect(Object.isFrozen(SwiftDemo.Job)).toBe(true);
            expect(Object.keys(SwiftDemo.Job)).toEqual(["Ticket"]);
            expect(new SwiftDemo.Job.Ticket(4).id).toBe(4);
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
                expect(event.data.callback).toBe("hi worker");
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

    describe("enums with associated values", function () {
        it("returns cases as objects naming the case", function () {
            expect(SwiftDemo.measure(2, 3)).toEqual({ case: "area", width: 2, height: 3 });
            expect(SwiftDemo.measure(2, null)).toEqual({ case: "length", value: 2 });
            expect(SwiftDemo.measure(0, null)).toEqual({ case: "none" });
            expect(SwiftDemo.measurements()).toEqual([
                { case: "length", value: 1 },
                { case: "area", width: 2, height: 3 },
                { case: "none" },
            ]);
        });

        it("accepts case objects", function () {
            expect(SwiftDemo.area({ case: "area", width: 2, height: 4 })).toBe(8);
            expect(SwiftDemo.area({ case: "none" })).toBe(0);
            expect(SwiftDemo.explain({ case: "tooManySides", count: 5, limit: 4 })).toBe("5 > 4");
            expect(SwiftDemo.explain({ case: "invalidSide", value: 1.5 })).toBe("invalid side 1.5");
            expect(SwiftDemo.Measurement.isNone({ case: "none" })).toBe(true);
            expect(SwiftDemo.Measurement.isNone({ case: "length", value: 1 })).toBe(false);
        });

        it("refuses unknown cases and mistyped values", function () {
            expect(function () { SwiftDemo.area({ case: "circle" }); })
                .toThrowError(TypeError, /case of Measurement/);
            expect(function () { SwiftDemo.area({ case: "area", width: "2", height: 1 }); })
                .toThrowError(TypeError);
            expect(function () { SwiftDemo.area("area"); }).toThrowError(TypeError);
        });

        it("round-trips recursive enums", function () {
            var formula = {
                case: "sum",
                0: { case: "number", value: 1 },
                1: { case: "negate", value: { case: "number", value: 4 } },
            };
            expect(SwiftDemo.Formula.value(formula)).toBe(-3);
            expect(SwiftDemo.simplify(formula)).toEqual({ case: "number", value: -3 });
        });

        it("carries objects, structs, enums, optionals and arrays", function () {
            var tracker = new SwiftDemo.Tracker(3);
            expect(SwiftDemo.echo({ case: "tracker", value: tracker }).value).toBe(tracker);
            var point = SwiftDemo.echo({ case: "point", value: new SwiftDemo.Point({ x: 1, y: 2 }) }).value;
            expect(point instanceof SwiftDemo.Point).toBe(true);
            expect(point.x).toBe(1);
            expect(SwiftDemo.echo({ case: "flavor", value: "chocolate" }))
                .toEqual({ case: "flavor", value: "chocolate" });
            expect(SwiftDemo.echo({ case: "maybe", value: null })).toEqual({ case: "maybe", value: null });
            expect(SwiftDemo.echo({ case: "maybe" })).toEqual({ case: "maybe", value: null });
            expect(SwiftDemo.echo({ case: "maybe", value: 7 })).toEqual({ case: "maybe", value: 7 });
            expect(SwiftDemo.echo({ case: "names", value: ["a", "b"] }))
                .toEqual({ case: "names", value: ["a", "b"] });
        });

        it("resolves async results and passes cases to closures", function (done) {
            var received;
            SwiftDemo.onMeasure(function (measurement) { received = measurement; });
            expect(received).toEqual({ case: "area", width: 1, height: 2 });
            SwiftDemo.measureLater(5).then(function (measurement) {
                expect(measurement).toEqual({ case: "length", value: 5 });
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });
    });

    describe("units", function () {
        // SwiftDemo and SwiftDemoKit are generated as one unit.
        var Kit = swift.module("SwiftDemoKit");

        it("gives each module of a unit its own namespace", function () {
            expect(Kit).not.toBe(SwiftDemo);
            expect(typeof Kit.Money).toBe("function");
            expect(SwiftDemo.Money).toBeUndefined();
            expect(require("ns:swift/SwiftDemoKit")).toBe(Kit);
            expect(swift.info("SwiftDemoKit").unit).toBe("SwiftDemo");
        });

        it("passes another module's types", function () {
            var wallet = SwiftDemo.starterWallet("ada");
            expect(wallet instanceof Kit.Wallet).toBe(true);
            expect(wallet.balance.amount).toBe(5);
            expect(SwiftDemo.flip("penny")).toBe("dime");
            var sum = SwiftDemo.sum([new Kit.Money(1, "EUR"), new Kit.Money(2, "EUR")]);
            expect(sum instanceof Kit.Money).toBe(true);
            expect(sum.amount).toBe(3);
            expect(Kit.formatted(sum)).toBe("3 EUR");
        });

        it("installs extensions on the extended type", function () {
            expect(new Kit.Money(0, "EUR").isZero).toBe(true);
            expect(new Kit.Money(4, "EUR").doubled().amount).toBe(8);
            expect(SwiftDemo.starterWallet("ada").summary()).toBe("ada: 5 EUR");
        });
    });

    describe("generic types", function () {
        var Kit = swift.module("SwiftDemoKit");

        it("gives every instantiation of a generic type one JS class", function () {
            var pair = new Kit.Pair(1, "one");
            var score = SwiftDemo.makeScore("ada", 3);
            expect(pair instanceof Kit.Pair).toBe(true);
            expect(score instanceof Kit.Pair).toBe(true);
            expect(pair.first).toBe(1);
            expect(pair.second).toBe("one");
            expect(score.first).toBe("ada");
            expect(score.second).toBe(3);
        });

        it("picks the instantiation from the constructor's arguments", function () {
            expect(SwiftDemo.describe(new Kit.Pair(2, "two"))).toBe("2:two");
            expect(function () { SwiftDemo.describe(new Kit.Pair("two", 2)); })
                .toThrowError(TypeError);
            var swapped = new Kit.Pair(2, "two").swapped();
            expect(swapped.first).toBe("two");
            expect(swapped.second).toBe(2);
            expect(swapped.swapped().first).toBe(2);
        });

        it("calls members of the receiver's own instantiation", function () {
            var count = SwiftDemo.countBox(4);
            var money = SwiftDemo.boxed(new Kit.Money(7, "EUR"));
            expect(count.value).toBe(4);
            expect(money.value.amount).toBe(7);
            count.value = 5;
            expect(count.value).toBe(5);
            expect(count.replaced(9).value).toBe(9);
            expect(function () { count.value = "x"; }).toThrowError(TypeError);
            expect(new Kit.Box(new Kit.Money(1, "EUR")).value.amount).toBe(1);
        });

        it("bridges generic enums with associated values", function () {
            expect(SwiftDemo.settle(3)).toEqual({ case: "done", value: 3 });
            expect(SwiftDemo.settle(-1)).toEqual({ case: "failed", reason: "negative" });
        });
    });

    describe("protocols", function () {
        function jsGreeting(name) {
            return {
                name: name,
                punctuation: "?",
                greet: function (other) { return "hey " + other + " from " + this.name; },
                reset: function () { this.punctuation = "."; },
            };
        }

        it("passes JS objects implementing a protocol", function () {
            expect(SwiftDemo.introduce(jsGreeting("js"), "ada")).toBe("hey ada from js?");
        });

        it("assigns properties through the implementation", function () {
            var greeting = jsGreeting("js");
            SwiftDemo.excite(greeting);
            expect(greeting.punctuation).toBe("!");
        });

        it("returns a JS implementation as the object it was given", function () {
            var greeting = jsGreeting("js");
            expect(SwiftDemo.same(greeting)).toBe(greeting);
        });

        it("passes Swift conformers as their own class", function () {
            var formal = SwiftDemo.makeGreeting("ada");
            expect(formal instanceof SwiftDemo.FormalGreeting).toBe(true);
            expect(SwiftDemo.introduce(formal, "bo")).toBe("Good day, bo, from ada.");
            expect(SwiftDemo.same(formal)).toBe(formal);
            var scorer = SwiftDemo.makeScorer();
            expect(scorer instanceof SwiftDemo.DoublingScorer).toBe(true);
            expect(SwiftDemo.scoreAll(scorer, [1, 2])).toEqual([2, 4]);
        });

        it("throws a JS implementation's exception from the call", function () {
            var scorer = {
                score: function (value) {
                    if (value > 1) {
                        throw new Error("too big");
                    }
                    return value;
                },
            };
            expect(SwiftDemo.scoreAll(scorer, [1])).toEqual([1]);
            expect(function () { SwiftDemo.scoreAll(scorer, [1, 2]); }).toThrowError("too big");
        });

        it("implements refined protocols' requirements too", function () {
            var scorer = { rank: 3, score: function (value) { return value + 10; } };
            expect(SwiftDemo.topRank(scorer)).toBe("3:11");
            scorer.rank = null;
            expect(SwiftDemo.topRank(scorer)).toBe("-1:11");
        });

        it("refuses incomplete implementations", function () {
            expect(function () {
                SwiftDemo.introduce({ name: "x", greet: function () { return ""; } }, "y");
            }).toThrowError(TypeError, /missing .*punctuation.*reset|missing .*reset.*punctuation/);
        });

        it("keeps implementations Swift holds", function () {
            var holder = new SwiftDemo.GreetingHolder();
            holder.greeting = jsGreeting("held");
            gc();
            expect(holder.greet("you")).toBe("hey you from held");
            expect(holder.greeting.name).toBe("held");
            holder.greeting = null;
            expect(holder.greet("you")).toBeNull();
        });

        it("runs requirements called from other threads on the JS thread", function (done) {
            var greeting = jsGreeting("js");
            greeting.greet = function (other) { return other + ":" + NSThread.isMainThread; };
            SwiftDemo.greetInBackground(greeting).then(function (text) {
                expect(text).toBe("background:true");
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });
    });

    describe("observation", function () {
        it("calls onChange once when a property read is about to change", function () {
            var thermostat = new SwiftDemo.Thermostat();
            var changes = 0;
            var seen;
            swift.track(function () { seen = thermostat.celsius; }, function () { changes++; });
            expect(seen).toBe(20);
            thermostat.label = "office";
            expect(changes).toBe(0);
            thermostat.celsius = 21;
            expect(changes).toBe(1);
            thermostat.warm(1);
            expect(changes).toBe(1);
        });

        it("keeps observing after each change, from any thread", function (done) {
            var thermostat = new SwiftDemo.Thermostat();
            var values = [];
            var stop = swift.observe(function () { return thermostat.celsius; }, function () {
                values.push(thermostat.celsius);
                if (values.length === 1) {
                    thermostat.warmLater(2);
                    return;
                }
                stop();
                // The background thread may not have stored the value it reported yet.
                (function settle(tries) {
                    if (thermostat.celsius !== 23 && tries > 0) {
                        setTimeout(function () { settle(tries - 1); }, 10);
                        return;
                    }
                    expect([values[0], thermostat.celsius]).toEqual([21, 23]);
                    done();
                })(100);
            });
            thermostat.warm(1);
        });

        it("throws what read throws", function () {
            expect(function () {
                swift.track(function () { throw new Error("nope"); }, function () {});
            }).toThrowError("nope");
        });
    });

    describe("asynchronous sequences", function () {
        function settle(promise, done) {
            promise.then(done, function (error) {
                fail(error);
                done();
            });
        }

        it("iterates AsyncStream results with for await", function (done) {
            settle((async function () {
                var values = [];
                for await (var value of SwiftDemo.countUp(3)) {
                    values.push(value);
                }
                expect(values).toEqual([1, 2, 3]);
            })(), done);
        });

        it("rejects with the sequence's error", function (done) {
            settle((async function () {
                var values = [];
                try {
                    for await (var value of SwiftDemo.countDown(3, 1)) {
                        values.push(value);
                    }
                    fail("expected the sequence to throw");
                } catch (error) {
                    expect(error.name).toBe("SwiftError");
                    expect(error.swiftType).toBe("SwiftDemo.CountdownError");
                }
                expect(values).toEqual([3, 2]);
            })(), done);
        });

        it("iterates opaque sequences and collection elements", function (done) {
            settle((async function () {
                var letters = [];
                for await (var letter of SwiftDemo.letters("abc")) {
                    letters.push(letter);
                }
                expect(letters).toEqual(["a", "b", "c"]);
                var pages = [];
                for await (var page of SwiftDemo.pages(2)) {
                    pages.push(page);
                }
                expect(pages).toEqual([["page 0", "item"], ["page 1", "item"]]);
            })(), done);
        });

        it("runs one step at a time and stays done at the end", function (done) {
            var iterator = SwiftDemo.countUp(2);
            settle(Promise.all([iterator.next(), iterator.next(), iterator.next(), iterator.next()])
                .then(function (results) {
                    expect(results.map(function (r) { return r.done; })).toEqual([false, false, true, true]);
                    expect(results[0].value).toBe(1);
                    expect(results[1].value).toBe(2);
                }), done);
        });
    });

    describe("SwiftUI views", function () {
        it("hosts a view in a UIHostingController", function () {
            var badge = new SwiftDemo.Badge("Inbox", 3);
            var controller = badge.hostingController();
            expect(controller instanceof UIViewController).toBe(true);
            expect(controller.view instanceof UIView).toBe(true);
            var size = controller.view.sizeThatFits(CGSizeMake(1000, 1000));
            expect(size.width).toBeGreaterThan(0);
            expect(size.height).toBeGreaterThan(0);
            // The struct is copied in: later changes do not reach the host.
            badge.count = 4;
            expect(badge.hostingController()).not.toBe(controller);
        });
    });

    describe("Objective-C objects", function () {
        it("passes NativeScript's Objective-C wrappers", function () {
            var view = UIView.new();
            view.tag = 7;
            expect(SwiftDemo.describe(view)).toBe("UIView 7");
            var label = UILabel.new();
            label.tag = 3;
            expect(SwiftDemo.tags([view, label])).toEqual([7, 3]);
        });

        it("returns objects with their Objective-C identity", function () {
            var view = UIView.new();
            expect(SwiftDemo.firstSubview(view)).toBeNull();
            var child = UIView.new();
            view.addSubview(child);
            expect(SwiftDemo.firstSubview(view)).toBe(child);

            var label = SwiftDemo.makeLabel("hello");
            expect(label instanceof UILabel).toBe(true);
            expect(label.text).toBe("hello");
        });

        it("round-trips Swift classes that are Objective-C visible", function (done) {
            var note = SwiftDemo.makeNote("memo");
            expect(note instanceof NSObject).toBe(true);
            expect(SwiftDemo.text(note)).toBe("memo");
            SwiftDemo.noteLater("later").then(function (later) {
                expect(SwiftDemo.text(later)).toBe("later");
                done();
            }, function (error) {
                fail(error);
                done();
            });
        });

        it("refuses other values", function () {
            expect(function () { SwiftDemo.describe({}); }).toThrowError(TypeError);
            expect(function () { SwiftDemo.describe(NSObject.new()); }).toThrowError(TypeError);
            expect(function () { SwiftDemo.text(UIView.new()); }).toThrowError(TypeError);
        });
    });

    describe("inout parameters", function () {
        it("writes the final value back to the reference object", function () {
            var counter = { value: 41 };
            SwiftDemo.bump(counter);
            expect(counter.value).toBe(42);

            var words = { value: ["a"] };
            SwiftDemo.append("b", words);
            expect(words.value).toEqual(["a", "b"]);

            var name = { value: "x" };
            SwiftDemo.clear(name);
            expect(name.value).toBeNull();
        });

        it("writes back structs and objects", function () {
            var point = new SwiftDemo.Point(1, 2);
            var ref = { value: point };
            new SwiftDemo.Loader().update(ref);
            expect(ref.value.x).toBe(2);
            // Value semantics: the struct passed in is a separate copy.
            expect(point.x).toBe(1);

            var first = new SwiftDemo.Tracker(1);
            var second = new SwiftDemo.Tracker(2);
            var a = { value: first };
            var b = { value: second };
            SwiftDemo.swapTrackers(a, b);
            expect(a.value).toBe(second);
            expect(b.value).toBe(first);
        });

        it("leaves the reference unchanged when the call throws", function () {
            var even = { value: 8 };
            SwiftDemo.halve(even);
            expect(even.value).toBe(4);
            var odd = { value: 3 };
            expect(function () { SwiftDemo.halve(odd); }).toThrowError(/invalidSide/);
            expect(odd.value).toBe(3);
        });

        it("requires a reference object", function () {
            expect(function () { SwiftDemo.bump(1); }).toThrowError(TypeError, /inout Int/);
            expect(function () { SwiftDemo.bump({ value: "1" }); }).toThrowError(TypeError);
        });
    });

    describe("generic functions", function () {
        it("picks the instantiation the arguments call for", function () {
            expect(SwiftDemo.largest([3, 9, 2])).toBe(9);
            expect(SwiftDemo.largest(["b", "c", "a"])).toBe("c");
            expect(SwiftDemo.repeated("x", 2)).toEqual(["x", "x"]);
            expect(SwiftDemo.repeated(true, 1)).toEqual([true]);
            expect(SwiftDemo.repeated(1.5, 2)).toEqual([1.5, 1.5]);
            expect(new SwiftDemo.Loader().first(["a", "b"])).toBe("a");
            expect(new SwiftDemo.Loader().first([4])).toBe(4);
        });

        it("instantiates with integers, protocols and superclasses", function () {
            expect(SwiftDemo.popCount(7)).toBe(3);
            expect(SwiftDemo.zero()).toBe(0);
            var greeting = {
                name: "js",
                punctuation: "!",
                greet: function (other) { return "hi " + other; },
                reset: function () {}
            };
            expect(SwiftDemo.greetTwice(greeting, "ada")).toBe("hi ada hi ada");
            expect(SwiftDemo.greetTwice(SwiftDemo.makeGreeting("swift"), "ada"))
                .toBe("Good day, ada, from swift Good day, ada, from swift");
            var view = UILabel.new();
            view.tag = 5;
            expect(SwiftDemo.viewTag(view)).toBe(5);
        });

        it("throws when the arguments do not decide the instantiation", function () {
            expect(function () { SwiftDemo.largest([]); })
                .toThrowError(TypeError, /Ambiguous call to largest/);
            expect(function () { SwiftDemo.largest([true]); })
                .toThrowError(TypeError, /No overload of largest/);
        });

        it("instantiates with the arguments of the unit's generic types", function () {
            var Kit = swift.module("SwiftDemoKit");
            expect(SwiftDemo.unbox(SwiftDemo.countBox(3))).toBe(3);
            expect(SwiftDemo.unbox(SwiftDemo.boxed(new Kit.Money(2, "EUR"))).amount).toBe(2);
            expect(SwiftDemo.unbox(Kit.Box.sample)).toBe(7);
            expect(SwiftDemo.firstOf(SwiftDemo.makeScore("ada", 3))).toBe("ada");
            expect(SwiftDemo.firstOf(new Kit.Pair(2, "two"))).toBe(2);
        });

        it("leaves functions without known stand-ins out", function () {
            expect(SwiftDemo.decodeJSON).toBeUndefined();
            expect(SwiftDemo.firstElement).toBeUndefined();
            expect(SwiftDemo.joined).toBeUndefined();
        });
    });

    describe("closures", function () {
        it("calls JS functions passed for closures while the call runs", function () {
            var ticks = [];
            SwiftDemo.countdown(3, function (value, last) {
                ticks.push([value, last]);
            });
            expect(ticks).toEqual([[3, false], [2, false], [1, false], [0, true]]);

            var loader = new SwiftDemo.Loader();
            var seen = [];
            loader.each(function (value) { seen.push(value); });
            expect(seen).toEqual([]);
        });

        it("throws a callback's exception from the call and skips later calls", function () {
            var calls = 0;
            expect(function () {
                SwiftDemo.countdown(5, function () {
                    calls++;
                    throw new Error("stop");
                });
            }).toThrowError("stop");
            expect(calls).toBe(1);
        });

        it("refuses values that are not functions", function () {
            expect(function () { SwiftDemo.countdown(1, 5); })
                .toThrowError(TypeError, /countdown.*\(Int, Bool\) -> Void/);
        });

        it("returns JS functions' results to Swift", function () {
            expect(SwiftDemo.transform([1, 2, 3], function (n) { return "#" + n; }))
                .toEqual(["#1", "#2", "#3"]);
            expect(SwiftDemo.sortedNames(["b", "c", "a"], function (x, y) { return x > y; }))
                .toEqual(["c", "b", "a"]);
            expect(SwiftDemo.lookup("seven", function (key) { return key.length; })).toBe(5);
            expect(SwiftDemo.lookup("none", function () { return null; })).toBe(-1);
        });

        it("throws when a function's result does not convert", function () {
            expect(function () { SwiftDemo.transform([1], function () { return 5; }); })
                .toThrowError(TypeError, /transform/);
        });

        it("throws a JS exception from a throwing closure into Swift and back", function () {
            expect(SwiftDemo.firstMatch([1, 4, 9], function (n) { return n > 3; })).toBe(4);
            expect(SwiftDemo.firstMatch([1], function () { return false; })).toBeNull();
            var calls = 0;
            expect(function () {
                SwiftDemo.firstMatch([1, 2, 3], function () {
                    calls++;
                    throw new Error("no match");
                });
            }).toThrowError("no match");
            expect(calls).toBe(1);
        });

        it("waits for functions called from other threads", function (done) {
            SwiftDemo.computeInBackground(function () {
                expect(NSThread.isMainThread).toBe(true);
                return 21;
            }).then(function (value) {
                expect(value).toBe(42);
                done();
            }, done.fail);
        });

        it("runs closures called from other threads on the JS thread", function (done) {
            SwiftDemo.greetLater("ns", function (greeting) {
                expect(greeting).toBe("hi ns");
                expect(NSThread.isMainThread).toBe(true);
                SwiftDemo.greetLater(null, function (nothing) {
                    expect(nothing).toBeNull();
                    done();
                });
            });
        });

        it("keeps escaping closures until Swift releases them", function (done) {
            var notifier = new SwiftDemo.Notifier();
            var received = [];
            notifier.subscribe(function (message) {
                received.push(message);
                if (message === "later") {
                    expect(received).toEqual(["now", "later"]);
                    notifier.clear();
                    expect(notifier.count).toBe(0);
                    done();
                }
            });
            gc();
            expect(notifier.count).toBe(1);
            notifier.publish("now");
            expect(received).toEqual(["now"]);
            notifier.publishLater("later");
        });

        it("releases the JS function once Swift drops the closure", function (done) {
            var notifier = new SwiftDemo.Notifier();
            var handler = function () {};
            var weakHandler = new WeakRef(handler);
            notifier.subscribe(handler);
            handler = null;
            setTimeout(function () {
                gc();
                expect(!!weakHandler.deref()).toBe(true);
                notifier.clear();
                setTimeout(function () {
                    gc();
                    expect(!!weakHandler.deref()).toBe(false);
                    done();
                }, 0);
            }, 0);
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
