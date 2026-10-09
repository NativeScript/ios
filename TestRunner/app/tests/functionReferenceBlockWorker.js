// Leaves native code holding a block built from a function that is also an
// interop.FunctionReference with a trampoline, past this worker's teardown.
onmessage = function () {
    var fn = new interop.FunctionReference(function (x) {
        return x * x;
    });
    TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 300);
    var block = interop.handleof(fn).toNumber();

    TNSClearOutput();
    functionWithSimpleFunctionPointer(fn);
    var pointerOutput = String(TNSGetOutput());
    TNSClearOutput();

    TNSTestNativeCallbacks.keepBlockForMilliseconds(fn, 300);
    postMessage({ pointerOutput: pointerOutput, blockKept: block !== 0 });
};
