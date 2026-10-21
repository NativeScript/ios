// Per-call cost of the same operations through the Objective-C/C metadata
// path and the Swift thunk path (ns:swift). Logs `swift-bench` lines and
// writes them to Documents/swift-bench.txt; asserts nothing, since timings
// vary.
describe("ns:swift benchmarks", function () {
    var SwiftDemo = require("ns:swift/SwiftDemo");
    var iterations = 50000;

    function measure(body) {
        for (var warm = 0; warm < 1000; warm++) {
            body();
        }
        var start = performance.now();
        for (var i = 0; i < iterations; i++) {
            body();
        }
        return ((performance.now() - start) * 1e6) / iterations;
    }

    var lines = [];
    function compare(name, objc, swift) {
        var objcNs = measure(objc);
        var swiftNs = measure(swift);
        var line = "swift-bench " + name + ": objc " + objcNs.toFixed(0) + " ns, swift " +
            swiftNs.toFixed(0) + " ns (" + (swiftNs / objcNs).toFixed(2) + "x)";
        console.log(line);
        lines.push(line);
    }

    it("logs per-call costs", function () {
        var primitives = TNSPrimitives.new();
        var bench = new SwiftDemo.Bench();
        compare("function(int) -> int", function () { functionWithInt(5); },
            function () { SwiftDemo.echoInt(5); });
        compare("class method(int) -> int", function () { TNSPrimitives.methodWithInt(5); },
            function () { SwiftDemo.Bench.echo(5); });
        compare("instance method(int) -> int", function () { primitives.methodWithInt(5); },
            function () { bench.echo(5); });
        compare("string round trip", function () { NSString.stringWithString("benchmark"); },
            function () { SwiftDemo.echoString("benchmark"); });
        compare("construct object", function () { TNSPrimitives.new(); },
            function () { new SwiftDemo.Bench(); });
        compare("read property", function () { return primitives.hash; },
            function () { return bench.value; });
        var documents = NSSearchPathForDirectoriesInDomains(9 /* Documents */, 1 /* user */, true).objectAtIndex(0);
        NSString.stringWithString(lines.join("\n") + "\n")
            .writeToFileAtomicallyEncodingError(documents + "/swift-bench.txt", true, 4 /* UTF-8 */, null);
        expect(lines.length).toBe(6);
    });
});
