// Adapter marshalling interleaved with the native lazy-global paths, on a
// worker isolate: the shape the production heap corruption surfaced under.
onmessage = function (msg) {
    var round = msg.data;
    var decoder = new TextDecoder();
    var sink = 0;

    for (var i = 0; i < 24; i++) {
        var holder = NSMutableArray.alloc().init();
        holder.addObject([round, i]);
        holder.addObject(new Uint8Array(16));
        holder.addObject({ round: round, i: i });
        sink += holder.count;

        sink += decoder.decode(new Uint8Array([65, 66, 67, i % 128])).length;
        sink += atob(btoa("worker-" + i)).length;
    }

    __collect();
    __collect();

    var survivor = NSMutableArray.arrayWithArray([1, 2, 3]);
    postMessage({ ok: sink > 0 && survivor.count === 3 });
};
