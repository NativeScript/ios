// The rejecting-entry worker, except its scope handler claims the error by
// returning truthy. The web stops propagation there, so the parent's error
// event must NOT fire.
globalThis.onerror = function (error) {
    postMessage("handled:" + String((error && error.message) || error));
    return true;
};

const i32 = new Int32Array(new SharedArrayBuffer(4));
const wait = Atomics.waitAsync(i32, 0, 0);
Atomics.notify(i32, 0);
await wait.value;

throw new Error("entry-rejected-handled");
