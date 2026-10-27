#!/usr/bin/env bun
// End-to-end test: a real unix-socket fixture, a real socutil process, real HTTP.
//
//   zig build && bun e2e.mjs
//   bun e2e.mjs --exe /path/to/socutil
//
// The test binds the server to port 0 and reads the port it actually took from the server's own
// "listening on" line, so it never collides with a socutil a person is using. The SSE half talks raw
// HTTP over a TCP socket instead of through fetch: the point is the wire, and a client library that
// buffers an event stream tests the library instead.
//
// Prints one `ok` line per check, then PASS, and exits non-zero on the first failure. It always tears
// down the process and the fixture socket, including on failure, so a failed run leaves nothing bound.
import assert from "node:assert/strict";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";

const here = import.meta.dir;
const scratch = path.join(here, ".tmp", "socutil-e2e");
const sockDir = path.join(scratch, "sockdir");
const sockPath = path.join(sockDir, "demo.sock");

const argv = process.argv.slice(2);
const at = argv.indexOf("--exe");
const exe =
  at >= 0
    ? argv[at + 1]
    : path.join(here, "zig-out", "bin", process.platform === "win32" ? "socutil.exe" : "socutil");

if (!exe) {
  console.error("--exe needs a path to the socutil executable");
  process.exit(2);
}
if (!fs.existsSync(exe)) {
  console.error(`socutil executable not found at ${exe}`);
  console.error("build it first: zig build (from the project root) - see README.md");
  process.exit(1);
}

fs.mkdirSync(sockDir, { recursive: true });
fs.rmSync(sockPath, { force: true });

const fixture = net.createServer((socket) => {
  socket.write("demo online\n");
  socket.on("data", (data) => {
    const line = data.toString("utf8");
    if (line.trim() === "quit") {
      socket.end("bye\n");
      return;
    }
    socket.write("echo:" + line);
  });
});
await new Promise((resolve, reject) => {
  fixture.once("error", reject);
  fixture.listen(sockPath, resolve);
});

const server = Bun.spawn([exe, "--port", "0", "--dir", sockDir], {
  stdout: "pipe",
  stderr: "pipe",
});
const stderrChunks = [];
void (async () => {
  for await (const chunk of server.stderr) stderrChunks.push(Buffer.from(chunk));
})();

let base;
{
  let output = "";
  const reader = server.stdout.getReader();
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    output += Buffer.from(value).toString("utf8");
    const match = /socutil listening on (http:\/\/[^\s/]+)\//.exec(output);
    if (match) {
      base = match[1];
      break;
    }
  }
  if (!base) {
    console.error("socutil did not print a listening URL; stderr:\n" + Buffer.concat(stderrChunks).toString("utf8"));
    await teardown(1);
  }
}

async function get(pathname) {
  return fetch(base + pathname);
}

// A raw HTTP/1.1 request, resolved with the whole response once the server closes it.
function rawRequest(requestText, host = "127.0.0.1") {
  const { port } = new URL(base);
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port: Number(port) });
    let buffer = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`timeout; got:\n${buffer.slice(0, 2000)}`));
    }, 10_000);
    socket.on("connect", () => socket.write(requestText));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    socket.on("end", () => {
      clearTimeout(timer);
      resolve(buffer);
    });
  });
}

function rawGet(requestPath) {
  return rawRequest(
    `GET ${requestPath} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`,
  );
}

function upgradeRequest(id, socketName, version = "13") {
  return (
    `GET /api/ws?id=${id}&name=${encodeURIComponent(socketName)} HTTP/1.1\r\n` +
    `Host: 127.0.0.1\r\n` +
    `Upgrade: websocket\r\n` +
    `Connection: Upgrade\r\n` +
    `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n` +
    `Sec-WebSocket-Version: ${version}\r\n` +
    `\r\n`
  );
}

async function socketName(file) {
  const listing = await (await get("/api/sockets")).json();
  const entry = listing.sockets.find((socket) => socket.file === file);
  if (!entry) throw new Error(`socket ${file} is not listed`);
  return entry.name;
}

function tunnelUrl(id, socketName) {
  const url = new URL(base);
  url.protocol = "ws:";
  url.pathname = "/api/ws";
  url.search = new URLSearchParams({ id, name: socketName }).toString();
  return url;
}

// The WebSocket tunnel: decodes binary frames into one text buffer, and lets
// the caller wait for a match or for the close event.
class Tunnel {
  constructor(id, socketName) {
    this.ws = new WebSocket(tunnelUrl(id, socketName));
    this.ws.binaryType = "arraybuffer";
    this.received = "";
    this.closed = null;
    this.ws.addEventListener("message", (event) => {
      this.received +=
        typeof event.data === "string"
          ? event.data
          : new TextDecoder().decode(event.data, { stream: true });
    });
    this.ws.addEventListener("close", (event) => {
      this.closed = event;
    });
  }

