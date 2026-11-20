// Host test harness for the dev tunnel relay: builds the relay core and the
// framework's SPI shim for macOS, runs each "app" as a relay-host process and
// plays the app's clients, the Mac-side pool and control connections against
// it over loopback. No simulator or device involved.
//
// Usage: node NativeScriptDevTunnel/tests/run-host-tests.mjs [--filter <text>] [--out-dir <dir>] [--sanitize] [--verbose]
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import {
  connect,
  handshake,
  hmacHex,
  lineReader,
  openControl,
  parseReady,
  startPool,
} from "./host-side.mjs";

const { values: args } = parseArgs({
  options: {
    filter: { type: "string" },
    "out-dir": { type: "string" },
    verbose: { type: "boolean", default: false },
    sanitize: { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});
if (args.help) {
  console.log(
    "Usage: node run-host-tests.mjs [--filter <text>] [--out-dir <dir>] [--sanitize] [--verbose]\n" +
      "  --filter   run only the cases whose name contains <text>\n" +
      "  --out-dir  where to build relay-host (default: a new temporary directory)\n" +
      "  --sanitize build the relay with AddressSanitizer and UBSan\n" +
      "  --verbose  print every relay log line",
  );
  process.exit(0);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const frameworkDir = path.resolve(here, "..");
const outDir = args["out-dir"] ?? fs.mkdtempSync(path.join(os.tmpdir(), "nsdt-host-"));
const relayBinary = path.join(outDir, "relay-host");
const TOKEN = "harness-token";
const DEFAULT_TUNNEL_PORT = 18283;
const BUNDLE = "org.nativescript.devtunnel.harness";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sha = (buffer) => createHash("sha256").update(buffer).digest("hex");

// The largest body any case asks for.
const MAX_BODY_BYTES = 300000;

function body(size, seed) {
  if (!Number.isSafeInteger(size) || size < 0 || size > MAX_BODY_BYTES) {
    throw new RangeError(`body size ${size} is not an integer from 0 to ${MAX_BODY_BYTES}`);
  }
  const buffer = Buffer.alloc(size);
  for (let i = 0; i < size; i++) buffer[i] = (i * 31 + seed) & 0xff;
  return buffer;
}

async function waitFor(predicate, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await sleep(25);
  }
  throw new Error(`timed out waiting for ${what}`);
}

function buildRelay() {
  fs.mkdirSync(outDir, { recursive: true });
  execFileSync(
    "clang",
    [
      "-std=c11",
      "-O2",
      ...(args.sanitize ? ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"] : []),
      "-g",
      "-Wall",
      "-Wextra",
      "-Werror",
      path.join(frameworkDir, "src/nsdt_relay.c"),
      path.join(frameworkDir, "NativeScriptDevTunnel.c"),
      path.join(here, "relay-host-main.c"),
      "-o",
      relayBinary,
    ],
    { stdio: "inherit" },
  );
}

// Free on both loopback families, `span` consecutive ports from the result.
async function canListen(port, host) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen({ port, host, ipv6Only: host === "::1" }, () => server.close(() => resolve(true)));
  });
}

let nextCandidate = 20000 + Math.floor(Math.random() * 20000);
async function freePorts(span = 1) {
  for (;;) {
    const base = nextCandidate;
    nextCandidate += span + 7;
    if (nextCandidate > 60000) nextCandidate = 20000;
    let ok = true;
    for (let port = base; ok && port < base + span; port++) {
      ok = (await canListen(port, "127.0.0.1")) && (await canListen(port, "::1"));
    }
    if (ok) return base;
  }
}

function listen(server, options) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(options, () => {
      server.off("error", reject);
      resolve(server);
    });
  });
}

