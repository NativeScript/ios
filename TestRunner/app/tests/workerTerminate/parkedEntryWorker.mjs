// Tells the parent the entry is running, then parks the module graph on a
// promise nothing settles: the entry never finishes on its own, so the worker
// sits in the loader's settle pump and, once that gives up, in its event loop.
postMessage("parked");
await new Promise(function () {});
