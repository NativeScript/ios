"use strict";

// The `node:url` compatibility shim over `ns:url` (docs/ns-builtin-modules.md).
// The two surfaces coincide today, so this only re-exports; any adaptation to
// Node's API belongs here, never in the standard module.

const { ObjectFreeze } = primordials;
const { URL, URLSearchParams, fileURLToPath, pathToFileURL } =
  require("ns:url");

module.exports = ObjectFreeze({
  URL,
  URLSearchParams,
  fileURLToPath,
  pathToFileURL,
});
