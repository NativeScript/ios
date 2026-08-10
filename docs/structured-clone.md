# structuredClone

The runtime exposes the WHATWG [`structuredClone(value, options)`](https://html.spec.whatwg.org/multipage/structured-data.html#dom-structuredclone) global. It performs a deep, structure-preserving copy of `value` using V8's structured clone serializer — the same one worker `postMessage` uses — optionally taking ownership of `ArrayBuffer`s named in `options.transfer`.

```js
const clone = structuredClone({ when: new Date(), tags: new Set(["a"]) });

const buffer = new ArrayBuffer(1024);
const moved = structuredClone(buffer, { transfer: [buffer] });
buffer.byteLength; // 0 — the memory now belongs to `moved`
```

## Surface

`structuredClone(value)` returns a clone of `value`. `structuredClone(value, { transfer })` additionally transfers every `ArrayBuffer` in `transfer`.

- `value` is required; calling with no arguments throws a `TypeError`.
- `options` may be `undefined` or `null` (both mean "no transfer"); anything else must be an object, or a `TypeError` is thrown.
- `options.transfer` is a WebIDL sequence: any object with a callable `Symbol.iterator` works (an array, a `Set`, a generator). A non-iterable value — including a string primitive — throws a `TypeError`.

Cloneable: every primitive value except symbols — numbers (including `-0`, `NaN` and the infinities), strings, booleans, `BigInt`, `null` and `undefined`; plain objects and arrays; `Date`, `RegExp`, `Map`, `Set`, `Error`; `Boolean`/`String`/`Number` wrapper objects; `ArrayBuffer`, every typed array and `DataView`.

The clone preserves the shape of the graph, not just the values: an object referenced twice in the input is a single object referenced twice in the output, and cycles round-trip. Prototypes do not survive — a class instance clones to a plain object with the same own properties. Getters are invoked during cloning and their result is stored as a plain data property. Property insertion order is preserved.

Not cloneable — each throws (see the deviation below): functions, symbols, `WeakMap`/`WeakSet`/`WeakRef`, `Promise`, and every native/interop object (ObjC wrappers, pointers, function references), which have no serialized form.

## Transfer semantics

Listed buffers are validated before anything is serialized: each entry must be an `ArrayBuffer`, must not already be detached, must be detachable, and must appear at most once. A violation throws before the source buffers are touched, so a rejected call never leaves a half-transferred graph behind.

On success the memory changes hands rather than being copied: the source buffer is detached (`byteLength` becomes 0, and every typed array over it becomes zero-length) and the clone receives the original backing store. A transferred buffer need not appear inside `value` at all; a buffer reached through a typed array in `value` is transferred as a unit, so the cloned view sees the original bytes.

## Deviations from the specification

- **`DataCloneError` is an `Error`, not a `DOMException`.** This runtime has no `DOMException`, so failures throw an `Error` whose `name` is set to `"DataCloneError"` — the same shape used for native exceptions (see [Error handling](error-handling.md)). Detect failures with `e.name === "DataCloneError"`; `instanceof DOMException` cannot work.
- **Only `ArrayBuffer` is transferable.** The spec's other transferable types — `MessagePort`, `ImageBitmap`, `ReadableStream` and friends — do not exist here. A non-`ArrayBuffer` in the transfer list is a `DataCloneError`.
- **`SharedArrayBuffer` is not supported** and clones to a `DataCloneError`, whether it appears in the value or in the transfer list.
- **Host objects are never cloneable.** The spec leaves platform objects to each host; here every native/interop wrapper is rejected with a `DataCloneError`, because a JavaScript copy detached from its native counterpart would be a wrapper around nothing.
