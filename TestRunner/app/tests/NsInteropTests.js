// The global `interop` is a compat layer over ns:interop, ns:interop/ios and
// ns:runtime. The export sets are public API, declared in types/ns-interop.d.ts,
// types/ns-interop-ios.d.ts and types/ns-runtime.d.ts and documented in
// docs/ns-builtin-modules.md — all of them must change together.

var C_TYPES = ["bool", "double", "float", "int16", "int32", "int64", "int8", "slong",
    "uint16", "uint32", "uint64", "uint8", "ulong", "void"];
var APPLE_TYPES = ["class", "id", "noop", "protocol", "selector", "unichar"];
var GLOBAL_KEYS = ["FunctionReference", "Pointer", "Reference", "adopt", "alloc",
    "bufferFromData", "escapeException", "free", "getExternalSize", "handleof",
    "setExternalSize", "sizeof", "stringFromCString", "types"];

describe("ns:interop", function () {
    var nsInterop = require("ns:interop");

    it("exposes exactly the declared surface", function () {
        expect(Object.keys(nsInterop).sort()).toEqual(["FunctionReference", "Pointer",
            "Reference", "alloc", "free", "handleof", "sizeof", "stringFromCString", "types"]);
        expect(Object.keys(nsInterop.types).sort()).toEqual(C_TYPES);
    });

    it("freezes its exports and its types", function () {
        expect(Object.isFrozen(nsInterop)).toBe(true);
        expect(Object.isFrozen(nsInterop.types)).toBe(true);
    });

    it("is a singleton per realm", function () {
        expect(require("ns:interop")).toBe(nsInterop);
    });

    it("hands out working natives", function () {
        var types = nsInterop.types;
        expect(nsInterop.sizeof(types.int32)).toBe(4);
        expect(nsInterop.sizeof(types.double)).toBe(8);

        var ref = new nsInterop.Reference(types.int32, 42);
        expect(ref.value).toBe(42);
        expect(nsInterop.handleof(ref) instanceof nsInterop.Pointer).toBe(true);

        var pointer = nsInterop.alloc(4);
        expect(pointer instanceof nsInterop.Pointer).toBe(true);
        var view = new nsInterop.Reference(types.int32, pointer);
        view.value = 7;
        expect(view.value).toBe(7);
    });

    it("reads a C string through its own types", function () {
        var cString = new nsInterop.Reference(nsInterop.types.uint8, nsInterop.alloc(4));
        cString[0] = 104;
        cString[1] = 105;
        cString[2] = 0;
        expect(nsInterop.stringFromCString(cString)).toBe("hi");
    });
});

describe("ns:interop/ios", function () {
    var nsInteropIos = require("ns:interop/ios");

    it("exposes exactly the declared surface", function () {
        expect(Object.keys(nsInteropIos).sort()).toEqual(["adopt", "bufferFromData", "types"]);
        expect(Object.keys(nsInteropIos.types).sort()).toEqual(APPLE_TYPES);
    });

    it("freezes its exports and its types", function () {
        expect(Object.isFrozen(nsInteropIos)).toBe(true);
        expect(Object.isFrozen(nsInteropIos.types)).toBe(true);
    });

    it("is the module behind every Apple spelling", function () {
        expect(require("ns:interop/ios")).toBe(nsInteropIos);
        expect(require("ns:interop/visionos")).toBe(nsInteropIos);
        expect(require("ns:interop/macos")).toBe(nsInteropIos);
    });

    it("does not resolve other platform spellings", function () {
        expect(function () {
            require("ns:interop/android");
        }).toThrowError("No such built-in module: ns:interop/android");
    });

    it("hands out working natives", function () {
        var data = NSString.stringWithString("abc").dataUsingEncoding(NSUTF8StringEncoding);
        var buffer = nsInteropIos.bufferFromData(data);
        expect(buffer instanceof ArrayBuffer).toBe(true);
        expect(Array.prototype.slice.call(new Uint8Array(buffer))).toEqual([97, 98, 99]);

        var nsInterop = require("ns:interop");
        expect(nsInterop.sizeof(nsInteropIos.types.id)).toBe(nsInterop.sizeof(nsInterop.types.uint64));
    });
});

