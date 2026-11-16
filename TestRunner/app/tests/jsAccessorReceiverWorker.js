// Leaves a natively created instance of a class with JS `value` accessors in
// a process-wide native slot, for the parent to reach after this worker ended.
onmessage = function () {
    var Host = TNSAccessorHost.extend({
        get value() {
            return "worker:" + this.name;
        },
        set value(value) {
            this._stored = value;
        },
        get rect() {
            return CGRectMake(1, 2, 3, 4);
        }
    }, { name: "JSAccessorReceiverWorkerHost" });
    TNSAccessorDriver.keepNewHostOfName(Host.class(), "kept");
    var rect = TNSAccessorDriver.readKeptRect();
    postMessage([TNSAccessorDriver.readKeptValue(), rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]);
};
