"use strict";

// The `ns:runtime` builtin: the dev-loader control surface the runtime
// exposes to development tooling (docs/ns-builtin-modules.md). Every member
// is a native function handed in through `binding`; this file only shapes
// and freezes the exports.
//
// Membership varies by realm and build:
//   - `terminateAllWorkers` exists only in the main realm (a worker must not
//     be able to take down its peers — see Worker.h).
//   - `canonicalizeHttpUrlKey` exists only in debug builds (test diagnostic).
// Missing members are simply absent — never present-but-throwing — so
// feature checks work.

const { ObjectFreeze } = primordials;

const surface = {
  configureRuntime: binding.configureRuntime,
  invalidateModules: binding.invalidateModules,
  getLoadedModuleUrls: binding.getLoadedModuleUrls,
  setDevBootComplete: binding.setDevBootComplete,
};
if (binding.terminateAllWorkers !== undefined) {
  surface.terminateAllWorkers = binding.terminateAllWorkers;
}
if (binding.canonicalizeHttpUrlKey !== undefined) {
  surface.canonicalizeHttpUrlKey = binding.canonicalizeHttpUrlKey;
}

module.exports = ObjectFreeze(surface);
