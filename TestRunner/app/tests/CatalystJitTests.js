// TestRunner's Catalyst build is signed with com.apple.security.cs.allow-jit,
// so the runtime must leave V8's JIT on there. scripts/check-catalyst-jit.sh
// re-signs it into configurations where the runtime must fall back to
// --jitless, and launches those with -expect-jitless.
if (NSProcessInfo.processInfo.macCatalystApp) {
    var expectJitless = NSProcessInfo.processInfo.arguments.containsObject("-expect-jitless");

    describe("Mac Catalyst JIT", function () {
        if (expectJitless) {
            it("runs V8 jitless when the process may not use the JIT", function () {
                expect(TNSHasExecutableV8Memory()).toBe(false);
            });
        } else {
            it("runs V8 with its JIT when the process may map JIT memory", function () {
                expect(TNSHasExecutableV8Memory()).toBe(true);
            });
        }
    });
}
