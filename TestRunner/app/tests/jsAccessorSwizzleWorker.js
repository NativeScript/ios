// Replaces the `value` accessors of a native class from this worker; the
// replacements stay installed on the class after the worker ended.
onmessage = function () {
    Object.defineProperty(TNSAccessorSwizzleTarget.prototype, "value", {
        get: function () {
            return "swizzled by the worker";
        },
        set: function (value) {},
        configurable: true
    });
    postMessage(TNSAccessorDriver.readSwizzleTargetValue());
};
