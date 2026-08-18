// Resolves whatever bare specifier the parent asks for, through the import map
// this worker inherited at spawn. Worker realms carry only the native
// __ns__-prefixed timers.
onmessage = function (msg) {
    import(msg.data).then(function (mod) {
        postMessage({ ok: true, name: mod.name });
    }).catch(function (error) {
        postMessage({ ok: false, error: String((error && error.message) || error) });
    });
};
