// Reassigns the global before the module is first required in this realm, so
// a module that merely read `globalThis.Worker` would report the impostor.
var original = globalThis.Worker;
globalThis.Worker = function Impostor() {};
var nsWorkerThreads = require("ns:worker_threads");
postMessage({
    isOriginal: nsWorkerThreads.Worker === original,
    isImpostor: nsWorkerThreads.Worker === globalThis.Worker,
    frozen: Object.isFrozen(nsWorkerThreads),
});
