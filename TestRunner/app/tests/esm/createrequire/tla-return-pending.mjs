// Exclusive to the onTimeout:"return-pending" spec. Parks on a NON-nestable
// foreground task (the Atomics.waitAsync wakeup), so the pump can never settle
// it and the deadline is always reached.
const i32 = new Int32Array(new SharedArrayBuffer(4));
const wait = Atomics.waitAsync(i32, 0, 0);
Atomics.notify(i32, 0);

export const value = await wait.value;
