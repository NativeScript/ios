// Starts an HTTP dynamic import, reports "fetching" as soon as it is issued
// and "settled" once it resolves or rejects. A terminated worker never sends
// "settled".
onmessage = function (msg) {
    function settled() {
        postMessage("settled");
    }
    import(msg.data).then(settled, settled);
    postMessage("fetching");
};