const relays = [];
// One process per "app"; its stdin takes relay-host-main.c's commands.
function startRelay({ bundleId = BUNDLE, release = false } = {}) {
  const argv = ["--bundle-id", bundleId];
  if (release) argv.push("--release");
  const child = spawn(relayBinary, argv, { stdio: ["pipe", "pipe", "pipe"] });
  const logs = [];
  const answers = [];
  let waiting = [];
  child.stderr.setEncoding("utf8");
  let stderrBuffer = "";
  child.stderr.on("data", (chunk) => {
    stderrBuffer += chunk;
    let index;
    while ((index = stderrBuffer.indexOf("\n")) !== -1) {
      const line = stderrBuffer.slice(0, index);
      stderrBuffer = stderrBuffer.slice(index + 1);
      if (args.verbose) console.log(`    [${bundleId}] ${line}`);
      logs.push(line.replace(/^LOG /, ""));
    }
  });
  child.stdout.setEncoding("utf8");
  let stdoutBuffer = "";
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    let index;
    while ((index = stdoutBuffer.indexOf("\n")) !== -1) {
      answers.push(stdoutBuffer.slice(0, index));
      stdoutBuffer = stdoutBuffer.slice(index + 1);
      const resolve = waiting.shift();
      if (resolve) resolve(answers.shift());
    }
  });
  const relay = {
    child,
    logs,
    bundleId,
    command(line) {
      return new Promise((resolve) => {
        waiting.push(resolve);
        child.stdin.write(`${line}\n`);
      });
    },
    // request(<tunnelPort>|undefined, <token>|undefined, { name: port }) -> { tunnelPort, tunnels }
    async request(tunnelPort, token, tunnels = {}) {
      const specs = Object.entries(tunnels).map(([name, port]) => `${name}=${port}`);
      const answer = await relay.command(
        ["request", tunnelPort ?? "-", token ?? "-", ...specs].join(" "),
      );
      const match = /^OK (\d+) (\S+)$/.exec(answer);
      if (!match) throw new Error(answer);
      return { tunnelPort: Number(match[1]), tunnels: parseList(match[2]) };
    },
    kill() {
      child.kill("SIGKILL");
      return new Promise((resolve) => child.once("exit", resolve));
    },
  };
  relays.push(relay);
  return relay;
}

function parseList(list) {
  const tunnels = {};
  if (list !== "-") {
    for (const entry of list.split(",")) {
      const [name, port] = entry.split("=");
      tunnels[name] = Number(port);
    }
  }
  return tunnels;
}

// Dev server stand-in: GET /bytes/<n>/<seed> returns n deterministic bytes
// (400 when n exceeds MAX_BODY_BYTES), anything else "<label> <url>"; /ws
// upgrades to a WebSocket echo. Counts the TCP connections it accepts.
function startTarget(label) {
  const state = { connections: 0 };
  const server = http.createServer((req, res) => {
    const match = /^\/bytes\/(\d{1,7})\/(\d{1,3})(?:$|[/?])/.exec(req.url);
    const size = match ? Number(match[1]) : 0;
    if (match && size > MAX_BODY_BYTES) {
      res.writeHead(400);
      res.end();
      return;
    }
    const payload = match ? body(size, Number(match[2])) : Buffer.from(`${label} ${req.url}`);
    res.writeHead(200, {
      "content-type": "application/octet-stream",
      "content-length": payload.length,
    });
    res.end(payload);
  });
  server.keepAliveTimeout = 30000;
  server.on("connection", () => state.connections++);
  server.on("upgrade", (req, socket) => acceptWebSocket(req, socket));
  return listen(server, { port: 0, host: "127.0.0.1" }).then(() => ({
    server,
    state,
    address: { host: "127.0.0.1", port: server.address().port },
  }));
}

// The smallest RFC 6455 server that echoes text and binary messages.
function acceptWebSocket(req, socket) {
  const key = req.headers["sec-websocket-key"];
  const accept = createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  let buffer = Buffer.alloc(0);
  socket.on("error", () => {});
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= buffer[maskOffset + (i % 4)];
      }
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) {
        socket.end(Buffer.from([0x88, 0x00]));
        return;
      }
      if (opcode === 0x9) {
        socket.write(frame(0xa, payload));
        continue;
      }
      if (opcode === 0x1 || opcode === 0x2) socket.write(frame(opcode, payload));
    }
  });
}

