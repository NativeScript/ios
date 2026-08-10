describe("ns:runtime", function () {
    var runtime = require("ns:runtime");

    it("exposes frozen exports", function () {
        expect(Object.isFrozen(runtime)).toBe(true);
        expect(typeof runtime.setConfig).toBe("function");
        expect(typeof runtime.getConfig).toBe("function");
    });

    // Registered before GCFinalizerTests (which toggles the policy and
    // restores it) so this observes the pristine default.
    it("defaults releasedObjectPolicy to 'report'", function () {
        expect(runtime.getConfig("releasedObjectPolicy")).toBe("report");
    });

    it("round-trips releasedObjectPolicy", function () {
        runtime.setConfig("releasedObjectPolicy", "throw");
        expect(runtime.getConfig("releasedObjectPolicy")).toBe("throw");
        runtime.setConfig("releasedObjectPolicy", "report");
        expect(runtime.getConfig("releasedObjectPolicy")).toBe("report");
    });

    it("rejects unknown keys", function () {
        expect(function () {
            runtime.setConfig("noSuchKey", 1);
        }).toThrowError(TypeError, /Unknown runtime config key/);
        expect(function () {
            runtime.getConfig("noSuchKey");
        }).toThrowError(TypeError, /Unknown runtime config key/);
    });

    it("rejects invalid policy values and keeps the current one", function () {
        expect(function () {
            runtime.setConfig("releasedObjectPolicy", "yolo");
        }).toThrowError(TypeError, /'report' or 'throw'/);
        expect(runtime.getConfig("releasedObjectPolicy")).toBe("report");
    });

    it("is a singleton across require calls", function () {
        expect(require("ns:runtime")).toBe(runtime);
    });
});
