// Reports whether +0 NSData reaching this worker gets charged, both from a
// call on this thread and from callbacks on a native serial queue.
function poll(predicate, timeoutMs, done) {
    var deadline = Date.now() + timeoutMs;
    (function check() {
        if (predicate() || Date.now() > deadline) {
            done();
        } else {
            setTimeout(check, 10);
        }
    })();
}

onmessage = function () {
    var local;
    TNSExternalMemory.passFreshDataOfLengthTo(128 * 1024, function (data) {
        local = data;
    });
    var localBefore = interop.getExternalSize(local);

    var streamed = [];
    var finished = false;
    TNSExternalMemory.streamDataOfLengthCountIntervalMsToCompletion(32 * 1024, 4, 5, function (data) {
        streamed.push(data);
    }, function () {
        finished = true;
    });

    function allCharged() {
        return interop.getExternalSize(local) > 0 && finished && streamed.length === 4 &&
            streamed.every(function (d) { return interop.getExternalSize(d) > 0; });
    }
    poll(allCharged, 3000, function () {
        postMessage({
            localBefore: localBefore,
            local: interop.getExternalSize(local),
            streamed: streamed.map(function (d) { return interop.getExternalSize(d); })
        });
    });
};
