onmessage = function () {
    const i32 = new Int32Array(new SharedArrayBuffer(4));
    Atomics.waitAsync(i32, 0, 0).value.then(value => {
        postMessage(value);
    });
    Atomics.notify(i32, 0);
};
