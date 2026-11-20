// NativeScriptDevTunnel.framework reached through the runtime's connector
// (TNSDevTunnel.h is a test-only fixture, not app API). The relay is
// process-wide and never closes, so the specs run in this order and the first
// one sees nothing open. Simulators share the Mac's loopback with other runs,
// so ports are checked against what the relay reports, never the preferred
// numbers.
describe("Dev tunnel", function () {
    var DEFAULT_TUNNEL_PORT = 18283;
    var bundleId = NSBundle.mainBundle.bundleIdentifier;

    if (!TNSIsConfigurationDebug()) {
        it("is unavailable outside debug builds", function () {
            expect(TNSDevTunnelAvailable()).toBe(false);
            expect(TNSDevTunnelRequest("web=18600", 0, null)).toMatch(/^ERROR /);
        });
        return;
    }

    var tunnelPort = 0;

    it("opens the tunnel port when the tool posts TunnelRequest, and not before", function (done) {
        expect(TNSDevTunnelAvailable()).toBe(true);
        expect(TNSDevTunnelInfo()).toBe(bundleId + " 0 -");

        TNSDevTunnelPostTunnelRequest();
        var deadline = Date.now() + 5000;
        (function poll() {
            var fields = TNSDevTunnelInfo().split(" ");
            if (fields[1] === "0" && Date.now() < deadline) {
                setTimeout(poll, 25);
                return;
            }
            tunnelPort = Number(fields[1]);
            expect(tunnelPort).not.toBeLessThan(DEFAULT_TUNNEL_PORT);
            expect(tunnelPort).toBeLessThan(DEFAULT_TUNNEL_PORT + 32);

            var ready = TNSDevTunnelControl(tunnelPort, "").split(" ");
            expect(ready.slice(0, 3)).toEqual(["NSDT/1", "READY", bundleId]);
            expect(ready[4]).toBe(String(tunnelPort));
            expect(ready[5]).toBe("-");
            expect(ready[7]).toBe("-");
            done();
        })();
    });

    it("requests two tunnels and carries bytes through each end to end", function () {
        var result = TNSDevTunnelRequest("alpha=18600,beta=18610", 0, null);
        var match = /^OK (\d+) alpha=(\d+),beta=(\d+)$/.exec(result);
        expect(match).withContext(result).not.toBe(null);
        var alpha = Number(match[2]);
        var beta = Number(match[3]);
        expect(Number(match[1])).toBe(tunnelPort);
        expect(alpha).not.toBeLessThan(18600);
        expect(beta).not.toBeLessThan(18610);
        expect(alpha).not.toBe(beta);

        var listed = "alpha=" + alpha + ",beta=" + beta;
        expect(TNSDevTunnelInfo()).toBe(bundleId + " " + tunnelPort + " " + listed);
        expect(TNSDevTunnelRequest("beta=18700", 0, null)).toBe("OK " + tunnelPort + " " + listed);

        [["alpha", alpha], ["beta", beta]].forEach(function (tunnel) {
            var payload = "hello " + tunnel[0];
            var parts = TNSDevTunnelRoundTrip(tunnelPort, tunnel[1], payload).split("|");
            var pair = parts[0].split(" ");
            expect(pair.slice(0, 4)).toEqual(["NSDT/1", "PAIR", tunnel[0], String(tunnel[1])]);
            expect(pair.length).toBe(5);
            expect(pair[4]).toMatch(/^\d+$/);
            expect(parts[1]).toBe(payload);
            expect(parts[2]).toBe("echo:" + payload);
        });

        var lines = TNSDevTunnelControl(tunnelPort, "NSDT/1 LIST").split("\n");
        var fields = lines[1].split(" ");
        expect(fields[3]).toMatch(/^\d+$/);
        fields[3] = "<pid>";
        expect(fields).toEqual(["NSDT/1", "READY", bundleId, "<pid>", String(tunnelPort), listed, "-", "-"]);
    });
});