describe("ns:interop ES modules", function () {
    var nsInterop = require("ns:interop");
    var nsInteropIos = require("ns:interop/ios");

    it("resolves through dynamic import with the same members", function (done) {
        Promise.all([import("ns:interop"), import("ns:interop/ios")]).then(function (namespaces) {
            expect(namespaces[0].default).toBe(nsInterop);
            expect(namespaces[0].Pointer).toBe(nsInterop.Pointer);
            expect(namespaces[0].types).toBe(nsInterop.types);
            expect(namespaces[1].default).toBe(nsInteropIos);
            expect(namespaces[1].adopt).toBe(nsInteropIos.adopt);
            done();
        }, function (error) {
            fail("import of ns:interop should resolve: " + error);
            done();
        });
    });

    it("gives every Apple spelling one namespace object", function (done) {
        Promise.all([
            import("ns:interop/ios"),
            import("ns:interop/visionos"),
            import("ns:interop/macos"),
        ]).then(function (namespaces) {
            expect(namespaces[1]).toBe(namespaces[0]);
            expect(namespaces[2]).toBe(namespaces[0]);
            done();
        }, function (error) {
            fail("import of an ns:interop/ios alias should resolve: " + error);
            done();
        });
    });

    it("resolves through a static import", function (done) {
        import("~/tests/esm/ns-interop-import.mjs").then(function (module) {
            expect(module.Pointer).toBe(nsInterop.Pointer);
            expect(module.types).toBe(nsInterop.types);
            expect(module.interopDefault).toBe(nsInterop);
            expect(module.adopt).toBe(nsInteropIos.adopt);
            expect(module.appleTypes).toBe(nsInteropIos.types);
            expect(module.visionosDefault).toBe(nsInteropIos);
            expect(module.macosNamespace).toBe(module.iosNamespace);
            done();
        }, function (error) {
            fail("static import of ns:interop should resolve: " + error);
            done();
        });
    });
});

describe("global interop", function () {
    var nsInterop = require("ns:interop");
    var nsInteropIos = require("ns:interop/ios");
    var runtime = require("ns:runtime");

    it("keeps its key set", function () {
        expect(Object.keys(interop).sort()).toEqual(GLOBAL_KEYS);
        expect(Object.keys(interop.types).sort()).toEqual(C_TYPES.concat(APPLE_TYPES).sort());
    });

    it("holds the modules' own objects", function () {
        ["Pointer", "Reference", "FunctionReference", "sizeof", "alloc", "free", "handleof",
            "stringFromCString"].forEach(function (name) {
            expect(interop[name]).toBe(nsInterop[name]);
        });
        expect(interop.adopt).toBe(nsInteropIos.adopt);
        expect(interop.bufferFromData).toBe(nsInteropIos.bufferFromData);
        expect(interop.escapeException).toBe(runtime.escapeException);
        expect(interop.setExternalSize).toBe(runtime.setExternalSize);
        expect(interop.getExternalSize).toBe(runtime.getExternalSize);
    });

    it("merges both modules' types into one object", function () {
        expect(interop.types).not.toBe(nsInterop.types);
        expect(interop.types).not.toBe(nsInteropIos.types);
        C_TYPES.forEach(function (name) {
            expect(interop.types[name]).toBe(nsInterop.types[name]);
        });
        APPLE_TYPES.forEach(function (name) {
            expect(interop.types[name]).toBe(nsInteropIos.types[name]);
        });
    });

    it("stays a mutable, enumerable global", function () {
        expect(Object.isFrozen(interop)).toBe(false);
        expect(Object.isExtensible(interop)).toBe(true);
        expect(Object.isFrozen(interop.types)).toBe(false);
        var descriptor = Object.getOwnPropertyDescriptor(globalThis, "interop");
        expect(descriptor.enumerable).toBe(true);
        expect(descriptor.writable).toBe(true);
        expect(descriptor.configurable).toBe(true);
    });

    it("is assembled the same way in a worker", function (done) {
        var worker = new Worker("./nsInteropIdentityWorker.js");
        worker.onmessage = function (event) {
            expect(event.data).toEqual({
                keys: GLOBAL_KEYS,
                typeKeys: C_TYPES.concat(APPLE_TYPES).sort(),
                mismatches: [],
                frozen: true,
                aliased: true,
            });
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
