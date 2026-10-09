// Leaves a native object as the only owner of a block built from a function
// that interop.FunctionReference registered first. Teardown disposes registered
// objects newest first, so it releases the block (and runs its dispose) before
// it reaches the function whose slot still points at the block's wrapper.
onmessage = function () {
    var fn = function () {};
    new interop.FunctionReference(fn);
    var operation = NSBlockOperation.alloc().init();
    // The pool drains the reference the marshalling call autoreleased.
    TNSTestNativeCallbacks.repeatPausingAfter(1, function () {
        operation.addExecutionBlock(fn);
    });
    globalThis.heldFunction = fn;
    globalThis.heldOperation = operation;
    postMessage("held");
};
