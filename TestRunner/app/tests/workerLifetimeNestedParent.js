// Reports once its child worker is running, so the test can end this worker
// while the child is alive; "close" ends it from the inside instead.
var child = new Worker("./eventLoopEchoWorker.js");
child.onmessage = function () {
    postMessage("child up");
};
child.onerror = function (event) {
    postMessage("child error: " + event.message);
    return true;
};
child.postMessage("ping");

onmessage = function (event) {
    if (event.data === "close") {
        close();
    }
};
