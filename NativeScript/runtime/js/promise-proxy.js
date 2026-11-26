// Run a Promise's callbacks on the thread that created it, but only when
// that thread is the runtime thread. A Promise created on a background
// thread settles on whichever thread resolves it, because the background
// run loop may be dormant and marshaling a resolution to it would hang.
//
// Never call CFRunLoopGetCurrent() off the runtime thread: it creates a run
// loop for any thread that lacks one.
const { isRuntimeThread } = binding;
const { FunctionPrototypeBind, Proxy } = primordials;

// The runtime loop never changes for an isolate, so it is fetched once, on
// the runtime thread, the first time a Promise is created there.
let runtimeLoop;

global.Promise = new Proxy(global.Promise, {
    construct: function(target, args) {
        let origFunc = args[0];
        const originIsRuntimeThread = isRuntimeThread();
        if (originIsRuntimeThread && runtimeLoop === undefined) {
            runtimeLoop = CFRunLoopGetCurrent();
        }

        let promise = new target(function(resolve, reject) {
            function isFulfilled() {
                return !resolve;
            }
            function markFulfilled() {
                origFunc = null;
                resolve = null;
                reject = null;
            }
            origFunc(value => {
                if (isFulfilled()) {
                    return;
                }
                const resolveCall = FunctionPrototypeBind(resolve, this, value);
                if (!originIsRuntimeThread || isRuntimeThread()) {
                    markFulfilled();
                    resolveCall();
                } else {
                    CFRunLoopPerformBlock(runtimeLoop, kCFRunLoopDefaultMode, resolveCall);
                    CFRunLoopWakeUp(runtimeLoop);
                    markFulfilled();
                }
            }, reason => {
                if (isFulfilled()) {
                    return;
                }
                const rejectCall = FunctionPrototypeBind(reject, this, reason);
                if (!originIsRuntimeThread || isRuntimeThread()) {
                    markFulfilled();
                    rejectCall();
                } else {
                    CFRunLoopPerformBlock(runtimeLoop, kCFRunLoopDefaultMode, rejectCall);
                    CFRunLoopWakeUp(runtimeLoop);
                    markFulfilled();
                }
            });
        });

        // The marshaling lives entirely in the wrapped executor above, so the
        // real promise goes out untouched — engine-level checks (IsPromise,
        // Node-API, rejection tracking) see the same object user code holds.
        return promise;
    }
});