function frame(opcode, payload) {
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x80 | opcode, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

// Raw TCP target that answers only after the client half-closes.
function startReverseTarget() {
  const server = net.createServer({ allowHalfOpen: true }, (socket) => {
    const chunks = [];
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.on("end", () => socket.end(Buffer.from(Buffer.concat(chunks)).reverse()));
  });
  return listen(server, { port: 0, host: "127.0.0.1" }).then(() => ({
    server,
    address: { host: "127.0.0.1", port: server.address().port },
  }));
}

// Raw TCP target that speaks first, then echoes.
function startBannerTarget() {
  const server = net.createServer((socket) => {
    socket.on("error", () => {});
    socket.write("220 banner from the server\n");
    socket.pipe(socket);
  });
  return listen(server, { port: 0, host: "127.0.0.1" }).then(() => ({
    server,
    address: { host: "127.0.0.1", port: server.address().port },
  }));
}

function get(url, agent) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { agent }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () =>
        resolve({ status: res.statusCode, body: Buffer.concat(chunks), reusedSocket: req.reusedSocket }),
      );
      res.on("error", reject);
    });
    req.on("error", reject);
    req.setTimeout(20000, () => req.destroy(new Error(`timeout ${url}`)));
  });
}

// Resolves with everything the peer sent before it closed (or ended its side),
// and how long that took.
function readUntilClosed(socket, timeoutMs = 15000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const chunks = [];
    const timer = setTimeout(() => reject(new Error(`still open after ${timeoutMs} ms`)), timeoutMs);
    const done = () => {
      clearTimeout(timer);
      resolve({ data: Buffer.concat(chunks).toString("latin1"), ms: Date.now() - started });
      socket.destroy();
    };
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.on("error", () => {});
    socket.once("end", done);
    socket.once("close", done);
  });
}

function notify(bundleId) {
  execFileSync("notifyutil", ["-p", `${bundleId}:NativeScript.Debug.TunnelRequest`]);
}

function listeningLines(relay) {
  return relay.logs.filter((line) => line.startsWith("NativeScript dev tunnel listening for "));
}

const results = [];
async function check(name, run) {
  if (args.filter && !name.includes(args.filter)) return;
  const started = Date.now();
  try {
    await run();
    results.push({ name, ok: true });
    console.log(`ok   ${name} (${Date.now() - started} ms)`);
  } catch (error) {
    results.push({ name, ok: false });
    console.log(`FAIL ${name}: ${error.stack || error.message}`);
  }
}

