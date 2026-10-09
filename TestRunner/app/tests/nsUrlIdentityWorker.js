// Reassigns the global before the module is first required in this realm, so
// a module that merely read `globalThis.URL` would report the impostor.
var original = globalThis.URL;
globalThis.URL = function Impostor() {};
var nsUrl = require("ns:url");
postMessage({
    isOriginal: nsUrl.URL === original,
    isImpostor: nsUrl.URL === globalThis.URL,
    frozen: Object.isFrozen(nsUrl),
});
