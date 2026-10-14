// Keeps the parent's notifications until asked, then releases them on this
// worker's thread in the order they arrived.
var name = "adapter-claim-release";
var notifications = [];
var observer = NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
    name, null, null, function (notification) { notifications.push(notification); });

onmessage = function () {
    NSNotificationCenter.defaultCenter.removeObserver(observer);
    notifications.forEach(function (notification) {
        __releaseNativeCounterpart(notification);
    });
    notifications = [];
    postMessage("released");
};

postMessage("observing");
