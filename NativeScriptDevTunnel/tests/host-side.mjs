// The Mac side of the dev tunnel protocol (docs/dev-tunnel.md), for the host
// test harness: the handshake, a pool of idle connections that dials a target
// per tunnel name when the relay pairs one, and a control connection. The
// transport is plain TCP to the relay's tunnel port; a real tool reaches the
// device's port through usbmux instead.
import { createHmac, randomBytes } from "node:crypto";
import net from "node:net";

const RETRY_MIN_MS = 50;
const RETRY_MAX_MS = 200;
const LINE_MAX_BYTES = 256;

export const hmacHex = (token, data) => createHmac("sha256", token).update(data).digest("hex");

export function parseTunnels(list) {
  const tunnels = {};
  if (list !== "-") {
    for (const entry of list.split(",")) {
      const [name, port] = entry.split("=");
      tunnels[name] = Number(port);
    }
  }
  return tunnels;
}

// "NSDT/1 READY <bundleId> <pid> <tunnelPort> <tunnels> <nonce> <proof>"
export function parseReady(line) {
  const fields = line.split(" ");
  if (fields.length !== 8 || fields[0] !== "NSDT/1" || fields[1] !== "READY") {
    return null;
  }
  return {
    bundleId: fields[2],
    pid: Number(fields[3]),
    tunnelPort: Number(fields[4]),
    tunnels: parseTunnels(fields[5]),
    nonce: fields[6],
    proof: fields[7],
  };
}

export class ProtocolError extends Error {
  constructor(message, reason) {
    super(message);
    this.reason = reason;
  }
}

// Reads '\n'-terminated lines off a socket that may also carry raw bytes
// after them: `next()` resolves with the next line, `rest()` hands back what
// came after the last line read and stops reading.
export function lineReader(socket) {
  let buffer = Buffer.alloc(0);
  let waiter = null;
  let ended = false;
  const settle = () => {
    if (waiter === null) return;
    const index = buffer.indexOf(10);
    if (index !== -1) {
      const line = buffer.subarray(0, index).toString("latin1");
      buffer = buffer.subarray(index + 1);
      const { resolve } = waiter;
      waiter = null;
      resolve(line);
    } else if (buffer.length >= LINE_MAX_BYTES) {
      const { reject } = waiter;
      waiter = null;
      reject(new ProtocolError("line too long", "protocol"));
    } else if (ended) {
      const { reject } = waiter;
      waiter = null;
      reject(new ProtocolError("connection closed", "closed"));
    }
  };
  const onData = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    settle();
  };
  const onEnd = () => {
    ended = true;
    settle();
  };
  socket.on("data", onData);
  socket.on("end", onEnd);
  socket.on("close", onEnd);
  return {
    next() {
      return new Promise((resolve, reject) => {
        waiter = { resolve, reject };
        settle();
      });
    },
    rest() {
      socket.off("data", onData);
      socket.off("end", onEnd);
      socket.off("close", onEnd);
      return buffer;
    },
  };
}

export function connect(port, host = "127.0.0.1") {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port, allowHalfOpen: true });
    socket.once("error", reject);
    socket.once("connect", () => {
      socket.off("error", reject);
      resolve(socket);
    });
  });
}

// Runs HELLO / READY / AUTH. Verifies the relay's proof before answering, so
// a relay that does not know the token never sees a valid AUTH.
export async function handshake(socket, { role, token, reader = lineReader(socket) }) {
  const hostNonce = randomBytes(16);
  socket.write(`NSDT/1 HELLO ${role} ${hostNonce.toString("hex")}\n`);
  const line = await reader.next();
  const ready = parseReady(line);
  if (ready === null) {
    const deny = /^NSDT\/1 DENY (\S+)$/.exec(line);
    throw new ProtocolError(`relay answered: ${line}`, deny ? deny[1] : "protocol");
  }
  if (token) {
    if (ready.proof !== hmacHex(token, hostNonce)) {
      throw new ProtocolError("the relay's proof does not match the token", "proof");
    }
    socket.write(`NSDT/1 AUTH ${hmacHex(token, Buffer.from(ready.nonce, "hex"))}\n`);
  } else if (ready.proof !== "-") {
    throw new ProtocolError("the relay requires a token", "token");
  }
  return { ready, reader };
}

/**
 * Keeps `size` authenticated idle connections to the relay's tunnel port.
 * When the relay pairs one (PAIR), dials `targets[name]` and pipes both ways.
 * `targets` is read at pairing time, so tests may add names later.
 * @param {{ port: number, host?: string, token?: string, targets: Record<string, {host: string, port: number}>, size?: number }} options
 */
