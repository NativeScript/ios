// Leaves a natively created instance of a class with JS `value` accessors in
// a process-wide native slot, for the parent to reach after this worker ended.
onmessage = function () {
    var Host = TNSAccessorHost.extend({
        get value() {
            return "worker:" + this.name;
        },
        set value(value) {
            this._stored = value;
        }
    }, { name: "JSAccessorReceiverWorkerHost" });
    TNSAccessorDriver.keepNewHostOfName(Host.class(), "kept");
    postMessage(TNSAccessorDriver.readKeptValue());
};
