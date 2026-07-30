// Run a Promise's callbacks on the thread that created it, but only when
// that thread is the runtime loop. A Promise created on a background
// thread settles on whichever thread resolves it, because the background
// run loop may be dormant and marshaling a resolution to it would hang.
(function(isRuntimeRunloop) {
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
                    const resolveCall = resolve.bind(this, value);
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
                    const rejectCall = reject.bind(this, reason);
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
                        return orig.bind(target);
                    }
                    return typeof orig === 'function' ? function(x) {
                        if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                            orig.bind(target, x)();
                            return target;
                        }
                        CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, orig.bind(target, x));
                        CFRunLoopWakeUp(runloop);
                        return target;
                    } : orig;
                }
            });
        }
    });
})
