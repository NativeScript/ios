describe("Node built-in and optional module resolution", function () {
  it("provides an in-memory polyfill for node:url", async function () {
    // Dynamic import to exercise ResolveModuleCallback ESM path.
    const mod = await import("node:url");
    const modAgain = await import("node:url");

    expect(mod).toBeDefined();
    expect(modAgain).toBe(mod);
    expect(typeof mod.fileURLToPath).toBe("function");
    expect(typeof mod.pathToFileURL).toBe("function");

    const p = mod.fileURLToPath("file:///foo/bar.txt");
    expect(p === "/foo/bar.txt" || p === "foo/bar.txt").toBe(true);

    const u = mod.pathToFileURL("/foo/bar.txt");
    expect(u instanceof URL).toBe(true);
    expect(u.protocol).toBe("file:");
  });

  it("creates an in-memory placeholder for likely-optional modules", async function () {
    // Use a name that IsLikelyOptionalModule will treat as optional (no slashes, no extension).
    const mod = await import("__ns_optional_test_module__");
    const modAgain = await import("__ns_optional_test_module__");

    expect(mod).toBeDefined();
    expect(modAgain).toBe(mod);
    expect(typeof mod.default).toBe("object");

    let threw = false;
    try {
      // Any property access should throw according to the placeholder implementation.
      // eslint-disable-next-line no-unused-expressions
      mod.default.someProperty;
    } catch (e) {
      threw = true;
    }
    expect(threw).toBe(true);
  });

  // IsLikelyOptionalModule is shared between require() (CommonJS) and this ESM resolver
  // (see ModuleInternal.h) so the boundary can't drift apart between the two paths. The
  // require()-side cases live in shared/Require/index.js; these mirror them for import()
  // to confirm the two stay in parity.
  it("still creates a placeholder for a dotted-but-not-extension bare specifier", async function () {
    // A dot that isn't a recognized file extension (e.g. an npm name like "lodash.debounce")
    // must still be treated as optional, not as an explicit missing file.
    const mod = await import("__ns_optional_test_module.dotted__");

    expect(mod).toBeDefined();
    expect(typeof mod.default).toBe("object");

    let threw = false;
    try {
      // eslint-disable-next-line no-unused-expressions
      mod.default.someProperty;
    } catch (e) {
      threw = true;
    }
    expect(threw).toBe(true);
  });

  it("rejects immediately for a missing bare specifier that carries an explicit file extension", async function () {
    // Mirrors the require()-side "video.js" case: a bare specifier with a recognized file
    // extension is an explicit (here, missing) file reference, not an optional dependency,
    // so import() must reject instead of resolving to a lazily-throwing placeholder.
    const names = [
      "__ns_missing_import_test__.js",
      "__ns_missing_import_test__.json",
      "__ns_missing_import_test__.mjs",
      "video.js",
    ];

    for (const name of names) {
      let threw = false;
      try {
        await import(name);
      } catch (e) {
        threw = true;
      }
      expect(threw).toBe(true);
    }
  });

  it("resolves import-map vendor modules through the explicit vendor registry", async function () {
    const configureRuntime = globalThis.__NS_DEV__ && globalThis.__NS_DEV__.configureRuntime;
    expect(typeof configureRuntime).toBe("function");

    const previousRegistry = globalThis.__nsVendorRegistry;
    const vendorRegistry = new Map();
    globalThis.__nsVendorRegistry = vendorRegistry;
    vendorRegistry.set("__ns_test_vendor__", {
      default: { source: "vendor-default" },
      namedValue: 7,
      makeValue() {
        return "vendor-named";
      },
    });

    try {
      configureRuntime({
        importMap: {
          imports: {
            __ns_test_vendor__: "ns-vendor://__ns_test_vendor__",
          },
        },
      });

      const mod = await import("__ns_test_vendor__");
      const modAgain = await import("__ns_test_vendor__");

      expect(mod).toBeDefined();
      expect(modAgain).toBe(mod);
      expect(mod.default).toEqual({ source: "vendor-default" });
      expect(mod.namedValue).toBe(7);
      expect(mod.makeValue()).toBe("vendor-named");
    } finally {
      configureRuntime({ importMap: { imports: {} } });
      if (typeof previousRegistry === "undefined") {
        delete globalThis.__nsVendorRegistry;
      } else {
        globalThis.__nsVendorRegistry = previousRegistry;
      }
    }
  });

  it("reuses blob URL modules across concurrent and repeated imports", async function () {
    delete globalThis.__nsBlobEvalCount;

    const blobSource = [
      "globalThis.__nsBlobEvalCount = (globalThis.__nsBlobEvalCount || 0) + 1;",
      "export const evalCount = globalThis.__nsBlobEvalCount;",
      "export const kind = 'blob-module';",
      "export default { evalCount, kind };",
    ].join("\n");

    const url = URL.createObjectURL(new Blob([blobSource], { type: "text/javascript" }), {
      ext: ".mjs",
    });

    expect(typeof url).toBe("string");
    expect(url.indexOf("blob:nativescript/")).toBe(0);

    try {
      const [first, second] = await Promise.all([import(url), import(url)]);
      const third = await import(url);

      expect(first).toBeDefined();
      expect(second).toBe(first);
      expect(third).toBe(first);
      expect(first.evalCount).toBe(1);
      expect(second.evalCount).toBe(1);
      expect(third.evalCount).toBe(1);
      expect(first.kind).toBe("blob-module");
      expect(globalThis.__nsBlobEvalCount).toBe(1);
    } finally {
      URL.revokeObjectURL(url);
      delete globalThis.__nsBlobEvalCount;
    }
  });
});
