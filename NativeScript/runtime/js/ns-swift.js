"use strict";

// The `ns:swift` builtin module: JavaScript access to Swift modules whose
// generated interop thunks are linked into the app. `module(name)` returns
// the module's types and top-level functions; see docs/swift-interop.md.

const { abiVersion, loadModule, moduleInfo } = binding;
const { ObjectFreeze, TypeError } = primordials;

function module(name) {
  if (typeof name !== "string") {
    throw new TypeError('The "name" argument must be a Swift module name.');
  }
  return loadModule(name);
}

function info(name) {
  if (typeof name !== "string") {
    throw new TypeError('The "name" argument must be a Swift module name.');
  }
  return moduleInfo(name);
}

exports.abiVersion = abiVersion;
exports.module = module;
exports.info = info;
ObjectFreeze(exports);
