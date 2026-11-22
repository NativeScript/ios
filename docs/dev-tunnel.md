# Dev tunnel

`NativeScriptDevTunnel.framework` lets an app on a USB-connected device reach a
server on the developer's Mac (a dev server, a WebSocket) at
`http://127.0.0.1:<port>`, without Wi-Fi and without the Local Network
permission. It is debug-only: the app templates embed it in debug builds only,
and it refuses to open anything when the runtime is not in debug mode.

On iOS only the Mac can open a connection to the device (usbmux), so every
listening socket is in the app:

- **App-side ports**, one per named tunnel (for example `vite`). The app's own
  clients connect to `127.0.0.1:<port>` or `[::1]:<port>`.
- **The tunnel port**, one per app process. The Mac-side tool connects to it
  over usbmux and keeps a **pool** of idle connections; it may also open
  **control** connections.

When an app connection arrives, the relay pairs it with an idle pool
connection, tells the tool which tunnel it is for, and copies bytes both ways
on threads of its own, never the JS thread. The tool dials the real server.
The tool is not part of this repository.

## Ports

All listeners bind loopback only: `127.0.0.1` and `::1`, the same port number
on both, because `localhost` resolves to `::1` on a device.

- A tunnel is opened at its preferred port, or the first port above it where
  both families bind, trying at most 32 ports. When either family reports the
  port in use, the pair moves up together. If nothing binds, the request fails
  and a log line says why.
- The tunnel port is opened the same way, preferring the port the app asked
  for, else **18283** (well above the inspector's 18183, which counts upward
  from there per app).
- A port another process listens on with a wildcard address (`0.0.0.0` or `::`)
  counts as taken: the relay does not bind a more specific address on top of
  it. A port held only by the `TIME_WAIT` connections of the app's previous run
  is reused, so a relaunched app usually gets its ports back.
- A listener that starts failing (iOS can make sockets defunct while the app is
  suspended) is closed and bound again on the same port, retried every second.

Ports never close for the life of the process; the relay survives runtime
restarts.

## Opening tunnels

The relay opens nothing until one of these happens:

1. **The app requests tunnels** with a name and a preferred port each (in the
   runtime: `tns::devtunnel::Request` in `NativeScript/runtime/DevTunnel.h`;
   there is no JavaScript API yet). Requests are idempotent: a name that exists
   keeps its port, a new name adds a tunnel. The answer carries the actual
   ports.
