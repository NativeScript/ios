"use strict";

// The `ns:runtime` builtin module: runtime-level configuration, native
// exception escaping and external-memory accounting. See
// docs/ns-builtin-modules.md for the contract and the key registry — keys,
// their value domains, and their scope (process-wide vs per-isolate) are
// defined and validated on the native side, so this file stays a thin, frozen
// surface.

const {
  setConfig,
  getConfig,
  escapeException,
  setExternalSize,
  getExternalSize,
} = binding;
const { ObjectFreeze } = primordials;

exports.setConfig = setConfig;
exports.getConfig = getConfig;
exports.escapeException = escapeException;
exports.setExternalSize = setExternalSize;
exports.getExternalSize = getExternalSize;
ObjectFreeze(exports);
