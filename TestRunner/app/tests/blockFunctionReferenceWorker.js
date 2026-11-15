// Hands native code a block built from a function that interop.FunctionReference
// also registered. The parent releases it after this worker's teardown.
onmessage = function () {
    var fn = function () {};
    new interop.FunctionReference(fn);
    TNSTestNativeCallbacks.keepBlockUntilReleased(fn);
    postMessage("kept");
};
