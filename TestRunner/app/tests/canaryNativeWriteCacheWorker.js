// Writes a native property from another isolate, which keeps a native setter
// cache of its own.
onmessage = function () {
    var result = { values: [] };
    try {
        var runtime = require("ns:runtime");
        var Sub = (function (_super) {
            __extends(Sub, _super);
            function Sub() {
                return (_super !== null && _super.apply(this, arguments)) || this;
            }
            return Sub;
        })(TNSCanaryCacheLeaf);
        var depth = Object.getOwnPropertyDescriptor(TNSCanaryCacheBase.prototype, "depth").get;
        var obj = Sub.new();
        var before = runtime.getWrapperLifetimeStats().canaryCachedNativeWrites;
        obj.depth = 1;
        obj.depth = 2;
        obj.depth = 3;
        result.hits = runtime.getWrapperLifetimeStats().canaryCachedNativeWrites - before;
        result.values.push(depth.call(obj));
        result.own = Object.prototype.hasOwnProperty.call(obj, "depth");
    } catch (e) {
        result.error = String((e && e.message) || e);
    }
    postMessage(result);
};
