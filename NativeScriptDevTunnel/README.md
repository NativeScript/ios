# NativeScriptDevTunnel

The debug-only reverse relay ("dev tunnel") that lets an app on a USB-connected
device reach servers on the developer's Mac. What it does, its ports and its
wire protocol: [docs/dev-tunnel.md](../docs/dev-tunnel.md).

- `src/nsdt_relay.{h,c}`: the relay, plain POSIX C with CommonCrypto, so it
  also builds for macOS.
- `NativeScriptDevTunnel.c`: the framework's entry point
  (`NativeScriptDevTunnelConnect`, the only exported symbol), implementing
  `NativeScript/runtime/DevTunnelSPI.h` and registering for the tool's
  `TunnelRequest` notification.
- `../build_dev_tunnel.sh`: builds `dist/NativeScriptDevTunnel.xcframework`.

## Host tests

```
node NativeScriptDevTunnel/tests/run-host-tests.mjs
```

Builds `tests/relay-host-main.c` with the relay and the SPI shim for macOS
(clang), then runs each "app" as a separate relay process and plays the app's
clients, the Mac-side pool (`tests/host-side.mjs`) and control connections
against it over loopback, with HTTP, WebSocket and raw TCP targets. Node 22 or
later, standard library only. Exits non-zero when a case fails.

Options: `--filter <text>` runs the cases whose name contains the text,
`--out-dir <dir>` keeps the built binary there, `--verbose` prints the relay's
log lines.
