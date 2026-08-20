"use strict";

// Snapshot of the intrinsics the other builtins depend on, taken before any
// user code can reach the globals. Runs first and is handed to every other
// builtin as the fifth fixed parameter.
//
// Instance methods are exposed "uncurried" (Node's idiom): the receiver
// becomes the first argument, so `ArrayPrototypeSlice(list, 0)` reads the
// captured Array.prototype.slice directly instead of a property of whatever
// `list.slice` resolves to at call time.

const FunctionPrototypeCall = Function.prototype.call;
const FunctionPrototypeBind = Function.prototype.bind;
const FunctionPrototypeApply = Function.prototype.apply;

// bind() with `this` pinned to call(): uncurryThis(fn) === fn.call.bind(fn),
// but without reading `fn.call`.
const uncurryThis = FunctionPrototypeBind.bind(FunctionPrototypeCall);

// Named `intrinsics` rather than `primordials`: the latter is this file's own
// (unused) parameter.
const intrinsics = {
  // Constructors and well-known symbols.
  Error,
  Map,
  Number,
  Proxy,
  Set,
  String,
  TypeError,
  URL,
  SymbolHasInstance: Symbol.hasInstance,
  SymbolIterator: Symbol.iterator,
  SymbolToStringTag: Symbol.toStringTag,

  // Namespaces / prototypes.
  ObjectPrototype: Object.prototype,

  // Statics.
  ArrayBufferIsView: ArrayBuffer.isView,
  ArrayIsArray: Array.isArray,
  decodeURIComponent,
  JSONStringify: JSON.stringify,
  NumberIsFinite: Number.isFinite,
  NumberIsNaN: Number.isNaN,
  NumberParseFloat: Number.parseFloat,
  NumberParseInt: Number.parseInt,
  ObjectAssign: Object.assign,
  ObjectCreate: Object.create,
  ObjectDefineProperty: Object.defineProperty,
  ObjectFreeze: Object.freeze,
  ObjectGetOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
  ObjectGetOwnPropertySymbols: Object.getOwnPropertySymbols,
  ObjectGetPrototypeOf: Object.getPrototypeOf,
  ObjectIs: Object.is,
  ObjectKeys: Object.keys,
  ObjectSetPrototypeOf: Object.setPrototypeOf,
  ReflectConstruct: Reflect.construct,

  // Instance methods, uncurried.
  ArrayPrototypeConcat: uncurryThis(Array.prototype.concat),
  ArrayPrototypeIndexOf: uncurryThis(Array.prototype.indexOf),
  ArrayPrototypePush: uncurryThis(Array.prototype.push),
  ArrayPrototypeSlice: uncurryThis(Array.prototype.slice),
  ArrayPrototypeSort: uncurryThis(Array.prototype.sort),
  ArrayPrototypeSplice: uncurryThis(Array.prototype.splice),
  FunctionPrototypeApply: uncurryThis(FunctionPrototypeApply),
  FunctionPrototypeBind: uncurryThis(FunctionPrototypeBind),
  FunctionPrototypeCall: uncurryThis(FunctionPrototypeCall),
  FunctionPrototypeToString: uncurryThis(Function.prototype.toString),
  DatePrototypeGetTime: uncurryThis(Date.prototype.getTime),
  DatePrototypeToISOString: uncurryThis(Date.prototype.toISOString),
  MapPrototypeDelete: uncurryThis(Map.prototype.delete),
  MapPrototypeEntries: uncurryThis(Map.prototype.entries),
  MapPrototypeGet: uncurryThis(Map.prototype.get),
  MapPrototypeSet: uncurryThis(Map.prototype.set),
  ObjectPrototypeHasOwnProperty: uncurryThis(Object.prototype.hasOwnProperty),
  ObjectPrototypePropertyIsEnumerable: uncurryThis(Object.prototype.propertyIsEnumerable),
  ObjectPrototypeToString: uncurryThis(Object.prototype.toString),
  RegExpPrototypeTest: uncurryThis(RegExp.prototype.test),
  RegExpPrototypeToString: uncurryThis(RegExp.prototype.toString),
  SetPrototypeAdd: uncurryThis(Set.prototype.add),
  SetPrototypeDelete: uncurryThis(Set.prototype.delete),
  SetPrototypeHas: uncurryThis(Set.prototype.has),
  SetPrototypeValues: uncurryThis(Set.prototype.values),
  StringPrototypeCharCodeAt: uncurryThis(String.prototype.charCodeAt),
  StringPrototypeEndsWith: uncurryThis(String.prototype.endsWith),
  StringPrototypeIndexOf: uncurryThis(String.prototype.indexOf),
  StringPrototypeLastIndexOf: uncurryThis(String.prototype.lastIndexOf),
  StringPrototypeSlice: uncurryThis(String.prototype.slice),
  StringPrototypeStartsWith: uncurryThis(String.prototype.startsWith),
  StringPrototypeToLowerCase: uncurryThis(String.prototype.toLowerCase),
  SymbolPrototypeToString: uncurryThis(Symbol.prototype.toString),

  // Iterator-protocol escape hatches: the captured `next` of the live map/set
  // iterator prototypes, so entries can be walked with early exit even after
  // user code tampers %MapIteratorPrototype%/%SetIteratorPrototype%.
  MapIteratorPrototypeNext: uncurryThis(
      Object.getPrototypeOf(new Map()[Symbol.iterator]()).next),
  SetIteratorPrototypeNext: uncurryThis(
      Object.getPrototypeOf(new Set()[Symbol.iterator]()).next),

  // Captured accessor getters: reading .length/.byteLength/.size off an
  // instance via the prototype would invoke whatever getter user code
  // installed there.
  MapPrototypeGetSize: uncurryThis(
      Object.getOwnPropertyDescriptor(Map.prototype, "size").get),
  SetPrototypeGetSize: uncurryThis(
      Object.getOwnPropertyDescriptor(Set.prototype, "size").get),
  TypedArrayPrototypeGetLength: uncurryThis(
      Object.getOwnPropertyDescriptor(
          Object.getPrototypeOf(Uint8Array.prototype), "length").get),
  ArrayBufferPrototypeGetByteLength: uncurryThis(
      Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get),
  DataViewPrototypeGetByteLength: uncurryThis(
      Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get),
};

Object.setPrototypeOf(intrinsics, null);
module.exports = Object.freeze(intrinsics);
