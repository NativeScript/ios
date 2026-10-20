"use strict";

// The `ns:swift` builtin module: JavaScript access to Swift modules whose
// generated interop thunks are linked into the app. `module(name)` returns
// the module's types and top-level functions; see docs/swift-interop.md.

const { abiVersion, loadModule, moduleInfo, track: trackNative } = binding;
const { ObjectFreeze, PromisePrototypeThen, PromiseResolve, TypeError } = primordials;

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

function checkFunctions(read, onChange) {
  if (typeof read !== "function" || typeof onChange !== "function") {
    throw new TypeError("Expected (read, onChange) functions.");
  }
}

// Runs `read`, then calls `onChange` once when an @Observable property it
// read is about to change (withObservationTracking).
function track(read, onChange) {
  checkFunctions(read, onChange);
  trackNative(read, onChange);
}

// `track`, re-armed after every change; `onChange` runs after a change made
// on this thread is stored (one made on another thread may still be in
// flight). Returns a function that stops observing.
function observe(read, onChange) {
  checkFunctions(read, onChange);
  let active = true;
  const arm = () => {
    if (!active) {
      return;
    }
    trackNative(read, () => {
      // Observation reports a change before it is made.
      PromisePrototypeThen(PromiseResolve(), () => {
        if (active) {
          // Re-armed first, so changes onChange makes are seen.
          arm();
          onChange();
        }
      });
    });
  };
  arm();
  return () => {
    active = false;
  };
}

exports.abiVersion = abiVersion;
exports.track = track;
exports.observe = observe;
exports.module = module;
exports.info = info;
ObjectFreeze(exports);
