// Collects notifications holding the parent's adapters or blocks, so their
// last native release can run inside this isolate's finalizers.
var name = "adapter-cross-isolate-release";
var observing = true;
var received = 0;
var observer = NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
    name, null, null, function (notification) { received++; });

(function collect() {
    if (!observing) {
        return;
    }
    __collect();
    setTimeout(collect, 1);
})();

onmessage = function () {
    observing = false;
    NSNotificationCenter.defaultCenter.removeObserver(observer);
    postMessage({ received: received });
};

postMessage("observing");
