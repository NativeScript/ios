"use strict";

// The `ns:module` builtin: the dev-loader control surface the runtime
// exposes to development tooling (docs/ns-builtin-modules.md). Every member
// is a native function handed in through `binding`; this file only shapes
// and freezes the exports.
//
// Membership varies by build:
//   - `canonicalizeHttpUrlKey` exists only in debug builds (test diagnostic).
// Missing members are simply absent — never present-but-throwing — so
// feature checks work.

const {
  decodeURIComponent,
  ObjectFreeze,
  StringPrototypeEndsWith,
  StringPrototypeIndexOf,
  StringPrototypeLastIndexOf,
  StringPrototypeSlice,
  StringPrototypeStartsWith,
  TypeError,
} = primordials;

// Node's wording (lib/internal/modules/cjs/loader.js), so a message copied out
// of a NativeScript stack trace still matches what the ecosystem documents.
const CREATE_REQUIRE_ERROR =
  "The argument 'filename' must be a file URL object, file URL string, or absolute path string.";

// A `file:` URL string down to the path it names. Deliberately string-based
// rather than routed through the global URL: this runs before app code and
// must not depend on an intrinsic the app may have replaced.
function fileUrlToPath(href) {
  let rest = StringPrototypeSlice(href, "file://".length);

  // Only an empty or localhost authority names a local file.
  const authorityEnd = StringPrototypeIndexOf(rest, "/");
  if (authorityEnd < 0) {
    throw new TypeError(CREATE_REQUIRE_ERROR);
  }
  const authority = StringPrototypeSlice(rest, 0, authorityEnd);
  if (authority !== "" && authority !== "localhost") {
    throw new TypeError(CREATE_REQUIRE_ERROR);
  }
  rest = StringPrototypeSlice(rest, authorityEnd);

  // The query and fragment are URL syntax, never part of the path.
  const queryAt = StringPrototypeIndexOf(rest, "?");
  if (queryAt >= 0) {
    rest = StringPrototypeSlice(rest, 0, queryAt);
  }
  const hashAt = StringPrototypeIndexOf(rest, "#");
  if (hashAt >= 0) {
    rest = StringPrototypeSlice(rest, 0, hashAt);
  }

  try {
    return decodeURIComponent(rest);
  } catch {
    throw new TypeError(CREATE_REQUIRE_ERROR);
  }
}

// The directory a require created for `filenameOrURL` resolves against.
function requireBaseDir(filenameOrURL) {
  let filepath;

  if (typeof filenameOrURL === "object" && filenameOrURL !== null) {
    // A URL object, identified by its href rather than by instanceof so a
    // URL from another realm still works.
    const href = filenameOrURL.href;
    if (typeof href !== "string") {
      throw new TypeError(CREATE_REQUIRE_ERROR);
    }
    filepath = urlStringToPath(href);
  } else if (typeof filenameOrURL !== "string") {
    throw new TypeError(CREATE_REQUIRE_ERROR);
  } else if (StringPrototypeStartsWith(filenameOrURL, "/")) {
    filepath = filenameOrURL;
  } else {
    filepath = urlStringToPath(filenameOrURL);
  }

  // Node treats a trailing slash as "this directory is the base"; otherwise
  // the base is the directory holding the named file.
  if (StringPrototypeEndsWith(filepath, "/")) {
    const trimmed = StringPrototypeSlice(filepath, 0, filepath.length - 1);
    return trimmed === "" ? "/" : trimmed;
  }
  const lastSlash = StringPrototypeLastIndexOf(filepath, "/");
  return lastSlash <= 0 ? "/" : StringPrototypeSlice(filepath, 0, lastSlash);
}

function urlStringToPath(value) {
  if (StringPrototypeStartsWith(value, "file://")) {
    return fileUrlToPath(value);
  }
  if (StringPrototypeStartsWith(value, "http://") ||
      StringPrototypeStartsWith(value, "https://")) {
    // require() over HTTP is blocked runtime-wide; a dev-served module is
    // reachable through import(), and a require base must name a real file.
    throw new TypeError(
      "createRequire() cannot take an http(s) URL (" + value +
        "): require() of a dev-served module is not supported. Pass an app-root " +
        "file path and use import() for remote modules.");
  }
  throw new TypeError(CREATE_REQUIRE_ERROR);
}

function createRequire(filenameOrURL) {
  return binding.createRequire(requireBaseDir(filenameOrURL), false);
}

function createPumpingRequire(filenameOrURL) {
  return binding.createRequire(requireBaseDir(filenameOrURL), true);
}

const surface = {
  configureLoader: binding.configureLoader,
  invalidateModules: binding.invalidateModules,
  getLoadedModuleUrls: binding.getLoadedModuleUrls,
  createRequire,
  createPumpingRequire,
};
if (binding.canonicalizeHttpUrlKey !== undefined) {
  surface.canonicalizeHttpUrlKey = binding.canonicalizeHttpUrlKey;
}

module.exports = ObjectFreeze(surface);
