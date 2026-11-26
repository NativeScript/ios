// Run a Promise's callbacks on the thread that created it, but only when
// that thread is the runtime thread. A Promise created on a background
// thread settles on whichever thread resolves it, because the background
// run loop may be dormant and marshaling a resolution to it would hang.
const { isRuntimeThread, postToRuntimeThread } = binding;
const { FunctionPrototypeBind, Proxy } = primordials;

// Settlements waiting for the runtime thread, oldest first. Every successful
// postToRuntimeThread() makes the runtime thread call runNext() exactly once,
// so queued nodes and posts pair 1:1.
let head = null;
let tail = null;

function enqueue(settle) {
    if (!postToRuntimeThread()) {
        return;
    }
    const node = { settle, next: null };
    if (tail === null) {
        head = node;
    } else {
        tail.next = node;
    }
    tail = node;
}

function runNext() {
    const node = head;
    if (node === null) {
        return;
    }
    head = node.next;
    if (head === null) {
        tail = null;
    }
    node.settle();
}

global.Promise = new Proxy(global.Promise, {
    construct: function(target, args) {
        let origFunc = args[0];
        const originIsRuntimeThread = isRuntimeThread();

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
                markFulfilled();
                if (!originIsRuntimeThread || isRuntimeThread()) {
                    resolveCall();
                } else {
                    enqueue(resolveCall);
                }
            }, reason => {
                if (isFulfilled()) {
                    return;
                }
                const rejectCall = FunctionPrototypeBind(reject, this, reason);
                markFulfilled();
                if (!originIsRuntimeThread || isRuntimeThread()) {
                    rejectCall();
                } else {
                    enqueue(rejectCall);
                }
            });
        });

        // The marshaling lives entirely in the wrapped executor above, so the
        // real promise goes out untouched — engine-level checks (IsPromise,
        // Node-API, rejection tracking) see the same object user code holds.
        return promise;
    }
});

module.exports = runNext;
