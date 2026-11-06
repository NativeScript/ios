"use strict";

// The `ns:interop` builtin module: native memory and C values, the part of
// interop every platform shares. See docs/ns-builtin-modules.md.

const {
  Pointer,
  Reference,
  FunctionReference,
  sizeof,
  alloc,
  free,
  handleof,
  stringFromCString,
  types,
} = binding;
const { ObjectFreeze } = primordials;

exports.Pointer = Pointer;
exports.Reference = Reference;
exports.FunctionReference = FunctionReference;
exports.sizeof = sizeof;
exports.alloc = alloc;
exports.free = free;
exports.handleof = handleof;
exports.stringFromCString = stringFromCString;
exports.types = ObjectFreeze(types);
ObjectFreeze(exports);
