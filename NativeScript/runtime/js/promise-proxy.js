// Run a Promise's callbacks on the thread that created it, but only when
// that thread is the runtime loop. A Promise created on a background
// thread settles on whichever thread resolves it, because the background
// run loop may be dormant and marshaling a resolution to it would hang.
const { isRuntimeRunloop } = binding;
const { FunctionPrototypeBind, Proxy } = primordials;

global.Promise = new Proxy(global.Promise, {
    construct: function(target, args) {
        let origFunc = args[0];
        let runloop = CFRunLoopGetCurrent();
        let originIsRuntimeLoop = isRuntimeRunloop();

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
                if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                    markFulfilled();
                    resolveCall();
                } else {
                    CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, resolveCall);
                    CFRunLoopWakeUp(runloop);
                    markFulfilled();
                }
            }, reason => {
                if (isFulfilled()) {
                    return;
                }
                const rejectCall = FunctionPrototypeBind(reject, this, reason);
                if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                    markFulfilled();
                    rejectCall();
                } else {
                    CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, rejectCall);
                    CFRunLoopWakeUp(runloop);
                    markFulfilled();
                }
            });
        });

        return new Proxy(promise, {
            get: function(target, name) {
                let orig = target[name];
                if (name === "then" || name === "catch" || name === "finally") {
                    return FunctionPrototypeBind(orig, target);
                }
                return typeof orig === 'function' ? function(x) {
                    if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                        FunctionPrototypeBind(orig, target, x)();
                        return target;
                    }
                    CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, FunctionPrototypeBind(orig, target, x));
                    CFRunLoopWakeUp(runloop);
                    return target;
                } : orig;
            }
        });
    }
});
