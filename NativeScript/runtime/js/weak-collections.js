"use strict";

// Canary wrapper lifetime mode only (run by WeakRef.cpp): WeakMap, WeakSet,
// WeakRef and FinalizationRegistry key a native object by its lifetime key
// instead of its wrapper. The wrapper (a canary, or under scope "extended" a
// plain object's wrapper) dies with its JS references while the native object
// lives on, and a later wrapper for the same object is a new JS object; keyed
// by the wrapper, entries and targets would be lost with it. Every other value
// passes through unchanged.
//
// They are subclasses of the native collections, so what subclassing shows is
// left as it is: Object.getPrototypeOf(WeakMap.prototype) is the native
// prototype, and WeakMap.toString() is not native code.

const { unwrap, wrap, cache } = binding;
const {
  FinalizationRegistry: NativeFinalizationRegistry,
  FinalizationRegistryPrototypeRegister,
  FinalizationRegistryPrototypeUnregister,
  ObjectDefineProperty,
  ObjectFreeze,
  SymbolKeyFor,
  WeakMap: NativeWeakMap,
  WeakMapPrototypeDelete,
  WeakMapPrototypeGet,
  WeakMapPrototypeGetOrInsert,
  WeakMapPrototypeGetOrInsertComputed,
  WeakMapPrototypeHas,
  WeakMapPrototypeSet,
  WeakRef: NativeWeakRef,
  WeakRefPrototypeDeref,
  WeakSet: NativeWeakSet,
  WeakSetPrototypeAdd,
  WeakSetPrototypeDelete,
  WeakSetPrototypeHas,
} = primordials;

// Only an object can be a canary; anything else goes to the native method as is.
function isObject(value) {
  return (typeof value === "object" && value !== null) || typeof value === "function";
}

// The values the native collections accept as keys and targets.
function canBeHeldWeakly(value) {
  return isObject(value) || (typeof value === "symbol" && SymbolKeyFor(value) === undefined);
}

// unwrap(value, true) makes the key on first use; lookups pass false so they
// never create state for an object that was never a key. A key is made only
// once the native method can no longer reject the call, so a failed call leaves
// no state behind: the receiver is checked first with a method that cannot
// insert anything.
//
// A native object's wrapper is stored as a key itself only when its object can
// have no lifetime key (a class forbidding associated objects or refusing weak
// references, a tagged pointer, a block, a -dealloc receiver, a released
// wrapper that never had one), and unwrap then returns the wrapper too. So
// every method first tries the value as is and unwraps it only when that
// misses.

// Slots of `cache` (WeakCollectionCache in WrapperLifetimeCanary.mm): EPOCH
// changes whenever a wrapper wrap answered may no longer be the one it
// answers; after unwrap(value, true, true), LIVE_CANARY says whether value is
// the wrapper wrap answers with for the key unwrap returned.
const EPOCH = 0;
const LIVE_CANARY = 1;

// The lifetime key value stands for, or undefined when that is value itself.
function otherKey(value) {
  if ((typeof value !== "object" || value === null) && typeof value !== "function") {
    return undefined;
  }
  const key = unwrap(value, false);
  return key !== value ? key : undefined;
}

// Unregistering it finds nothing: it is never a token.
const receiverProbe = ObjectFreeze({ __proto__: null });

class WeakMap extends NativeWeakMap {
  get(key) {
    const direct = WeakMapPrototypeGet(this, key);
    // A stored undefined is a hit too.
    if (direct !== undefined || WeakMapPrototypeHas(this, key)) {
      return direct;
    }
    const other = otherKey(key);
    return other === undefined ? undefined : WeakMapPrototypeGet(this, other);
  }

  set(key, value) {
    // Also checks the receiver before a key is made.
    if (isObject(key) && !WeakMapPrototypeHas(this, key)) {
      key = unwrap(key, true);
    }
    WeakMapPrototypeSet(this, key, value);
    return this;
  }

  has(key) {
    if (WeakMapPrototypeHas(this, key)) {
      return true;
    }
    const other = otherKey(key);
    return other !== undefined && WeakMapPrototypeHas(this, other);
  }

  delete(key) {
    if (WeakMapPrototypeDelete(this, key)) {
      return true;
    }
    const other = otherKey(key);
    return other !== undefined && WeakMapPrototypeDelete(this, other);
  }
}

