// TestRunner's Catalyst build is signed with com.apple.security.cs.allow-jit,
// so the runtime must leave V8's JIT on there.
if (NSProcessInfo.processInfo.macCatalystApp) {
    describe("Mac Catalyst JIT", function () {
        it("runs V8 with its JIT when the process may map JIT memory", function () {
            expect(TNSHasExecutableV8Memory()).toBe(true);
        });
    });
}
