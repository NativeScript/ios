describe("ns:url", function () {
    var nsUrl = require("ns:url");

    it("exposes frozen exports", function () {
        expect(Object.isFrozen(nsUrl)).toBe(true);
        expect(typeof nsUrl.URL).toBe("function");
        expect(typeof nsUrl.URLSearchParams).toBe("function");
        expect(typeof nsUrl.fileURLToPath).toBe("function");
        expect(typeof nsUrl.pathToFileURL).toBe("function");
    });

    // The export set is public API, declared in types/ns-url.d.ts and
    // docs/ns-builtin-modules.md — all three must change together.
    it("exposes exactly the declared surface", function () {
        expect(Object.keys(nsUrl).sort()).toEqual([
            "URL",
            "URLSearchParams",
            "fileURLToPath",
            "pathToFileURL",
        ]);
    });

    it("exports the URL and URLSearchParams the globals hold", function () {
        expect(nsUrl.URL).toBe(globalThis.URL);
        expect(nsUrl.URLSearchParams).toBe(globalThis.URLSearchParams);
    });

    it("leaves URLPattern a global only", function () {
        expect(typeof globalThis.URLPattern).toBe("function");
        expect("URLPattern" in nsUrl).toBe(false);
    });

    it("is a singleton per realm", function () {
        expect(require("ns:url")).toBe(nsUrl);
    });

    it("converts between paths and file URLs with its own URL", function () {
        var url = nsUrl.pathToFileURL("/foo/bar baz.txt");
        expect(url instanceof nsUrl.URL).toBe(true);
        expect(url.href).toBe("file:///foo/bar%20baz.txt");
        expect(nsUrl.fileURLToPath(url)).toBe("/foo/bar baz.txt");
    });

    it("is re-exported member for member by a distinct, frozen node:url", function () {
        var shim = require("node:url");
        expect(shim).not.toBe(nsUrl);
        expect(Object.isFrozen(shim)).toBe(true);
        expect(Object.keys(shim).sort()).toEqual(Object.keys(nsUrl).sort());
        Object.keys(nsUrl).forEach(function (name) {
            expect(shim[name]).toBe(nsUrl[name]);
        });
    });

    it("hands a worker realm its own URL, not whatever the global names", function (done) {
        var worker = new Worker("./nsUrlIdentityWorker.js");
        worker.onmessage = function (event) {
            expect(event.data).toEqual({ isOriginal: true, isImpostor: false, frozen: true });
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
