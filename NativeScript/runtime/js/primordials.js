"use strict";

// Snapshot of the intrinsics the other builtins depend on, taken before any
// user code can reach the globals. Runs first and is handed to every other
// builtin as the second fixed parameter.
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
  Proxy,
  String,
  TypeError,
  SymbolHasInstance: Symbol.hasInstance,

  // Statics.
  JSONStringify: JSON.stringify,
  ObjectAssign: Object.assign,
  ObjectCreate: Object.create,
  ObjectDefineProperty: Object.defineProperty,
  ObjectFreeze: Object.freeze,
  ObjectGetOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
  ObjectKeys: Object.keys,
  ObjectSetPrototypeOf: Object.setPrototypeOf,
  ReflectConstruct: Reflect.construct,

  // Instance methods, uncurried.
  ArrayPrototypeConcat: uncurryThis(Array.prototype.concat),
  ArrayPrototypeIndexOf: uncurryThis(Array.prototype.indexOf),
  ArrayPrototypePush: uncurryThis(Array.prototype.push),
  ArrayPrototypeSlice: uncurryThis(Array.prototype.slice),
  ArrayPrototypeSplice: uncurryThis(Array.prototype.splice),
  FunctionPrototypeApply: uncurryThis(FunctionPrototypeApply),
  FunctionPrototypeBind: uncurryThis(FunctionPrototypeBind),
  FunctionPrototypeCall: uncurryThis(FunctionPrototypeCall),
  FunctionPrototypeToString: uncurryThis(Function.prototype.toString),
  MapPrototypeDelete: uncurryThis(Map.prototype.delete),
  MapPrototypeGet: uncurryThis(Map.prototype.get),
  MapPrototypeSet: uncurryThis(Map.prototype.set),
  ObjectPrototypeHasOwnProperty: uncurryThis(Object.prototype.hasOwnProperty),
  StringPrototypeIndexOf: uncurryThis(String.prototype.indexOf),
  StringPrototypeToLowerCase: uncurryThis(String.prototype.toLowerCase),
};

Object.setPrototypeOf(intrinsics, null);
module.exports = Object.freeze(intrinsics);