export function startPool(options) {
  const size = options.size ?? 8;
  const stats = {
    opened: 0,
    paired: 0,
    pairedByName: {},
    unknownName: 0,
    idleClosed: 0,
    connectFailures: 0,
    handshakeFailures: 0,
    denied: {},
    activePairs: 0,
    bundleIds: new Set(),
  };
  const idle = new Set();
  let connecting = 0;
  let retryDelay = RETRY_MIN_MS;
  let retryTimer = null;
  let stopped = false;

  function fill() {
    if (stopped || retryTimer) return;
    while (idle.size + connecting < size) openOne();
  }

  function scheduleRetry() {
    if (stopped || retryTimer) return;
    retryTimer = setTimeout(() => {
      retryTimer = null;
      fill();
    }, retryDelay);
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
  }

  async function openOne() {
    connecting++;
    let socket;
    try {
      socket = await connect(options.port, options.host);
    } catch {
      connecting--;
      stats.connectFailures++;
      scheduleRetry();
      return;
    }
    socket.on("error", () => {});
    try {
      const { ready, reader } = await handshake(socket, { role: "pool", token: options.token });
      stats.bundleIds.add(ready.bundleId);
      connecting--;
      adopt(socket, reader.rest());
    } catch (error) {
      connecting--;
      stats.handshakeFailures++;
      stats.denied[error.reason] = (stats.denied[error.reason] ?? 0) + 1;
      socket.destroy();
      scheduleRetry();
    }
  }

  function adopt(socket, leftover) {
    if (stopped) {
      socket.destroy();
      return;
    }
    socket.setNoDelay(true);
    retryDelay = RETRY_MIN_MS;
    stats.opened++;
    idle.add(socket);
    let state = "idle";
    let header = leftover;
    // With allowHalfOpen an idle socket the relay closed only ends.
    const onIdleGone = () => {
      if (state !== "idle") return;
      state = "closed";
      idle.delete(socket);
      stats.idleClosed++;
      socket.destroy();
      fill();
    };
    const onData = (chunk) => {
      header = Buffer.concat([header, chunk]);
      const index = header.indexOf(10);
      if (index === -1) {
        if (header.length >= LINE_MAX_BYTES) onIdleGone();
        return;
      }
      socket.off("data", onData);
      socket.pause();
      const line = header.subarray(0, index).toString("latin1");
      const appBytes = header.subarray(index + 1);
      const match = /^NSDT\/1 PAIR (\S+) (\d+) (\d+)$/.exec(line);
      if (!match) {
        onIdleGone();
        return;
      }
      state = "paired";
      idle.delete(socket);
      const name = match[1];
      const target = options.targets[name];
      if (!target) {
        stats.unknownName++;
        socket.destroy();
        fill();
        return;
      }
      stats.paired++;
      stats.pairedByName[name] = (stats.pairedByName[name] ?? 0) + 1;
      stats.activePairs++;
      const upstream = net.connect({ host: target.host, port: target.port, allowHalfOpen: true });
      upstream.setNoDelay(true);
      if (appBytes.length > 0) upstream.write(appBytes);
      upstream.once("connect", () => {
        socket.pipe(upstream);
        upstream.pipe(socket);
        socket.resume();
      });
      const finish = () => {
        socket.destroy();
        upstream.destroy();
      };
      upstream.on("error", finish);
      socket.on("error", finish);
      let closed = 0;
      const onClose = () => {
        if (++closed === 2) stats.activePairs--;
      };
      socket.once("close", onClose);
      upstream.once("close", onClose);
      fill();
    };
    socket.on("data", onData);
    socket.once("end", onIdleGone);
    socket.once("close", onIdleGone);
    socket.resume();
  }

  fill();
  return {
    stats,
    idleCount: () => idle.size,
    stop() {
      stopped = true;
      if (retryTimer) clearTimeout(retryTimer);
      for (const socket of idle) socket.destroy();
      idle.clear();
    },
  };
}

/** A control connection: `command(line)` resolves with the relay's answer. */
export async function openControl({ port, host, token }) {
  const socket = await connect(port, host);
  socket.on("error", () => {});
  const { ready, reader } = await handshake(socket, { role: "control", token });
  return {
    ready,
    socket,
    async command(line) {
      socket.write(`${line}\n`);
      return reader.next();
    },
    close() {
      socket.destroy();
    },
  };
}
