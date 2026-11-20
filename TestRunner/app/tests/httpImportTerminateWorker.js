// Starts an HTTP dynamic import and reports as soon as its fetch is in flight,
// without waiting for it to settle.
onmessage = function (msg) {
    import(msg.data).catch(function () {});
    postMessage("fetching");
};