// V8 ships the upsert proposal; inherited, these would key on the wrapper.
if (WeakMapPrototypeGetOrInsert !== undefined) {
  ObjectDefineProperty(WeakMap.prototype, "getOrInsert", {
    value: function getOrInsert(key, value) {
      if (isObject(key) && !WeakMapPrototypeHas(this, key)) {
        key = unwrap(key, true);
      }
      return WeakMapPrototypeGetOrInsert(this, key, value);
    },
    writable: true,
    configurable: true,
  });
}
if (WeakMapPrototypeGetOrInsertComputed !== undefined) {
  ObjectDefineProperty(WeakMap.prototype, "getOrInsertComputed", {
    value: function getOrInsertComputed(key, callbackfn) {
      if (!isObject(key) || typeof callbackfn !== "function") {
        return WeakMapPrototypeGetOrInsertComputed(this, key, callbackfn);
      }
      if (WeakMapPrototypeHas(this, key)) {
        return WeakMapPrototypeGet(this, key);
      }
      const existing = otherKey(key);
      if (existing !== undefined && WeakMapPrototypeHas(this, existing)) {
        return WeakMapPrototypeGet(this, existing);
      }
      // Before the key exists, so a callback that throws leaves none; it sees
      // the key it was given, not the lifetime key.
      const value = callbackfn(key);
      WeakMapPrototypeSet(this, unwrap(key, true), value);
      return value;
    },
    writable: true,
    configurable: true,
  });
}

class WeakSet extends NativeWeakSet {
  add(value) {
    // Also checks the receiver before a key is made.
    if (isObject(value) && !WeakSetPrototypeHas(this, value)) {
      value = unwrap(value, true);
    }
    WeakSetPrototypeAdd(this, value);
    return this;
  }

  has(value) {
    if (WeakSetPrototypeHas(this, value)) {
      return true;
    }
    const other = otherKey(value);
    return other !== undefined && WeakSetPrototypeHas(this, other);
  }

  delete(value) {
    if (WeakSetPrototypeDelete(this, value)) {
      return true;
    }
    const other = otherKey(value);
    return other !== undefined && WeakSetPrototypeDelete(this, other);
  }
}

class WeakRef extends NativeWeakRef {
  // Undefined when the target is not a lifetime key. Otherwise null, or a
  // NativeWeakRef to the wrapper the WeakRef was made with or deref last
  // returned, which wrap still answers with while the epoch is #epoch.
  #wrapper = undefined;
  #epoch = 0;

  constructor(target) {
    const now = cache[EPOCH];
    const key = isObject(target) ? unwrap(target, true, true) : target;
    const live = key !== target && cache[LIVE_CANARY] !== 0;
    super(key);
    // The target itself, not only its key, stays alive until the job ends.
    if (key !== target) {
      const kept = new NativeWeakRef(target);
      if (live) {
        this.#wrapper = kept;
        this.#epoch = now;
      } else {
        this.#wrapper = null;
      }
    }
  }

  // The live wrapper, a new one if the old one died while the native object
  // lived, or undefined once the native object is gone. Like a native WeakRef
  // target, the wrapper it returns stays alive until the job ends, so a second
  // deref in the same job sees the same object.
  deref() {
    const target = WeakRefPrototypeDeref(this);
    if (!isObject(target)) {
      return target;
    }
    if (!(#wrapper in this)) {
      return wrap(target);
    }
    const last = this.#wrapper;
    if (last === undefined) {
      return target;
    }
    const now = cache[EPOCH];
    if (last !== null && this.#epoch === now) {
      const live = WeakRefPrototypeDeref(last);
      if (live !== undefined) {
        return live;
      }
    }
    const result = wrap(target);
    if (result !== undefined) {
      this.#wrapper = new NativeWeakRef(result);
      this.#epoch = now;
    } else {
      this.#wrapper = null;
    }
    return result;
  }
}

// weak-ref.js gave the native prototype `get` (an alias of `deref`) and a
// deprecated `clear`; inherited as is, `get` would hand out the lifetime key.
ObjectDefineProperty(WeakRef.prototype, "get", {
  value: WeakRef.prototype.deref,
  writable: true,
  configurable: true,
});

class FinalizationRegistry extends NativeFinalizationRegistry {
  constructor(cleanupCallback) {
    super(cleanupCallback);
  }

  // The default keeps `length` at 2, as on the native method.
  register(target, heldValue, unregisterToken = undefined) {
    // Checked on the original values: unwrapping would make target and
    // heldValue differ. A call the native method rejects gets its error.
    if (!canBeHeldWeakly(target) || target === heldValue ||
        (unregisterToken !== undefined && !canBeHeldWeakly(unregisterToken))) {
      return FinalizationRegistryPrototypeRegister(this, target, heldValue, unregisterToken);
    }
    FinalizationRegistryPrototypeUnregister(this, receiverProbe);
    FinalizationRegistryPrototypeRegister(
      this,
      isObject(target) ? unwrap(target, true) : target,
      heldValue,
      isObject(unregisterToken) ? unwrap(unregisterToken, true) : unregisterToken,
    );
  }

  unregister(unregisterToken) {
    if (FinalizationRegistryPrototypeUnregister(this, unregisterToken)) {
      return true;
    }
    const other = otherKey(unregisterToken);
    return other !== undefined && FinalizationRegistryPrototypeUnregister(this, other);
  }
}

for (const [name, value] of [
  ["WeakMap", WeakMap],
  ["WeakSet", WeakSet],
  ["WeakRef", WeakRef],
  ["FinalizationRegistry", FinalizationRegistry],
]) {
  ObjectDefineProperty(globalThis, name, {
    value,
    writable: true,
    configurable: true,
    enumerable: false,
  });
}