async function main() {
  buildRelay();
  const web = await startTarget("web");
  const api = await startTarget("api");
  const targets = { web: web.address, api: api.address };

  // The main relay: one app with a token and a "web" tunnel.
  const tunnelPort = await freePorts(1);
  const webPort = await freePorts(1);
  let main = null;
  let pool = null;
  let mainTunnels = {};
  const newPool = (size = 8) =>
    startPool({ port: tunnelPort, token: TOKEN, targets, size });

  await check("a pool started before the relay retries until it listens", async () => {
    pool = newPool();
    await sleep(400);
    assert.ok(pool.stats.connectFailures > 0, "expected refused connects before the relay starts");
    main = startRelay();
    const opened = await main.request(tunnelPort, TOKEN, { web: webPort });
    assert.equal(opened.tunnelPort, tunnelPort);
    assert.equal(opened.tunnels.web, webPort);
    mainTunnels = opened.tunnels;
    await waitFor(() => pool.idleCount() === 8, 5000, "8 idle pool connections");
    assert.deepEqual([...pool.stats.bundleIds], [BUNDLE]);
  });

  await check("the listening log line names the bundle id and every bound port", async () => {
    await waitFor(() => listeningLines(main).length > 0, 2000, "the listening log line");
    assert.deepEqual(listeningLines(main), [
      `NativeScript dev tunnel listening for ${BUNDLE}: tunnel port ${tunnelPort}; web=${webPort}`,
    ]);
  });

  await check("an app connection queued before any pool connection is paired once one opens", async () => {
    pool.stop();
    await sleep(200);
    const response = get(`http://127.0.0.1:${webPort}/queued`, false);
    await sleep(700);
    pool = newPool();
    const { status, body: received } = await response;
    assert.equal(status, 200);
    assert.equal(received.toString(), "web /queued");
  });

  await check("keep-alive: 20 sequential requests share one connection end to end", async () => {
    const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    const before = web.state.connections;
    for (let i = 0; i < 20; i++) {
      const { status, body: received, reusedSocket } = await get(
        `http://127.0.0.1:${webPort}/bytes/4096/${i}`,
        agent,
      );
      assert.equal(status, 200);
      assert.equal(sha(received), sha(body(4096, i)));
      if (i > 0) assert.ok(reusedSocket, `request ${i} did not reuse the socket`);
    }
    agent.destroy();
    assert.equal(web.state.connections - before, 1);
  });

  await check("100 parallel requests of 256 KiB each", async () => {
    const agent = new http.Agent({ keepAlive: false, maxSockets: 100 });
    const pairedBefore = pool.stats.paired;
    const responses = await Promise.all(
      Array.from({ length: 100 }, (_, i) =>
        get(`http://127.0.0.1:${webPort}/bytes/262144/${i}`, agent),
      ),
    );
    responses.forEach(({ status, body: received }, i) => {
      assert.equal(status, 200);
      assert.equal(sha(received), sha(body(262144, i)), `body ${i}`);
    });
    assert.equal(pool.stats.paired - pairedBefore, 100);
  });

  await check("the pool replenishes to its size after a burst", async () => {
    await waitFor(
      () => pool.idleCount() === 8 && pool.stats.activePairs === 0,
      5000,
      "8 idle pool connections, no active pairs",
    );
  });

  await check("WebSocket echo over 127.0.0.1 and over localhost", async () => {
    for (const host of ["127.0.0.1", "localhost"]) {
      const socket = new WebSocket(`ws://${host}:${webPort}/ws`);
      await new Promise((resolve, reject) => {
        socket.onopen = resolve;
        socket.onerror = () => reject(new Error(`WebSocket to ${host} failed`));
      });
      const received = [];
      const done = new Promise((resolve) => {
        socket.onmessage = (event) => {
          received.push(event.data);
          if (received.length === 50) resolve();
        };
      });
      for (let i = 0; i < 50; i++) socket.send(`message ${i} via ${host}`);
      await done;
      assert.deepEqual(
        received,
        Array.from({ length: 50 }, (_, i) => `message ${i} via ${host}`),
      );
      socket.close();
    }
  });

  await check("HTTP over localhost and over [::1]", async () => {
    for (const host of ["localhost", "[::1]"]) {
      const { status, body: received } = await get(`http://${host}:${webPort}/via`, false);
      assert.equal(status, 200);
      assert.equal(received.toString(), "web /via");
    }
  });

  await check("closed idle pool connections are never paired", async () => {
    pool.stop();
    await sleep(50);
    const response = get(`http://127.0.0.1:${webPort}/after-close`, false);
    await sleep(300);
    pool = newPool();
    const { status, body: received } = await response;
    assert.equal(status, 200);
    assert.equal(received.toString(), "web /after-close");
  });

  await check("two tunnels interleaved over one pool", async () => {
    const apiPort = await freePorts(1);
    const added = await main.request(undefined, TOKEN, { api: apiPort });
    assert.equal(added.tunnels.api, apiPort);
    assert.equal(added.tunnels.web, webPort);
    mainTunnels = added.tunnels;
    const before = { ...pool.stats.pairedByName };
    const agent = new http.Agent({ keepAlive: false, maxSockets: 40 });
    const responses = await Promise.all(
      Array.from({ length: 40 }, (_, i) => {
        const name = i % 2 === 0 ? "web" : "api";
        return get(`http://127.0.0.1:${mainTunnels[name]}/n/${i}`, agent).then((r) => ({ ...r, name, i }));
      }),
    );
    for (const { status, body: received, name, i } of responses) {
      assert.equal(status, 200);
      assert.equal(received.toString(), `${name} /n/${i}`);
    }
    assert.equal(pool.stats.pairedByName.web - (before.web ?? 0), 20);
    assert.equal(pool.stats.pairedByName.api - (before.api ?? 0), 20);
  });

  await check("requests are idempotent and refuse a different token", async () => {
    const again = await main.request(undefined, TOKEN, { web: webPort + 3 });
    assert.equal(again.tunnels.web, webPort);
    const unchanged = await main.request(undefined, undefined, {});
    assert.deepEqual(unchanged.tunnels, mainTunnels);
    await assert.rejects(main.request(undefined, "another-token", {}), /different token/);
    await assert.rejects(main.request(undefined, undefined, { "bad/name": 1234 }), /invalid tunnel name/);
    await assert.rejects(main.request(undefined, undefined, { [`n${"x".repeat(32)}`]: 1234 }), /invalid tunnel name/);
    assert.deepEqual((await main.request(undefined, undefined, {})).tunnels, mainTunnels);
  });

  await check("a tunnel added through a control connection carries traffic and LIST shows it", async () => {
    const control = await openControl({ port: tunnelPort, token: TOKEN });
    assert.deepEqual(control.ready.tunnels, mainTunnels);
    const preferred = await freePorts(1);
    const opened = await control.command(`NSDT/1 OPEN late ${preferred}`);
    assert.equal(opened, `NSDT/1 OPENED late ${preferred}`);
    assert.equal(await control.command(`NSDT/1 OPEN late ${preferred + 5}`), opened);
    assert.equal(await control.command("NSDT/1 OPEN bad/name 1234"), "NSDT/1 DENY name");
    assert.equal(await control.command("NSDT/1 OPEN other 0"), "NSDT/1 DENY port");
    targets.late = web.address;
    const { status, body: received } = await get(`http://127.0.0.1:${preferred}/late`, false);
    assert.equal(status, 200);
    assert.equal(received.toString(), "web /late");
    const listed = parseReady(await control.command("NSDT/1 LIST"));
    assert.equal(listed.bundleId, BUNDLE);
    assert.equal(listed.tunnelPort, tunnelPort);
    assert.equal(listed.nonce, "-");
    assert.equal(listed.proof, "-");
    assert.deepEqual(listed.tunnels, { ...mainTunnels, late: preferred });
    mainTunnels = listed.tunnels;
    await waitFor(
      () => listeningLines(main).at(-1).endsWith(`; web=${webPort} api=${mainTunnels.api} late=${preferred}`),
      2000,
      "the listening line with the new tunnel",
    );
    const info = await main.command("info");
    assert.equal(info, `INFO ${BUNDLE} ${tunnelPort} web=${webPort},api=${mainTunnels.api},late=${preferred}`);
    control.close();
  });

  await check("an unknown tunnel name on the host side closes that app connection only", async () => {
    const unknownPort = await freePorts(1);
    await main.request(undefined, TOKEN, { nobody: unknownPort });
    const before = pool.stats.unknownName;
    const socket = net.connect({ host: "127.0.0.1", port: unknownPort });
    const { data } = await readUntilClosed(socket, 5000);
    assert.equal(data, "");
    assert.equal(pool.stats.unknownName - before, 1);
    const { body: received } = await get(`http://127.0.0.1:${webPort}/still-fine`, false);
    assert.equal(received.toString(), "web /still-fine");
  });

  await check("a server that speaks first reaches the app before it sends anything", async () => {
    const banner = await startBannerTarget();
    const bannerPort = await freePorts(1);
    await main.request(undefined, TOKEN, { banner: bannerPort });
    targets.banner = banner.address;
    const socket = await connect(bannerPort);
    const reader = lineReader(socket);
    assert.equal(await reader.next(), "220 banner from the server");
    socket.write("echo me\n");
    assert.equal(await reader.next(), "echo me");
    socket.destroy();
    banner.server.close();
  });

  await check("the relay's proof is verified by the host; a wrong token never gets to AUTH", async () => {
    const good = await connect(tunnelPort);
    const { ready } = await handshake(good, { role: "control", token: TOKEN });
    assert.match(ready.proof, /^[0-9a-f]{64}$/);
    good.destroy();
    const wrong = await connect(tunnelPort);
    await assert.rejects(handshake(wrong, { role: "control", token: "not-the-token" }), /proof does not match/);
    wrong.destroy();
  });

  await check("a wrong AUTH and a missing AUTH are denied", async () => {
    const wrong = await connect(tunnelPort);
    const reader = lineReader(wrong);
    wrong.write(`NSDT/1 HELLO pool ${randomBytes(16).toString("hex")}\n`);
    const ready = parseReady(await reader.next());
    wrong.write(`NSDT/1 AUTH ${hmacHex("not-the-token", Buffer.from(ready.nonce, "hex"))}\n`);
    assert.equal(await reader.next(), "NSDT/1 DENY auth");
    await assert.rejects(reader.next(), /connection closed/);

    const silent = await connect(tunnelPort);
    const silentReader = lineReader(silent);
    const started = Date.now();
    silent.write(`NSDT/1 HELLO pool ${randomBytes(16).toString("hex")}\n`);
    assert.ok(parseReady(await silentReader.next()));
    assert.equal(await silentReader.next(), "NSDT/1 DENY auth");
    const elapsed = Date.now() - started;
    assert.ok(elapsed >= 1800 && elapsed < 3500, `denied after ${elapsed} ms`);
  });

  await check("a connection that never sends HELLO is closed after 2 s", async () => {
    const socket = await connect(tunnelPort);
    const { data, ms } = await readUntilClosed(socket, 6000);
    assert.equal(data, "");
    assert.ok(ms >= 1800 && ms < 3500, `closed after ${ms} ms`);
  });

  await check("another protocol version, an unknown role and an overlong line are denied", async () => {
    const cases = [
      [`NSDT/2 HELLO pool ${"ab".repeat(16)}\n`, "NSDT/1 DENY version\n"],
      [`NSDT/1 HELLO peer ${"ab".repeat(16)}\n`, "NSDT/1 DENY role\n"],
      [`NSDT/1 HELLO pool abc\n`, "NSDT/1 DENY nonce\n"],
      ["GET / HTTP/1.1\r\n\r\n", "NSDT/1 DENY protocol\n"],
      ["x".repeat(300), "NSDT/1 DENY protocol\n"],
    ];
    for (const [sent, expected] of cases) {
      const socket = await connect(tunnelPort);
      socket.write(sent);
      const { data } = await readUntilClosed(socket, 5000);
      assert.equal(data, expected, JSON.stringify(sent.slice(0, 40)));
    }
  });

  await check("half-close: the client ends its side and still gets the answer", async () => {
    const reverse = await startReverseTarget();
    const halfPort = await freePorts(1);
    await main.request(undefined, TOKEN, { reverse: halfPort });
    targets.reverse = reverse.address;
    const payload = body(300000, 7);
    const answer = await new Promise((resolve, reject) => {
      const socket = net.connect({ host: "127.0.0.1", port: halfPort, allowHalfOpen: true });
      const chunks = [];
      socket.on("data", (chunk) => chunks.push(chunk));
      socket.on("end", () => resolve(Buffer.concat(chunks)));
      socket.on("error", reject);
      socket.end(payload);
    });
    assert.equal(sha(answer), sha(Buffer.from(payload).reverse()));
    reverse.server.close();
  });

  await check("no-token mode end to end", async () => {
    const relay = startRelay({ bundleId: "org.nativescript.devtunnel.notoken" });
    const ports = await freePorts(2);
    const opened = await relay.request(ports, undefined, { web: ports + 1 });
    const open = startPool({ port: opened.tunnelPort, targets, size: 2 });
    await waitFor(() => open.idleCount() === 2, 3000, "no-token pool");
    const raw = await connect(opened.tunnelPort);
    const { ready } = await handshake(raw, { role: "control" });
    assert.equal(ready.proof, "-");
    raw.destroy();
    const { body: received } = await get(`http://127.0.0.1:${opened.tunnels.web}/open`, false);
    assert.equal(received.toString(), "web /open");
    const tokenPool = startPool({ port: opened.tunnelPort, token: TOKEN, targets, size: 1 });
    await waitFor(() => tokenPool.stats.handshakeFailures > 0, 3000, "a token pool refusing a relay without one");
    assert.equal(tokenPool.stats.denied.proof, tokenPool.stats.handshakeFailures);
    tokenPool.stop();
    open.stop();
    await relay.kill();
  });

  await check("relay restart (app relaunch): same ports, the pool drops dead connections and refills", async () => {
    const ports = await freePorts(2);
    const first = startRelay({ bundleId: "org.nativescript.devtunnel.restart" });
    await first.request(ports, TOKEN, { web: ports + 1 });
    const restartPool = startPool({ port: ports, token: TOKEN, targets, size: 4 });
    await waitFor(() => restartPool.idleCount() === 4, 3000, "pool on the first relay");
    const { body: warm } = await get(`http://127.0.0.1:${ports + 1}/before-restart`, false);
    assert.equal(warm.toString(), "web /before-restart");
    await first.kill();
    await waitFor(() => restartPool.stats.idleClosed >= 3, 3000, "idle connections to the dead relay dropped");
    const second = startRelay({ bundleId: "org.nativescript.devtunnel.restart" });
    const reopened = await second.request(ports, TOKEN, { web: ports + 1 });
    assert.equal(reopened.tunnelPort, ports, "the tunnel port moved after a restart");
    assert.equal(reopened.tunnels.web, ports + 1, "the app port moved after a restart");
    const { body: received } = await get(`http://127.0.0.1:${ports + 1}/after-restart`, false);
    assert.equal(received.toString(), "web /after-restart");
    restartPool.stop();
    await second.kill();
  });

  await check("two apps asking for the same preferred ports: the second moves upward", async () => {
    const ports = await freePorts(6);
    const appA = startRelay({ bundleId: "org.nativescript.devtunnel.a" });
    const appB = startRelay({ bundleId: "org.nativescript.devtunnel.b" });
    const a = await appA.request(ports, undefined, { web: ports + 3 });
    const b = await appB.request(ports, undefined, { web: ports + 3 });
    assert.equal(a.tunnelPort, ports);
    assert.equal(a.tunnels.web, ports + 3);
    assert.ok(b.tunnelPort > ports && b.tunnelPort !== a.tunnels.web, `tunnel port ${b.tunnelPort}`);
    assert.ok(b.tunnels.web > ports + 3 && b.tunnels.web !== b.tunnelPort, `web ${b.tunnels.web}`);
    for (const [relay, opened] of [[appA, a], [appB, b]]) {
      const control = await openControl({ port: opened.tunnelPort });
      assert.equal(control.ready.bundleId, relay.bundleId);
      assert.deepEqual(control.ready.tunnels, opened.tunnels);
      control.close();
      const expected = new RegExp(`tunnel port ${opened.tunnelPort}; web=${opened.tunnels.web}$`);
      await waitFor(() => expected.test(listeningLines(relay).at(-1) ?? ""), 2000, "the listening line");
    }
    await appA.kill();
    await appB.kill();
  });

  await check("a port taken on one loopback family moves both families up together", async () => {
    const ports = await freePorts(3);
    const relay = startRelay({ bundleId: "org.nativescript.devtunnel.family" });
    const blocker6 = await listen(net.createServer(), { port: ports + 1, host: "::1", ipv6Only: true });
    const opened = await relay.request(ports, undefined, { web: ports + 1 });
    assert.equal(opened.tunnels.web, ports + 2);
    assert.ok(await canListen(ports + 1, "127.0.0.1"), "the abandoned 127.0.0.1 port is still bound");
    const open = startPool({ port: ports, targets, size: 1 });
    for (const host of ["127.0.0.1", "[::1]"]) {
      const { body: received } = await get(`http://${host}:${ports + 2}/family`, false);
      assert.equal(received.toString(), "web /family");
    }
    open.stop();
    blocker6.close();
    await relay.kill();
  });

  await check("a wildcard listener on the preferred port is not shadowed", async () => {
    const ports = await freePorts(4);
    const wildcard4 = await listen(net.createServer(), { port: ports, host: "0.0.0.0" });
    const dualStack = await listen(net.createServer(), { port: ports + 2, host: "::" });
    const relay = startRelay({ bundleId: "org.nativescript.devtunnel.wildcard" });
    const opened = await relay.request(ports, undefined, { web: ports + 2 });
    assert.notEqual(opened.tunnelPort, ports);
    assert.notEqual(opened.tunnels.web, ports + 2);
    wildcard4.close();
    dualStack.close();
    await relay.kill();
  });

  await check("the TunnelRequest notification opens the tunnel port, and nothing is open before", async () => {
    const bundleId = `org.nativescript.devtunnel.notify${process.pid}`;
    const relay = startRelay({ bundleId });
    assert.equal(await relay.command("info"), `INFO ${bundleId} 0 -`);
    notify(bundleId);
    await waitFor(() => listeningLines(relay).length === 1, 3000, "the listening log line");
    const port = Number(/tunnel port (\d+); -$/.exec(listeningLines(relay)[0])[1]);
    assert.ok(port >= DEFAULT_TUNNEL_PORT && port < DEFAULT_TUNNEL_PORT + 32, `tunnel port ${port}`);
    assert.equal(await relay.command("info"), `INFO ${bundleId} ${port} -`);
    const control = await openControl({ port });
    assert.equal(control.ready.bundleId, bundleId);
    notify(bundleId);
    await waitFor(() => listeningLines(relay).length === 2, 3000, "the line again for a second notification");
    assert.equal(listeningLines(relay)[1], listeningLines(relay)[0]);
    control.close();
    await relay.kill();
  });

  await check("a token configured after unauthenticated connections drops them", async () => {
    const bundleId = `org.nativescript.devtunnel.late${process.pid}`;
    const relay = startRelay({ bundleId });
    // Answered once the framework is connected, and so registered for the notification.
    await relay.command("info");
    notify(bundleId);
    await waitFor(() => listeningLines(relay).length === 1, 3000, "the tunnel port");
    const port = Number(/tunnel port (\d+);/.exec(listeningLines(relay)[0])[1]);
    const open = startPool({ port, targets, size: 3 });
    await waitFor(() => open.idleCount() === 3, 3000, "unauthenticated pool");
    const control = await openControl({ port });
    const controlClosed = readUntilClosed(control.socket, 3000);
    const webPortLate = await freePorts(1);
    const opened = await relay.request(undefined, "late-token", { web: webPortLate });
    await controlClosed;
    await waitFor(() => open.stats.idleClosed >= 3, 3000, "unauthenticated idle connections closed");
    const response = get(`http://127.0.0.1:${opened.tunnels.web}/late-token`, false);
    await sleep(300);
    assert.equal(open.stats.paired, 0, "an unauthenticated connection was paired");
    assert.ok(open.stats.denied.token > 0, "the old pool should now be asked for a token");
    open.stop();
    const authenticated = startPool({ port, token: "late-token", targets, size: 2 });
    const { body: received } = await response;
    assert.equal(received.toString(), "web /late-token");
    authenticated.stop();
    await relay.kill();
  });

  await check("a tunnel that would push READY past 256 bytes is refused, never truncated", async () => {
    const bundleId = `org.nativescript.${"x".repeat(100 - 17)}`;
    const relay = startRelay({ bundleId });
    const ports = await freePorts(4);
    const opened = await relay.request(ports, TOKEN, { one: ports + 1, two: ports + 2 });
    await assert.rejects(relay.request(undefined, TOKEN, { three: ports + 3 }), /would not fit the 256-byte protocol line/);
    const socket = await connect(opened.tunnelPort);
    const reader = lineReader(socket);
    socket.write(`NSDT/1 HELLO control ${randomBytes(32).toString("hex")}\n`);
    const line = await reader.next();
    assert.ok(line.length + 1 <= 256, `READY is ${line.length + 1} bytes`);
    assert.deepEqual(parseReady(line).tunnels, opened.tunnels);
    socket.destroy();
    await relay.kill();
    const tooLong = startRelay({ bundleId: `org.nativescript.${"y".repeat(130)}` });
    assert.match(await tooLong.command("request - - web=1234"), /^ERROR bundle id .* cannot be sent/);
    await tooLong.kill();
  });

  await check("a release host opens nothing", async () => {
    const bundleId = `org.nativescript.devtunnel.release${process.pid}`;
    const relay = startRelay({ bundleId, release: true });
    assert.match(await relay.command("request - - web=1234"), /^ERROR /);
    notify(bundleId);
    await sleep(500);
    assert.equal(listeningLines(relay).length, 0);
    await relay.kill();
  });

  await check("an app connection with no pool is closed after the pending timeout", async () => {
    const relay = startRelay({ bundleId: "org.nativescript.devtunnel.lonely" });
    const ports = await freePorts(2);
    const opened = await relay.request(ports, undefined, { web: ports + 1 });
    const socket = net.connect({ host: "127.0.0.1", port: opened.tunnels.web });
    const { ms } = await readUntilClosed(socket, 15000);
    // The relay checks pending connections once a second.
    assert.ok(ms >= 9500 && ms < 12500, `closed after ${ms} ms`);
    // The relay closes the connections before it logs.
    await waitFor(
      () => relay.logs.some((line) => line.includes("closed 1 connection(s) to web after 10 s without a tunnel connection")),
      2000,
      "the timeout log line",
    );
    await relay.kill();
  });

  if (args.sanitize) {
    await check("no sanitizer reports from any relay", async () => {
      const reports = relays.flatMap((relay) =>
        relay.logs.filter((line) => /Sanitizer|runtime error:/.test(line)),
      );
      assert.deepEqual(reports, []);
    });
  }

  pool?.stop();
  web.server.close();
  api.server.close();
  for (const relay of relays) relay.child.kill("SIGKILL");
  const failed = results.filter((result) => !result.ok);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  if (!args["out-dir"]) fs.rmSync(outDir, { recursive: true, force: true });
  process.exit(failed.length > 0 || results.length === 0 ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  for (const relay of relays) relay.child.kill("SIGKILL");
  process.exit(1);
});
