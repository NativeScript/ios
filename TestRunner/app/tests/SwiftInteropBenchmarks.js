// The same API called through NativeScript's Objective-C metadata path
// (TestFixtures' TNSBenchmark) and through Swift thunks (ns:swift,
// SwiftDemo's Benchmark). Every case consumes its result in JS, as an app
// would, so lazily wrapped Objective-C collections pay for the elements read.
// Logs `swift-bench` lines and writes them to Documents/swift-bench.txt;
// asserts nothing about timings, which vary by device and build.
describe("ns:swift benchmarks", function () {
    var SwiftDemo = require("ns:swift/SwiftDemo");
    var Benchmark = SwiftDemo.Benchmark;
    var lines = [];
    var rounds = 3;

    // Median per-iteration time over `rounds`, in microseconds.
    function measure(iterations, body) {
        for (var warm = 0; warm < Math.min(iterations, 200); warm++) {
            body();
        }
        var times = [];
        for (var round = 0; round < rounds; round++) {
            var start = performance.now();
            for (var i = 0; i < iterations; i++) {
                body();
            }
            times.push(((performance.now() - start) * 1000) / iterations);
        }
        times.sort(function (a, b) { return a - b; });
        return times[Math.floor(rounds / 2)];
    }

    function record(name, objc, swift) {
        var line = "swift-bench " + name + ": objc " + objc.toFixed(2) + " us, swift " +
            swift.toFixed(2) + " us (" + (swift / objc).toFixed(2) + "x)";
        console.log(line);
        lines.push(line);
    }

    function compare(name, iterations, objc, swift) {
        record(name, measure(iterations, objc), measure(iterations, swift));
    }

    function write() {
        var documents = NSSearchPathForDirectoriesInDomains(9 /* Documents */, 1 /* user */, true).objectAtIndex(0);
        NSString.stringWithString(lines.join("\n") + "\n")
            .writeToFileAtomicallyEncodingError(documents + "/swift-bench.txt", true, 4 /* UTF-8 */, null);
    }

    var longText = new Array(1025).join("0123456789");
    var numbers = [];
    for (var n = 0; n < 1000; n++) {
        numbers.push(n);
    }
    var dictionary = {};
    for (var k = 0; k < 10; k++) {
        dictionary["key" + k] = k;
    }
    var keys = Object.keys(dictionary);

    it("measures synchronous calls", function () {
        var objcObject = TNSBenchmark.new();
        var swiftObject = new Benchmark();

        compare("call: no arguments", 20000,
            function () { TNSBenchmark.noop(); },
            function () { Benchmark.noop(); });
        compare("call: int -> int", 20000,
            function () { return TNSBenchmark.echoInt(5); },
            function () { return Benchmark.echoInt(5); });
        compare("call: 3 doubles -> double", 20000,
            function () { return TNSBenchmark.combineTimesPlus(1.5, 2, 3); },
            function () { return Benchmark.combine(1.5, 2, 3); });
        compare("call: bool -> bool", 20000,
            function () { return TNSBenchmark.negate(true); },
            function () { return Benchmark.negate(true); });
        compare("string: short round trip", 20000,
            function () { return TNSBenchmark.echoString("benchmark"); },
            function () { return Benchmark.echoString("benchmark"); });
        compare("string: 10 KB in", 2000,
            function () { return TNSBenchmark.lengthOf(longText); },
            function () { return Benchmark.length(longText); });
        compare("string: 10 KB round trip", 2000,
            function () { return TNSBenchmark.echoString(longText).length; },
            function () { return Benchmark.echoString(longText).length; });
        compare("object: construct", 10000,
            function () { return TNSBenchmark.new(); },
            function () { return new Benchmark(); });
        compare("object: instance method", 20000,
            function () { return objcObject.increment(); },
            function () { return swiftObject.increment(); });
        compare("object: property read", 20000,
            function () { return objcObject.counter; },
            function () { return swiftObject.counter; });
        compare("object: property write", 20000,
            function () { objcObject.counter = 3; },
            function () { swiftObject.counter = 3; });
        compare("array: 1000 ints in", 500,
            function () { return TNSBenchmark.sum(numbers); },
            function () { return Benchmark.sum(numbers); });
        compare("array: 1000 ints out, all read", 500,
            function () {
                var values = TNSBenchmark.makeArray(1000);
                var total = 0;
                for (var i = 0, count = values.count; i < count; i++) {
                    total += values.objectAtIndex(i);
                }
                return total;
            },
            function () {
                var values = Benchmark.makeArray(1000);
                var total = 0;
                for (var i = 0; i < values.length; i++) {
                    total += values[i];
                }
                return total;
            });
        compare("dictionary: 10 keys in", 2000,
            function () { return TNSBenchmark.sumValues(dictionary); },
            function () { return Benchmark.sumValues(dictionary); });
        compare("dictionary: 10 keys out, all read", 2000,
            function () {
                var result = TNSBenchmark.makeDictionary(10);
                var total = 0;
                for (var i = 0; i < keys.length; i++) {
                    total += result[keys[i]];
                }
                return total;
            },
            function () {
                var result = Benchmark.makeDictionary(10);
                var total = 0;
                for (var i = 0; i < keys.length; i++) {
                    total += result[keys[i]];
                }
                return total;
            });
        var megabyte = new Uint8Array(1024 * 1024);
        for (var b = 0; b < megabyte.length; b++) {
            megabyte[b] = b & 255;
        }
        compare("data: 1 MB in", 50,
            function () { return TNSBenchmark.checksum(megabyte.buffer); },
            function () { return Benchmark.checksum(megabyte); });
        compare("data: 1 MB out as bytes", 50,
            function () {
                var bytes = new Uint8Array(interop.bufferFromData(TNSBenchmark.makeData(1024 * 1024)));
                return bytes.length + bytes[0] + bytes[bytes.length - 1];
            },
            function () {
                var bytes = Benchmark.makeData(1024 * 1024);
                return bytes.length + bytes[0] + bytes[bytes.length - 1];
            });
        compare("struct: CGPoint in and out", 10000,
            function () {
                var point = TNSBenchmark.midpointOfWith({ x: 0, y: 0 }, { x: 4, y: 2 });
                return point.x + point.y;
            },
            function () {
                var point = Benchmark.midpoint({ x: 0, y: 0 }, { x: 4, y: 2 });
                return point.x + point.y;
            });

        var objcBlock = function (i) { return i; };
        var swiftClosure = function (i) { return i; };
        compare("callback: native calls JS 100 times", 500,
            function () { return TNSBenchmark.callBlockTimes(objcBlock, 100); },
            function () { return Benchmark.callClosure(swiftClosure, 100); });

        var ObjCDelegate = NSObject.extend({
            valueForIndex: function (index) { return index; }
        }, { protocols: [TNSBenchmarkDelegate] });
        var objcDelegate = ObjCDelegate.new();
        var swiftDelegate = { value: function (index) { return index; } };
        compare("delegate: native calls JS object 100 times", 500,
            function () { return TNSBenchmark.callDelegateTimes(objcDelegate, 100); },
            function () { return Benchmark.callDelegate(swiftDelegate, 100); });

        compare("error: thrown and caught", 5000,
            function () {
                try {
                    TNSBenchmark.failWithError();
                } catch (error) {
                    return error;
                }
            },
            function () {
                try {
                    Benchmark.fail();
                } catch (error) {
                    return error;
                }
            });
        compare("batch: build, filter, sort 1000 records, all read", 100,
            function () {
                var records = TNSBenchmark.topRecordsMinimumScore(1000, 50);
                var total = 0;
                for (var i = 0, count = records.count; i < count; i++) {
                    var item = records.objectAtIndex(i);
                    total += item.name.length + item.score + item.rank;
                }
                return total;
            },
            function () {
                var records = Benchmark.topRecords(1000, 50);
                var total = 0;
                for (var i = 0; i < records.length; i++) {
                    var item = records[i];
                    total += item.name.length + item.score + item.rank;
                }
                return total;
            });
        expect(lines.length).toBeGreaterThan(0);
    });

    it("measures async calls", function (done) {
        var iterations = 300;
        function sequential(call) {
            var start = performance.now();
            var i = 0;
            function next() {
                if (i++ >= iterations) {
                    return Promise.resolve(((performance.now() - start) * 1000) / iterations);
                }
                return call().then(next);
            }
            return next();
        }
        sequential(function () {
            return new Promise(function (resolve) { TNSBenchmark.echoLaterCompletion(5, resolve); });
        }).then(function (objc) {
            return sequential(function () { return Benchmark.echoLater(5); }).then(function (swift) {
                record("async: call and await, sequential", objc, swift);
                write();
                done();
            });
        }, done.fail);
    });
});
