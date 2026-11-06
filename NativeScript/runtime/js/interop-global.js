"use strict";

// The global `interop`: a compatibility layer assembled from ns:interop,
// ns:interop/ios and ns:runtime, so every member is the module's own object.
// Unlike the module exports it is not frozen; apps have always been able to
// add to it. A lazy global (LazyGlobals.cpp): it runs on the first read of the
// name.

const interop = require("ns:interop");
const apple = require("ns:interop/ios");
const runtime = require("ns:runtime");

const types = {
  noop: apple.types.noop,
  void: interop.types.void,
  bool: interop.types.bool,
  uint8: interop.types.uint8,
  int8: interop.types.int8,
  uint16: interop.types.uint16,
  int16: interop.types.int16,
  uint32: interop.types.uint32,
  int32: interop.types.int32,
  uint64: interop.types.uint64,
  int64: interop.types.int64,
  ulong: interop.types.ulong,
  slong: interop.types.slong,
  float: interop.types.float,
  double: interop.types.double,
  id: apple.types.id,
  unichar: apple.types.unichar,
  protocol: apple.types.protocol,
  class: apple.types.class,
  selector: apple.types.selector,
};

exports.interop = {
  Reference: interop.Reference,
  Pointer: interop.Pointer,
  FunctionReference: interop.FunctionReference,
  bufferFromData: apple.bufferFromData,
  stringFromCString: interop.stringFromCString,
  handleof: interop.handleof,
  alloc: interop.alloc,
  free: interop.free,
  adopt: apple.adopt,
  setExternalSize: runtime.setExternalSize,
  getExternalSize: runtime.getExternalSize,
  sizeof: interop.sizeof,
  escapeException: runtime.escapeException,
  types,
};
