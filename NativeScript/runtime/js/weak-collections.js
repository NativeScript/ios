"use strict";

// Canary wrapper lifetime mode only (run by WeakRef.cpp): WeakMap, WeakSet,
// WeakRef and FinalizationRegistry key a native object by its lifetime key
// instead of its wrapper. The wrapper is a canary that dies with its JS
// references while the native object lives on, and a later wrapper for the same
// object is a new JS object; keyed by the wrapper, entries and targets would be
// lost with it. Every other value passes through unchanged.

const { unwrap, wrap } = binding;
const {
  FinalizationRegistry: NativeFinalizationRegistry,
  WeakMap: NativeWeakMap,
  WeakRef: NativeWeakRef,
  WeakSet: NativeWeakSet,
} = globalThis;

class WeakMap extends NativeWeakMap {
  get(key) {
    return super.get(unwrap(key));
  }

  set(key, value) {
    super.set(unwrap(key), value);
    return this;
  }

  has(key) {
    return super.has(unwrap(key));
  }

  delete(key) {
    return super.delete(unwrap(key));
  }
}

class WeakSet extends NativeWeakSet {
  add(value) {
    super.add(unwrap(value));
    return this;
  }

  has(value) {
    return super.has(unwrap(value));
  }

  delete(value) {
    return super.delete(unwrap(value));
  }
}

class WeakRef extends NativeWeakRef {
  constructor(target) {
    super(unwrap(target));
  }

  // The live wrapper, a new one if the old one died while the native object
  // lived, or undefined once the native object is gone.
  deref() {
    return wrap(super.deref());
  }
}

// weak-ref.js gave the native prototype a `get` alias of `deref`; inherited
// as is, it would hand out the lifetime key.
Object.defineProperty(WeakRef.prototype, "get", {
  value: WeakRef.prototype.deref,
  writable: true,
  configurable: true,
});

class FinalizationRegistry extends NativeFinalizationRegistry {
  register(target, heldValue, unregisterToken) {
    super.register(
      unwrap(target),
      heldValue,
      unregisterToken === undefined ? undefined : unwrap(unregisterToken),
    );
  }

  unregister(unregisterToken) {
    return super.unregister(unwrap(unregisterToken));
  }
}

for (const [name, value] of [
  ["WeakMap", WeakMap],
  ["WeakSet", WeakSet],
  ["WeakRef", WeakRef],
  ["FinalizationRegistry", FinalizationRegistry],
]) {
  Object.defineProperty(globalThis, name, {
    value,
    writable: true,
    configurable: true,
    enumerable: false,
  });
}
