// Hands native code a block built from a function that interop.FunctionReference
// also registered, and keeps it past this worker's teardown.
onmessage = function () {
    var fn = function () {};
    new interop.FunctionReference(fn);
    TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 300);
    postMessage("kept");
};