  opened() {
    if (this.ws.readyState === WebSocket.OPEN) return Promise.resolve();
    return new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", () => reject(new Error("websocket failed to open")), {
        once: true,
      });
    });
  }

  send(text) {
    this.ws.send(new TextEncoder().encode(text));
  }

  async waitForText(text, label) {
    const deadline = Date.now() + 10_000;
    while (!this.received.includes(text)) {
      if (Date.now() >= deadline) {
        throw new Error(`timed out waiting for ${label}; got ${JSON.stringify(this.received)}`);
      }
      await Bun.sleep(20);
    }
  }

  async waitForClose() {
    const deadline = Date.now() + 10_000;
    while (this.closed === null) {
      if (Date.now() >= deadline) throw new Error("timed out waiting for the close frame");
      await Bun.sleep(20);
    }
    return this.closed;
  }

  close() {
    this.ws.close();
  }
}

// The SSE session: reads events from one raw request, and lets the caller await them in order.
class SseSession {
  constructor() {
    const { port } = new URL(base);
    this.socket = net.createConnection({ host: "127.0.0.1", port: Number(port) });
    this.buffer = "";
    this.events = [];
    this.waiters = [];
    this.ended = false;
    this.error = null;

    this.socket.on("data", (chunk) => this.feed(chunk.toString("utf8")));
    this.socket.on("end", () => {
      this.ended = true;
      this.wake();
    });
    this.socket.on("error", (error) => {
      this.error = error;
      this.ended = true;
      this.wake();
    });
  }

  open(requestPath) {
    this.socket.write(
      `GET ${requestPath} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`,
    );
    return this;
  }

  feed(text) {
    this.buffer += text.replace(/\r\n/g, "\n");
    // Drop the HTTP head once, then keep parsing event blocks. Chunk-size lines between events are
    // ignored by the line parser below, so chunked framing needs no special case.
    if (!this.headersSeen) {
      const end = this.buffer.indexOf("\n\n");
      if (end === -1) return;
      this.head = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end + 2);
      this.headersSeen = true;
    }

    let split;
    while ((split = this.buffer.indexOf("\n\n")) !== -1) {
      const block = this.buffer.slice(0, split);
      this.buffer = this.buffer.slice(split + 2);
      if (block.startsWith(":")) continue;
      let event = "message";
      let data = "";
      for (const line of block.split("\n")) {
        if (line.startsWith("event:")) event = line.slice(6).trim();
        else if (line.startsWith("data:")) data += line.slice(5).trim();
      }
      if (event === "message" && data === "") continue;
      this.events.push({ event, data });
    }
    this.wake();
  }

  wake() {
    while (this.waiters.length !== 0) {
      const waiter = this.waiters[0];
      if (this.events.length !== 0) {
        this.waiters.shift();
        waiter.resolve(this.events.shift());
      } else if (this.ended) {
        this.waiters.shift();
        waiter.reject(this.error ?? new Error("SSE stream ended before the expected event"));
      } else {
        return;
      }
    }
  }

  next(timeoutMs = 10_000) {
    if (this.events.length !== 0) return Promise.resolve(this.events.shift());
    if (this.ended) return Promise.reject(this.error ?? new Error("SSE stream already ended"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("timed out waiting for the next SSE event"));
      }, timeoutMs);
      this.waiters.push({
        resolve: (event) => {
          clearTimeout(timer);
          resolve(event);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
    });
  }

  close() {
    this.socket.destroy();
  }
}

function assertStatus(response, expected, label) {
  assert.equal(response.status, expected, `${label}: expected ${expected}, got ${response.status}`);
}

