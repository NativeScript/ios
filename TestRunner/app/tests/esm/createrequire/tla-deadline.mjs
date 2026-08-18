// Exclusive to the deadlineSeconds spec: same non-nestable park, so the
// require always reaches its deadline and throws.
const i32 = new Int32Array(new SharedArrayBuffer(4));
const wait = Atomics.waitAsync(i32, 0, 0);
Atomics.notify(i32, 0);

export const value = await wait.value;
