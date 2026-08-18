describe("reloadApplication", function () {
    var previousHook;

    beforeEach(function () {
        previousHook = global.__onApplicationReload;
        TNSClearOutput();
    });

    afterEach(function () {
        if (previousHook) {
            global.__onApplicationReload = previousHook;
        } else {
            delete global.__onApplicationReload;
        }
        TNSClearOutput();
    });

    it("keeps the main isolate and JS-backed native methods alive", function () {
        expect(typeof NativeScriptRuntime.reloadApplication).toBe("function");

        var JSObject = NSObject.extend({
            description: function () {
                this._n = (this._n || 0) + 1;
                return "alive-" + this._n;
            }
        }, {
            name: "TNSReloadKeepAlive"
        });
        var inst = JSObject.new();
        expect(NSString.stringWithFormat("%@", inst).toString()).toBe("alive-1");

        var hookCalls = 0;
        global.__onApplicationReload = function () {
            hookCalls++;
        };

        var runtimeBefore = NativeScriptRuntime;
        var countBefore = NativeScriptRuntime.reloadCount;
        expect(NativeScriptRuntime.reloadApplication()).toBe(true);

        expect(hookCalls).toBe(1);
        expect(NativeScriptRuntime).toBe(runtimeBefore);
        expect(NativeScriptRuntime.reloadCount).toBe(countBefore + 1);
        expect(NSString.stringWithFormat("%@", inst).toString()).toBe("alive-2");
    });

    it("re-evaluates required modules on the same isolate", function () {
        global.__onApplicationReload = function () {};

        var first = require("./reload-counter");
        expect(NativeScriptRuntime.reloadApplication()).toBe(true);
        var second = require("./reload-counter");

        expect(second).not.toBe(first);
        expect(second.n).toBe(first.n + 1);
    });

    it("preserves webpack vendor.mjs across reload so the Angular realm stays", function (done) {
        global.__onApplicationReload = function () {};

        import("~/vendor.mjs")
            .then(function (first) {
                expect(NativeScriptRuntime.reloadApplication()).toBe(true);
                return import("~/vendor.mjs").then(function (second) {
                    expect(second).toBe(first);
                    expect(second.n).toBe(first.n);
                    done();
                });
            })
            .catch(function (error) {
                fail("vendor.mjs should resolve before and after reload: " + error);
                done();
            });
    });

    it("keeps JS UIApplicationDelegate IMPs callable from native after reload", function () {
        var AppDelegate = UIResponder.extend({
            get window() {
                TNSLog("app.window");
                return this._window || null;
            },
            set window(value) {
                this._window = value;
            },
            applicationDidFinishLaunchingWithOptions: function () {
                TNSLog("app.didFinishLaunching");
                return true;
            },
            applicationDidBecomeActive: function () {
                TNSLog("app.didBecomeActive");
            },
            applicationConfigurationForConnectingSceneSessionOptions: function () {
                TNSLog("app.configurationForConnecting");
                return null;
            }
        }, {
            name: "TNSReloadAppDelegate",
            protocols: [UIApplicationDelegate]
        });

        var delegate = AppDelegate.new();
        var window = UIWindow.alloc().init();
        delegate.window = window;

        expect(delegate.conformsToProtocol(UIApplicationDelegate)).toBe(true);
        expect(TNSTestNativeCallbacks.invokeDelegateWindow(delegate)).toBe(window);

        TNSClearOutput();
        TNSTestNativeCallbacks.invokeApplicationDelegateLifecycle(delegate);
        expect(TNSGetOutput()).toBe(
            "app.window" +
            "app.didFinishLaunching" +
            "app.didBecomeActive" +
            "app.configurationForConnecting"
        );

        global.__onApplicationReload = function () {};
        var runtimeBefore = NativeScriptRuntime;
        expect(NativeScriptRuntime.reloadApplication()).toBe(true);
        expect(NativeScriptRuntime).toBe(runtimeBefore);
        expect(delegate.conformsToProtocol(UIApplicationDelegate)).toBe(true);
        expect(TNSTestNativeCallbacks.invokeDelegateWindow(delegate)).toBe(window);

        TNSClearOutput();
        TNSTestNativeCallbacks.invokeApplicationDelegateLifecycle(delegate);
        expect(TNSGetOutput()).toBe(
            "app.window" +
            "app.didFinishLaunching" +
            "app.didBecomeActive" +
            "app.configurationForConnecting"
        );
    });

    it("keeps JS UIWindowSceneDelegate IMPs callable from native after reload", function () {
        var SceneDelegate = UIResponder.extend({
            get window() {
                TNSLog("scene.window");
                return this._window || null;
            },
            set window(value) {
                this._window = value;
            },
            sceneWillConnectToSessionOptions: function () {
                TNSLog("scene.willConnect");
            },
            sceneDidBecomeActive: function () {
                TNSLog("scene.didBecomeActive");
            }
        }, {
            name: "TNSReloadSceneDelegate",
            protocols: [UIWindowSceneDelegate]
        });

        var delegate = SceneDelegate.new();
        var window = UIWindow.alloc().init();
        delegate.window = window;

        expect(delegate.conformsToProtocol(UIWindowSceneDelegate)).toBe(true);
        expect(TNSTestNativeCallbacks.invokeDelegateWindow(delegate)).toBe(window);

        TNSClearOutput();
        TNSTestNativeCallbacks.invokeSceneDelegateLifecycle(delegate);
        expect(TNSGetOutput()).toBe("scene.window" + "scene.willConnect" + "scene.didBecomeActive");

        global.__onApplicationReload = function () {};
        expect(NativeScriptRuntime.reloadApplication()).toBe(true);
        expect(delegate.conformsToProtocol(UIWindowSceneDelegate)).toBe(true);
        expect(TNSTestNativeCallbacks.invokeDelegateWindow(delegate)).toBe(window);

        TNSClearOutput();
        TNSTestNativeCallbacks.invokeSceneDelegateLifecycle(delegate);
        expect(TNSGetOutput()).toBe("scene.window" + "scene.willConnect" + "scene.didBecomeActive");
    });

    it("does not replace UIApplication or require a second UIApplicationMain", function () {
        var appBefore = UIApplication.sharedApplication;
        global.__onApplicationReload = function () {};
        expect(NativeScriptRuntime.reloadApplication()).toBe(true);
        expect(UIApplication.sharedApplication).toBe(appBefore);
    });
});
