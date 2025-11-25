describe("Node built-in and optional module resolution", function () {
  it("provides an in-memory polyfill for node:url", async function () {
    // Dynamic import to exercise ResolveModuleCallback ESM path.
    const mod = await import("node:url");

    expect(mod).toBeDefined();
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

    expect(mod).toBeDefined();
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
});
