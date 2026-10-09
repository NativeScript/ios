// Hands a JS collection to native loops that keep reading it from background
// threads past this worker's termination.
onmessage = function (msg) {
    var collection = msg.data === "array" ? [1, 2, 3] : { a: 1, b: 2, c: 3 };
    TNSTestNativeCallbacks.queryFromThreadsForMilliseconds(collection, 4, 400);
    postMessage("querying");
};
