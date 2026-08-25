describe("worker autorelease pools", function () {
    it("drains autoreleased objects per event-loop callout, not at worker death", function (done) {
        var worker = new Worker("~/tests/autoreleasePoolDrainWorker.js");
        worker.onmessage = function (e) {
            worker.terminate();
            expect(e.data).toContain("TNSAllocLog init");
            expect(e.data).toContain("TNSAllocLog dealloc");
            done();
        };
    });
});
