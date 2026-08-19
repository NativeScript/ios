describe("Node built-in and optional module resolution", function () {
  it("resolves node:url through both require and import", async function () {
    // Dynamic import exercises the ESM resolve path; require exercises the
    // CommonJS one. The registered builtin serves both from one frozen object.
    const ns = await import("node:url");
    const nsAgain = await import("node:url");
    const required = globalThis.require("node:url");

    expect(nsAgain).toBe(ns);
    expect(ns.default).toBe(required);
    expect(ns.fileURLToPath).toBe(required.fileURLToPath);
    expect(Object.isFrozen(required)).toBe(true);
    expect(Object.keys(required).sort()).toEqual(["fileURLToPath", "pathToFileURL"]);
  });

  it("converts file URLs to paths the way Node does", function () {
    const { fileURLToPath } = globalThis.require("node:url");

    expect(fileURLToPath("file:///foo/bar.txt")).toBe("/foo/bar.txt");
    expect(fileURLToPath(new URL("file:///foo/bar.txt"))).toBe("/foo/bar.txt");
    // The URL spec folds a "localhost" authority to no host at all.
    expect(fileURLToPath("file://localhost/foo/bar.txt")).toBe("/foo/bar.txt");
    // Query and fragment are URL syntax, never part of the path.
    expect(fileURLToPath("file:///foo/bar.txt?x=1#frag")).toBe("/foo/bar.txt");
    // Percent-encoding is decoded.
    expect(fileURLToPath("file:///foo/a%20b.txt")).toBe("/foo/a b.txt");
    expect(fileURLToPath("file:///foo/100%25.txt")).toBe("/foo/100%.txt");
  });

  it("rejects file URLs it cannot honestly convert", function () {
    const { fileURLToPath } = globalThis.require("node:url");

    expect(function () { fileURLToPath("http://example.com/x.js"); })
      .toThrowError(TypeError, /scheme file/);
    expect(function () { fileURLToPath("file://otherhost/foo.txt"); })
      .toThrowError(TypeError, /host must be/);
    // %2F would decode into a separator and change the path's shape.
    expect(function () { fileURLToPath("file:///foo%2Fbar.txt"); })
      .toThrowError(TypeError, /encoded \/ characters/);
    expect(function () { fileURLToPath(42); }).toThrowError(TypeError);
    expect(function () { fileURLToPath("not a url"); }).toThrowError(TypeError);
  });

  it("converts paths to file URLs and round-trips them", function () {
    const { fileURLToPath, pathToFileURL } = globalThis.require("node:url");

    const url = pathToFileURL("/foo/bar.txt");
    expect(url instanceof URL).toBe(true);
    expect(url.protocol).toBe("file:");
    expect(url.pathname).toBe("/foo/bar.txt");

    // The characters that would otherwise be read as URL syntax.
    for (const path of ["/foo/bar.txt", "/foo/a b.txt", "/foo/100%.txt",
                        "/foo/q?x.txt", "/foo/h#x.txt", "/foo/dir/"]) {
      expect(fileURLToPath(pathToFileURL(path))).toBe(path);
    }

    // No process working directory here, so a relative path has no answer.
    expect(function () { pathToFileURL("foo/bar.txt"); })
      .toThrowError(TypeError, /absolute path/);
    expect(function () { pathToFileURL(42); }).toThrowError(TypeError);
  });

  it("reports an unregistered node: builtin the same way for require and import",
     async function () {
    let importError = null;
    try {
      await import("node:fs");
    } catch (e) {
      importError = e;
    }
    expect(importError).not.toBe(null);
    expect(String(importError)).toContain("No such built-in module: node:fs");

    let requireError = null;
    try {
      globalThis.require("node:fs");
    } catch (e) {
      requireError = e;
    }
    expect(requireError).not.toBe(null);
    expect(String(requireError)).toContain("No such built-in module: node:fs");
  });

  // Missing bare specifiers fail at the request site on both require() and
  // import(). ESM callers that want optionality can `try { await import(x) } catch {}`.
  it("rejects a missing bare specifier instead of resolving a placeholder", async function () {
    const names = [
      "__ns_optional_test_module__",
      // A dot that isn't a recognized file extension (e.g. an npm name shaped like
      // "lodash.debounce") gets no special treatment either.
      "__ns_optional_test_module.dotted__",
    ];

    for (const name of names) {
      let error = null;
      try {
        await import(name);
      } catch (e) {
        error = e;
      }
      expect(error).not.toBe(null);
      expect(String(error)).toContain("Cannot find module");

      let requireError = null;
      try {
        globalThis.require(name);
      } catch (e) {
        requireError = e;
      }
      expect(requireError).not.toBe(null);
      expect(String(requireError)).toContain("Cannot find module");
    }
  });

  it("rejects immediately for a missing bare specifier that carries an explicit file extension", async function () {
    // Extension-qualified names ("video.js") resolve through the filesystem-candidate
    // walk rather than the bare-specifier path; pin that they reject the same way.
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

  it("reuses blob URL modules across concurrent and repeated imports", async function () {
    // `Blob` is a @nativescript/core global — the bare TestRunner realm has
    // none. Stand in a minimal one: `URL.createObjectURL` only needs the
    // argument to be `instanceof Blob` and to carry `type`, and the loader only
    // ever calls `.text()` on it.
    const previousBlob = globalThis.Blob;
    globalThis.Blob = class Blob {
      constructor(parts, options) {
        this._text = (parts || []).join("");
        this.type = (options && options.type) || "";
      }

      text() {
        return Promise.resolve(this._text);
      }
    };

    delete globalThis.__nsBlobEvalCount;

    const blobSource = [
      "globalThis.__nsBlobEvalCount = (globalThis.__nsBlobEvalCount || 0) + 1;",
      "export const evalCount = globalThis.__nsBlobEvalCount;",
      "export const kind = 'blob-module';",
      "export default { evalCount, kind };",
    ].join("\n");

    let url;

    try {
      url = URL.createObjectURL(new Blob([blobSource], { type: "text/javascript" }), {
        ext: ".mjs",
      });

      expect(typeof url).toBe("string");
      expect(url.indexOf("blob:nativescript/")).toBe(0);

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
      if (typeof url === "string") {
        URL.revokeObjectURL(url);
      }
      delete globalThis.__nsBlobEvalCount;
      if (typeof previousBlob === "undefined") {
        delete globalThis.Blob;
      } else {
        globalThis.Blob = previousBlob;
      }
    }
  });
});