try {
  {
    const response = await get("/");
    assertStatus(response, 200, "GET /");
    assert.match(response.headers.get("content-type") ?? "", /^text\/html/);
    assert.match(await response.text(), /socutil/);
    console.log("ok static index");
  }

  {
    const response = await get("/app.js");
    assertStatus(response, 200, "GET /app.js");
    assert.match(response.headers.get("content-type") ?? "", /javascript/);
    console.log("ok embedded script");
  }

  {
    const response = await get("/style.css");
    assertStatus(response, 200, "GET /style.css");
    assert.match(response.headers.get("content-type") ?? "", /text\/css/);
    console.log("ok embedded stylesheet");
  }

  let demoName;
  {
    const response = await get("/api/sockets");
    assertStatus(response, 200, "GET /api/sockets");
    const listing = await response.json();
    assert.ok(
      listing.dirs.some((dir) => dir.path === sockDir),
      "the scanned directory should be reported",
    );
    assert.ok(
      listing.dirs.some((dir) => dir.name === "sockdir"),
      "the directory should carry a configured name",
    );
    const found = listing.sockets.find((entry) => entry.file === "demo.sock");
    assert.ok(found, "demo.sock should be listed");
    assert.equal(found.name, "sockdir.demo.sock", "the API name is <dir-name>.<file-name>");
    assert.equal(found.dirName, "sockdir");
    assert.equal(found.path, sockPath, "the path is listed for display");
    demoName = found.name;
    console.log("ok socket listing", found.name, "->", found.path);
  }

  const sessionId = crypto.randomUUID();
  const sse = new SseSession().open(
    "/api/events?" + new URLSearchParams({ id: sessionId, name: demoName }).toString(),
  );

  try {
    const ready = await sse.next();
    assert.equal(ready.event, "ready", "first event should be ready");
    const readyData = JSON.parse(ready.data);
    assert.equal(readyData.path, sockPath);
    assert.match(sse.head ?? "", /^HTTP\/1\.1 200/);
    assert.match(sse.head ?? "", /text\/event-stream/);
    console.log("ok SSE ready");

    const input = (body) =>
      fetch(base + "/api/input?" + new URLSearchParams({ id: sessionId }).toString(), {
        method: "POST",
        body,
      });

    let response = await input("hello\n");
    assertStatus(response, 200, "POST /api/input hello");
    assert.deepEqual(await response.json(), { ok: true, written: 6 });

    let output = "";
    for (;;) {
      const event = await sse.next();
      assert.equal(event.event, "out", `unexpected event ${event.event}`);
      output += Buffer.from(JSON.parse(event.data).b, "base64").toString("utf8");
      if (output.includes("echo:hello")) break;
    }
    assert.ok(output.includes("demo online"), "the fixture greeting should arrive");
    console.log("ok socket round trip", JSON.stringify(output));

    response = await input("quit\n");
    assertStatus(response, 200, "POST /api/input quit");

    for (;;) {
      const event = await sse.next();
      if (event.event === "out") {
        const text = Buffer.from(JSON.parse(event.data).b, "base64").toString("utf8");
        if (text.includes("bye")) output += text;
        continue;
      }
      assert.equal(event.event, "exit");
      assert.equal(JSON.parse(event.data).reason, "eof");
      break;
    }
    assert.ok(output.includes("bye"), "the fixture's farewell should arrive before the exit event");
    console.log("ok exit event");
  } finally {
    sse.close();
  }

  {
    const response = await fetch(
      base + "/api/input?" + new URLSearchParams({ id: sessionId }).toString(),
      { method: "POST", body: "nope\n" },
    );
    assertStatus(response, 404, "POST to a finished session");
    console.log("ok finished session rejected");
  }

  {
    const tunnel = new Tunnel(crypto.randomUUID(), demoName);
    await tunnel.opened();
    await tunnel.waitForText("demo online", "the WebSocket greeting");
    tunnel.send("hello\n");
    await tunnel.waitForText("echo:hello", "the WebSocket echo");
    tunnel.send("quit\n");
    const closed = await tunnel.waitForClose();
    assert.equal(closed.code, 1000, "a socket EOF should close normally");
    assert.match(closed.reason, /eof/);
    assert.ok(tunnel.received.includes("bye"), "the farewell should arrive before the close");
    console.log("ok websocket byte tunnel", JSON.stringify(tunnel.received));
  }

  {
    const binaryPath = path.join(sockDir, "binary.sock");
    fs.rmSync(binaryPath, { force: true });
    const greeting = [0x00, 0xff, 0x10, 0x7f];
    const binaryFixture = net.createServer((socket) => {
      socket.write(Buffer.from(greeting));
      socket.on("data", (data) => socket.write(data));
    });
    await new Promise((resolve, reject) => {
      binaryFixture.once("error", reject);
      binaryFixture.listen(binaryPath, resolve);
    });

    try {
      const binaryName = await socketName("binary.sock");
      const ws = new WebSocket(tunnelUrl(crypto.randomUUID(), binaryName));
      ws.binaryType = "arraybuffer";
      const chunks = [];
      let received = 0;
      ws.addEventListener("message", (event) => {
        const bytes = new Uint8Array(event.data);
        chunks.push(Buffer.from(bytes));
        received += bytes.length;
      });
      await new Promise((resolve, reject) => {
        ws.addEventListener("open", resolve, { once: true });
        ws.addEventListener("error", () => reject(new Error("websocket failed to open")), { once: true });
      });

      const deadline = Date.now() + 10_000;
      while (received < greeting.length && Date.now() < deadline) await Bun.sleep(20);
      const before = Buffer.concat(chunks);
      assert.deepEqual([...before.subarray(0, greeting.length)], greeting, "the greeting must be byte-exact");

      const payload = Uint8Array.of(0x00, 0x01, 0x02, 0xff);
      ws.send(payload);
      while (received < greeting.length + payload.length && Date.now() < deadline) await Bun.sleep(20);
      const after = Buffer.concat(chunks);
      assert.deepEqual(
        [...after.subarray(greeting.length, greeting.length + payload.length)],
        [...payload],
        "the echo must be byte-exact",
      );
      ws.close();
      console.log("ok websocket is byte-exact");
    } finally {
      await new Promise((resolve) => binaryFixture.close(resolve));
      fs.rmSync(binaryPath, { force: true });
    }
  }

  {
    const tunnel = new Tunnel(crypto.randomUUID(), demoName);
    await tunnel.opened();
    tunnel.ws.send(new Uint8Array(100 * 1024));
    const closed = await tunnel.waitForClose();
    assert.equal(closed.code, 1009, "a frame over the 64 KiB buffer must be refused with 1009");
    assert.match(closed.reason, /too big/);
    console.log("ok websocket oversize refused");
  }

  {
    const response = await get(
      "/api/ws?" + new URLSearchParams({ id: "plain", name: demoName }).toString(),
    );
    assertStatus(response, 426, "GET /api/ws without an upgrade");
    console.log("ok websocket requires an upgrade");
  }

  {
    const raw = await rawRequest(upgradeRequest("bad-version", demoName, "8"));
    assert.match(raw, /^HTTP\/1\.1 400/, "a version other than 13 must be refused");
    console.log("ok websocket version is checked");
  }

  {
    const raw = await rawRequest(upgradeRequest("outside", sockPath));
    assert.match(
      raw,
      /^HTTP\/1\.1 404/,
      "a path sent where a name belongs must not resolve to a socket",
    );
    console.log("ok websocket refuses a path as a name");
  }

  {
    const id = crypto.randomUUID();
    const tunnel = new Tunnel(id, demoName);
    await tunnel.opened();
    const response = await fetch(base + "/api/close?id=" + id, { method: "POST" });
    assertStatus(response, 200, "POST /api/close on a websocket session");
    await tunnel.waitForClose();
    console.log("ok websocket session closed by the API");
  }

  {
    const response = await fetch(base + "/api/sockets", { method: "POST" });
    assertStatus(response, 405, "POST /api/sockets");
    assert.match(response.headers.get("allow") ?? "", /GET/);
    console.log("ok method not allowed");
  }

  {
    const response = await get("/does-not-exist");
    assertStatus(response, 404, "GET /does-not-exist");
    console.log("ok unknown asset is 404");
  }

  {
    const response = await get(
      "/api/events?id=has%20space&name=" + encodeURIComponent(demoName),
    );
    assertStatus(response, 400, "invalid session id");
    console.log("ok invalid session id is rejected");
  }

  {
    const response = await get("/api/events?id=path-attempt&path=" + encodeURIComponent(sockPath));
    assertStatus(response, 400, "a path is not a selector");
    console.log("ok path parameters are refused");
  }

  {
    const response = await get("/api/ws?id=path-attempt&path=" + encodeURIComponent(sockPath));
    assertStatus(response, 400, "a path is not a selector");
    console.log("ok websocket path parameters are refused");
  }

  {
    const response = await get(
      "/api/events?" + new URLSearchParams({ id: "outside", name: sockPath }).toString(),
    );
    assertStatus(response, 404, "a path sent as a name is not a socket");
    console.log("ok a path sent as a name is rejected");
  }

  {
    const raw = await rawGet("/api/sockets");
    assert.match(raw, /^HTTP\/1\.1 200/);
    assert.match(raw, /"file":"demo\.sock"/);
    assert.match(raw, /"name":"sockdir\.demo\.sock"/);
    console.log("ok raw HTTP response");
  }

  console.log("PASS");
} catch (error) {
  console.error("\nFAIL: " + (error?.stack ?? error));
  console.error("server stderr:\n" + Buffer.concat(stderrChunks).toString("utf8"));
  await teardown(1);
} finally {
  await teardown(0);
}

async function teardown(code) {
  try {
    server.kill();
  } catch {}
  try {
    await Promise.race([server.exited, Bun.sleep(2000)]);
  } catch {}
  try {
    await new Promise((resolve) => fixture.close(resolve));
  } catch {}
  fs.rmSync(sockPath, { force: true });
  process.exit(code);
}
