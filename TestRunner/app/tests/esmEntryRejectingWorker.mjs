// An ES module worker entry that rejects AFTER the in-place yield window, the
// way a real failing entry does: parked on a non-nestable foreground task, so
// the entry's evaluation promise is still pending when boot hands off and the
// rejection arrives through that promise rather than synchronously.
//
// The rejection is the worker's own uncaught error. The worker scope's
// `onerror` sees it first, and because this handler declines it, it must go on
// to the parent's error event. Attaching one handler to both outcomes of the
// entry promise used to mark the rejection handled, so neither hop ever ran.
globalThis.onerror = function (error) {
    postMessage("worker-onerror:" + String((error && error.message) || error));
    // Falsy: decline it, so the parent still gets its turn.
    return false;
};

const i32 = new Int32Array(new SharedArrayBuffer(4));
const wait = Atomics.waitAsync(i32, 0, 0);
Atomics.notify(i32, 0);
await wait.value;

throw new Error("entry-rejected");
