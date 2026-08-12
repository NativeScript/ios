describe("ns:runtime", function () {
    var runtime = require("ns:runtime");

    it("exposes frozen exports", function () {
        expect(Object.isFrozen(runtime)).toBe(true);
        expect(typeof runtime.setConfig).toBe("function");
        expect(typeof runtime.getConfig).toBe("function");
    });

    // The export set is public API, declared in types/ns-runtime.d.ts and
    // docs/ns-builtin-modules.md — all three must change together.
    it("exposes exactly the declared surface", function () {
        expect(Object.keys(runtime).sort()).toEqual(["getConfig", "setConfig"]);
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

    it("defaults logScriptLoading and httpFetchUrlLog from app config", function () {
        expect(runtime.getConfig("logScriptLoading")).toBe(false);
        expect(runtime.getConfig("httpFetchUrlLog")).toBe(false);
    });

    it("round-trips logScriptLoading and httpFetchUrlLog", function () {
        runtime.setConfig("logScriptLoading", true);
        expect(runtime.getConfig("logScriptLoading")).toBe(true);
        runtime.setConfig("logScriptLoading", false);
        expect(runtime.getConfig("logScriptLoading")).toBe(false);

        runtime.setConfig("httpFetchUrlLog", true);
        expect(runtime.getConfig("httpFetchUrlLog")).toBe(true);
        runtime.setConfig("httpFetchUrlLog", false);
        expect(runtime.getConfig("httpFetchUrlLog")).toBe(false);
    });

    it("rejects non-boolean log flag values and keeps the current one", function () {
        expect(function () {
            runtime.setConfig("logScriptLoading", "yes");
        }).toThrowError(TypeError, /must be a boolean/);
        expect(runtime.getConfig("logScriptLoading")).toBe(false);
        expect(function () {
            runtime.setConfig("httpFetchUrlLog", 1);
        }).toThrowError(TypeError, /must be a boolean/);
        expect(runtime.getConfig("httpFetchUrlLog")).toBe(false);
    });

    it("does not expose remote-module security through getConfig or setConfig", function () {
        ["security", "allowRemoteModules", "remoteModuleAllowlist"].forEach(function (key) {
            expect(function () {
                runtime.getConfig(key);
            }).toThrowError(TypeError, /Unknown runtime config key/);
            expect(function () {
                runtime.setConfig(key, true);
            }).toThrowError(TypeError, /Unknown runtime config key/);
        });
    });

    it("is a singleton across require calls", function () {
        expect(require("ns:runtime")).toBe(runtime);
    });
});
