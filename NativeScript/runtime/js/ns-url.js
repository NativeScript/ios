"use strict";

// The `ns:url` builtin module: the runtime's own URL and URLSearchParams, the
// very functions the globals of those names were created with, and the two
// path/URL converters. See docs/ns-builtin-modules.md for the contract.
//
// The converters parse through URL rather than a hand-rolled scan, so
// authority normalization (`file://localhost/x` has no host, per the URL
// spec), percent-decoding and path canonicalization all follow the spec
// instead of an approximation.

const { URL, URLSearchParams } = binding;
const {
  decodeURIComponent,
  ObjectFreeze,
  StringPrototypeCharCodeAt,
  StringPrototypeStartsWith,
  TypeError,
} = primordials;

const INVALID_ARG =
  'The "path" argument must be of type string or an instance of URL.';

function toUrl(input) {
  let href;
  if (typeof input === "string") {
    href = input;
  } else if (input !== null && typeof input === "object" &&
             typeof input.href === "string") {
    // Duck-typed so a URL from another realm still works.
    href = input.href;
  } else {
    throw new TypeError(INVALID_ARG);
  }

  try {
    return new URL(href);
  } catch {
    throw new TypeError(INVALID_ARG);
  }
}

function fileURLToPath(input) {
  const url = toUrl(input);

  if (url.protocol !== "file:") {
    throw new TypeError("The URL must be of scheme file");
  }
  // The URL parser already folded a "localhost" authority to the empty host,
  // so anything left here is a real remote host and names no local file.
  if (url.hostname !== "") {
    throw new TypeError('File URL host must be "localhost" or empty');
  }

  // `pathname` carries neither the query nor the fragment.
  const pathname = url.pathname;
  for (let i = 0; i < pathname.length; i++) {
    if (pathname[i] !== "%") {
      continue;
    }
    // %2F would decode to a separator and silently change the path's shape.
    const third = StringPrototypeCharCodeAt(pathname, i + 2) | 0x20;
    if (pathname[i + 1] === "2" && third === 102 /* 'f' */) {
      throw new TypeError("File URL path must not include encoded / characters");
    }
  }

  return decodeURIComponent(pathname);
}

const kHexDigits = "0123456789ABCDEF";

// Percent-encode everything the URL parser would otherwise read as syntax (or
// reject), leaving `/` as the separator it is. Non-ASCII is left alone: the
// parser UTF-8 encodes it correctly on its own.
function encodePathChars(filepath) {
  let encoded = "";
  for (let i = 0; i < filepath.length; i++) {
    const char = filepath[i];
    const code = StringPrototypeCharCodeAt(filepath, i);
    const mustEncode =
      code < 0x21 || code === 0x7f || char === "%" || char === "?" ||
      char === "#" || char === "\\" || char === '"' || char === "<" ||
      char === ">" || char === "`" || char === "{" || char === "}";
    if (mustEncode) {
      encoded += "%" + kHexDigits[(code >> 4) & 0xf] + kHexDigits[code & 0xf];
    } else {
      encoded += char;
    }
  }
  return encoded;
}

function pathToFileURL(filepath) {
  if (typeof filepath !== "string") {
    throw new TypeError('The "path" argument must be of type string.');
  }
  // Node resolves a relative path against the process working directory; there
  // is no such thing here, so a relative path has no single correct answer.
  if (!StringPrototypeStartsWith(filepath, "/")) {
    throw new TypeError('The "path" argument must be an absolute path.');
  }

  return new URL("file://" + encodePathChars(filepath));
}

exports.URL = URL;
exports.URLSearchParams = URLSearchParams;
exports.fileURLToPath = fileURLToPath;
exports.pathToFileURL = pathToFileURL;
ObjectFreeze(exports);