2. **The tool posts the Darwin notification**
   `<bundleId>:NativeScript.Debug.TunnelRequest` (the same scheme as the
   inspector's `<bundleId>:NativeScript.Debug.AttachRequest`). The relay opens
   the tunnel port if it is not open yet. A notification carries no payload:
   the tool then asks for tunnels over a control connection. Each notification
   writes the listening line again.

Every time the set of bound ports changes, the relay writes a public line to
the system log, so tools can find the ports on a device:

```
NativeScript dev tunnel listening for <bundleId>: tunnel port <T>; <name>=<port> <name>=<port>
```

With no tunnels yet the part after `;` is `-`. Failures are logged the same
way (`NativeScript dev tunnel for <bundleId>: ...`), including app connections
closed because no pool connection arrived within 10 s.

## Authentication

A shared token is optional. When the app supplied one, both sides prove they
know it on every tunnel-port connection. Without one there is no
authentication, which is also the inspector's situation.

- The first token configured stays; a request with a different token fails.
  A request without a token leaves the setting as it is.
- When a token is configured after connections were admitted without one (the
  tool opened the tunnel port by notification, then the app asked with a
  token), those idle pool and control connections are closed and never paired.

## Wire protocol v1

Everything before pairing is ASCII lines on the tunnel port: fields separated
by single spaces, each line ending in `\n` and at most **256 bytes including
the `\n`** (a trailing `\r` is ignored). Hex is lowercase on output and either
case on input.

1. **HELLO.** Right after connecting the host sends

   ```
   NSDT/1 HELLO <role> <hostNonceHex>
   ```

   `role` is `pool` or `control`; the nonce is 8 to 32 random bytes. The relay
   waits at most 2 s for this line, counted from the connection, and otherwise
   closes without a word.

2. **READY or DENY.** The relay answers

   ```
   NSDT/1 READY <bundleId> <pid> <tunnelPort> <tunnels> <relayNonceHex> <proof>
   ```

   `tunnels` is `<name>=<port>[,<name>=<port>...]`, or `-` when there are none.
   The relay nonce is 16 random bytes from a CSPRNG. `proof` is
   `hex(HMAC-SHA256(key = token, message = host nonce bytes))` when a token is
   configured, `-` otherwise. The host should check the proof before answering,
   so a relay that does not know the token never receives a valid AUTH.

   Or it answers `NSDT/1 DENY <reason>` and closes.

3. **AUTH**, only when a token is configured. Within 2 s of READY the host sends

   ```
   NSDT/1 AUTH <hex(HMAC-SHA256(key = token, message = relay nonce bytes))>
   ```

   A wrong or missing answer gets `NSDT/1 DENY auth` and the connection closes.
   Proofs are compared in constant time. HMAC keys are the token's bytes; the
   messages are the nonces' bytes, not their hex.

4. **Pool connections** are then idle. The host sends nothing more until the
   relay pairs the connection, so an idle connection that becomes readable has
   been closed (or broke the protocol) and is closed, never paired. At pairing
   the relay writes

   ```
   NSDT/1 PAIR <name> <appPort> <connId>
   ```

   before any byte from the app, then copies raw bytes both ways. The header
   names the tunnel, never a host or port to dial: the tool maps names to
   targets. A half-close on either side is passed on (`shutdown(SHUT_WR)`), and
   the pair closes when both directions ended. Bytes of the app may follow the
   `\n` of the PAIR line in the same read. A server that speaks first works:
   PAIR is sent when the connection is paired, not when the app first writes.

5. **Control connections** are never paired. The host may send, any number of
   times, until it closes:

   - `NSDT/1 OPEN <name> <preferredPort>`: opens a tunnel (or finds the
     existing one) and answers `NSDT/1 OPENED <name> <port>`, or
     `NSDT/1 DENY <reason>`; the connection stays open after a DENY here.
   - `NSDT/1 LIST`: answers a READY line for the current state, with `-` for
     both the nonce and the proof.

   Anything else gets `NSDT/1 DENY protocol` and the connection closes. A
   control connection admitted without a token is closed when a token is
   configured; a command it sent just before gets `NSDT/1 DENY auth`.

DENY reasons: `version` (another `NSDT/<n>`), `protocol` (malformed or overlong
line), `role`, `nonce`, `auth`, `busy` (connection limits), and, for OPEN,
`name`, `port`, `bind` (no port bound), `full` (tunnel limit), `token`,
`bundle`, `internal`.

Limits: tunnel names are 1 to 32 characters from `A-Z a-z 0-9 . _ -`; at most
16 tunnels; and the bundle id plus the tunnel list must leave the READY line
within 256 bytes with the widest pid, port and proof, so a tunnel that would
overflow it is refused rather than truncated. App connections wait at most
10 s for a pool connection.

## Release builds

The framework is listed in `NS_DEBUG_FRAMEWORKS` in the iOS and visionOS app
templates (`internal/nativescript-build.xcconfig`): only configurations based
on `build-debug.xcconfig` embed it, and `nsld.sh` weak-links it, so a release
app keeps a weak load command for it and dyld skips it. The runtime contains
no relay code: it looks up `NativeScriptDevTunnelConnect` with `dlsym` in debug
builds only, and the framework itself refuses to open anything unless the
runtime reports debug mode. The framework has no Objective-C classes and no
public headers, so the metadata generator finds nothing in it.

`scripts/check-dev-tunnel-exclusion.sh <App.app>` fails when a built app
embeds the framework or carries a relay string or symbol, and lists what the
runtime binary keeps (the hook symbol name and the connector's messages).

## Tests

- `node NativeScriptDevTunnel/tests/run-host-tests.mjs` builds the relay and
  the SPI shim for macOS and drives them as the app's clients, the tool's pool
  and control connections (see `NativeScriptDevTunnel/README.md`).
- `TestRunner/app/tests/DevTunnelTests.js` checks the runtime's connector and
  the notification in the test app, through test-only fixtures
  (`TestFixtures/TNSDevTunnel.h`).
