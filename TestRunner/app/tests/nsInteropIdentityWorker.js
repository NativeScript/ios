// Reads the global before anything in this realm has loaded the modules, so
// the compat layer is what builds them here.
var keys = Object.keys(interop).sort();
var typeKeys = Object.keys(interop.types).sort();
var nsInterop = require("ns:interop");
var nsInteropIos = require("ns:interop/ios");
var runtime = require("ns:runtime");

var mismatches = [];
function check(name, actual, expected) {
    if (actual !== expected) {
        mismatches.push(name);
    }
}
Object.keys(nsInterop).forEach(function (name) {
    if (name !== "types") {
        check(name, interop[name], nsInterop[name]);
    }
});
Object.keys(nsInterop.types).forEach(function (name) {
    check("types." + name, interop.types[name], nsInterop.types[name]);
});
Object.keys(nsInteropIos.types).forEach(function (name) {
    check("types." + name, interop.types[name], nsInteropIos.types[name]);
});
check("adopt", interop.adopt, nsInteropIos.adopt);
check("bufferFromData", interop.bufferFromData, nsInteropIos.bufferFromData);
["escapeException", "setExternalSize", "getExternalSize"].forEach(function (name) {
    check(name, interop[name], runtime[name]);
});

postMessage({
    keys: keys,
    typeKeys: typeKeys,
    mismatches: mismatches,
    frozen: Object.isFrozen(nsInterop) && Object.isFrozen(nsInteropIos),
    aliased: require("ns:interop/visionos") === nsInteropIos,
});
