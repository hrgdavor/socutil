#!/usr/bin/env bun
// End-to-end test: socutil-cli speaks the fs-meta unix-socket protocol (FORMAT.socket.md).
//
//   zig build && bun cli-test.mjs
//   bun cli-test.mjs --exe /path/to/socutil-cli --fsmeta /path/to/fsmeta
//
// The test builds a scratch trio under fs-meta/.tmp by running `fsmeta refresh`, serves that
// root with `fsmeta serve <root>` (no --http: port 8765 is not part of this protocol), and
// drives socutil-cli over <root>/.fs-meta/socket. The greeting below is hand-encoded from the
// document, not borrowed from either executable: 8-byte prefix (u16 kind, u16 flags, u32
// length, little-endian) plus the fixed 24-byte HELLO payload. After HELLO the client sends
// SUBSCRIBE{from_batch = 0}; the server answers with HELLO and then replays generation 1.
//
// Three properties are asserted beyond the bytes:
//   - the HELLO frame arrives with only the 24-byte greeting on stdin, before any SUBSCRIBE and
//     before any stdin EOF. This is the reported zero-byte symptom: a relay that buffers until
//     its reader is full (readSliceShort) sees nothing here, because the server has sent 32
//     bytes and is waiting for the client's SUBSCRIBE;
//   - at least one replay frame follows while stdin is still open, so the relay is not merely
//     flushing a closed connection's buffer;
//   - the client exits once the server closes the connection, even though stdin was never
//     closed. A relay that joins its stdin pump first stays alive forever in that case.
//
// Prints one `ok` line per check, then PASS, and exits non-zero on the first failure. Every
// wait is bounded and the process/server/socket/scratch trio are torn down in a finally, so a
// failed run cannot leave a process holding a socket path or fsmeta.exe.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const here = import.meta.dir;
const fsMetaDir = process.env.FSMETA_DIR ?? path.resolve(here, "..", "fs-meta");
const scratchBase = path.join(fsMetaDir, ".tmp");

function argValue(name) {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : undefined;
}

const exeName = (stem) => (process.platform === "win32" ? `${stem}.exe` : stem);
const cli = argValue("--exe") ?? path.join(here, "zig-out", "bin", exeName("socutil-cli"));
const fsmeta = argValue("--fsmeta") ?? path.join(fsMetaDir, "zig-out", "bin", exeName("fsmeta"));

for (const [what, file] of [
  ["socutil-cli", cli],
  ["fsmeta", fsmeta],
]) {
  if (!fs.existsSync(file)) {
    console.error(`${what} executable not found at ${file}`);
    console.error(
      what === "fsmeta"
        ? "build it first: zig build (from the fs-meta project root)"
        : "build it first: zig build (from the socutil project root)",
    );
    process.exit(1);
  }
}

// A unique scratch root so a parallel run, or a leftover from an interrupted one, cannot
// collide. fs-meta's .tmp/ is the only place tests are allowed to write.
const root = path.join(
  scratchBase,
  `cli-test-${process.pid.toString(36)}-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`,
);
const socketPath = path.join(root, ".fs-meta", "socket");

// ---------------------------------------------------------------------------- wire format

// FORMAT.socket.md § Framing: kind u16, flags u16, length u32, all little-endian.
function frame(kind, payload) {
  const prefix = Buffer.alloc(8);
  prefix.writeUInt16LE(kind, 0);
  prefix.writeUInt16LE(0, 2); // senders write flags as 0 (§ Multipart)
  prefix.writeUInt32LE(payload.length, 4);
  return Buffer.concat([prefix, payload]);
}

// FORMAT.socket.md § Handshake, byte for byte:
//   u16 protocol (major << 8 | minor)   0..2    this implementation pins 0x0102
//   u16 entry_size                       2..4    64
//   u8  hash_algorithm                   4       0 = wyhash64
//   u8  role                             5       1 = client
//   u8  capabilities                     6       bit 0 snapshot, bit 1 changes_hash
//   u8  reserved                         7       0
//   u64 generation                       8..16   the newest batch this side knows (0 = none)
//   u64 max_frame                        16..24  largest payload accepted (here the 1 MiB cap)
function helloGreeting() {
  const payload = Buffer.alloc(24);
  payload.writeUInt16LE(0x0102, 0);
  payload.writeUInt16LE(64, 2);
  payload.writeUInt8(0, 4); // wyhash64
  payload.writeUInt8(1, 5); // role = client
  payload.writeUInt8(0, 6); // capabilities: no snapshot, no changes_hash
  payload.writeUInt8(0, 7); // reserved
  payload.writeBigUInt64LE(0n, 8); // generation: nothing applied yet
  payload.writeBigUInt64LE(1024n * 1024n, 16); // max_frame
  return frame(0x01, payload);
}

// FORMAT.socket.md § Replay: SUBSCRIBE { u64 from_batch }, 0 = nothing applied.
function subscribe(fromBatch) {
  const payload = Buffer.alloc(8);
  payload.writeBigUInt64LE(BigInt(fromBatch), 0);
  return frame(0x06, payload);
}

const HELLO = 0x01;
const START_BATCH = 0x02;
const CHANGE_ENTRY = 0x03;
const END_BATCH = 0x04;
const KIND_NAMES = new Map([
  [HELLO, "HELLO"],
  [START_BATCH, "START_BATCH"],
  [CHANGE_ENTRY, "CHANGE_ENTRY"],
  [END_BATCH, "END_BATCH"],
  [0x05, "ERROR"],
  [0x06, "SUBSCRIBE"],
  [0x07, "PING"],
  [0x08, "PONG"],
  [0x09, "STATE"],
  [0x0a, "GIT_EVENT"],
]);
const kindName = (kind) => KIND_NAMES.get(kind) ?? `0x${kind.toString(16)}`;

// Run one fsmeta command to completion with a bounded wait. Synchronous spawning would block the
// event loop and with it the watchdog, so even these short commands go through async spawn.
async function runFsmeta(args, label, timeoutMs = 20_000) {
  const child = Bun.spawn([fsmeta, ...args], { stdout: "pipe", stderr: "pipe" });
  const out = [];
  const err = [];
  const outPump = (async () => {
    for await (const chunk of child.stdout) out.push(Buffer.from(chunk));
  })();
  const errPump = (async () => {
    for await (const chunk of child.stderr) err.push(Buffer.from(chunk));
  })();
  const finished = await Promise.race([
    child.exited.then(() => true),
    Bun.sleep(timeoutMs).then(() => false),
  ]);
  if (!finished) {
    try {
      child.kill();
    } catch {}
    throw new Error(`${label} timed out after ${timeoutMs} ms`);
  }
  await Promise.race([Promise.all([outPump, errPump]), Bun.sleep(1000)]);
  return { code: child.exitCode ?? 0, stdout: Buffer.concat(out).toString(), stderr: Buffer.concat(err).toString() };
}

// Decode every complete frame in `buffer` from `offset`, returning the new offset. A frame is
// validated before it is accepted: flags must be 0, the kind must be binary (< 0x7B) and the
// length must respect the 1 MiB cap (§ Framing). A truncated tail is left for the next read.
function decodeFrames(buffer, offset, frames) {
  while (buffer.length - offset >= 8) {
    const kind = buffer.readUInt16LE(offset);
    const flags = buffer.readUInt16LE(offset + 2);
    const length = buffer.readUInt32LE(offset + 4);
    assert.ok(kind > 0 && kind < 0x7b, `frame ${frames.length}: kind ${kind} is not a binary kind`);
    assert.equal(flags, 0, `frame ${frames.length} (${kindName(kind)}): flags must be 0`);
    assert.ok(length <= 1024 * 1024, `frame ${frames.length} (${kindName(kind)}): length ${length} exceeds 1 MiB`);
    if (buffer.length - offset - 8 < length) break;
    frames.push({
      kind,
      flags,
      payload: buffer.subarray(offset + 8, offset + 8 + length),
    });
    offset += 8 + length;
  }
  return offset;
}

let server = null;
let client = null;
let exitCode = 0;
let stdoutChunks = [];
let stderrChunks = [];
let serverOut = [];
let serverErr = [];
let frames = [];
let frameOffset = 0;

// Last-resort guard: every wait below has its own deadline, but a stuck pipe, a hung fsmeta
// refresh or a wedged socket must still fail the run rather than hang a CI job.
const watchdog = setTimeout(() => {
  console.error("\nFAIL: cli-test watchdog fired after 45 s");
  try {
    client?.kill();
  } catch {}
  try {
    server?.kill();
  } catch {}
  try {
    fs.rmSync(root, { recursive: true, force: true });
  } catch {}
  process.exit(1);
}, 45_000);

try {
  // ------------------------------------------------------------------ scratch trio
  fs.mkdirSync(scratchBase, { recursive: true });
  fs.mkdirSync(root, { recursive: true });
  // The scratch trio is a real publish: an empty refresh creates the layout, the second refresh
  // after one file makes generation 1 a published batch, which is what replay will stream.
  for (const step of [1, 2]) {
    if (step === 2) fs.writeFileSync(path.join(root, "greeting.txt"), "hello from cli-test\n");
    const refresh = await runFsmeta(["refresh", root], `fsmeta refresh (step ${step})`);
    if (refresh.code !== 0) {
      throw new Error(
        `fsmeta refresh ${root} failed (${refresh.code}):\n${refresh.stdout}\n${refresh.stderr}`,
      );
    }
    if (step === 2) {
      assert.match(
        refresh.stdout,
        /generation \d+, 1 names, published yes/,
        "the second refresh should publish generation 1 with the file",
      );
    }
  }
  console.log(`ok scratch trio ${root}`);

  // ------------------------------------------------------------------ fsmeta serve
  server = Bun.spawn([fsmeta, "serve", root], { stdout: "pipe", stderr: "pipe" });
  const serverStdout = (async () => {
    for await (const chunk of server.stdout) serverOut.push(Buffer.from(chunk));
  })();
  void (async () => {
    for await (const chunk of server.stderr) serverErr.push(Buffer.from(chunk));
  })();

  {
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const banner = Buffer.concat(serverOut).toString("utf8");
      if (banner.includes("listening on")) break;
      if (server.exitCode !== null) {
        throw new Error(
          `fsmeta serve exited (${server.exitCode}) before listening:\n${Buffer.concat(serverErr).toString()}`,
        );
      }
      await Bun.sleep(20);
    }
    if (!Buffer.concat(serverOut).toString("utf8").includes("listening on")) {
      throw new Error(`fsmeta serve did not print a listening banner:\n${Buffer.concat(serverErr).toString()}`);
    }
  }
  assert.ok(fs.existsSync(socketPath), `the server should have bound ${socketPath}`);
  console.log(`ok fsmeta serve ${socketPath}`);

  // ------------------------------------------------------------------ socutil-cli
  client = Bun.spawn([cli, socketPath], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  void (async () => {
    for await (const chunk of client.stdout) stdoutChunks.push(Buffer.from(chunk));
  })();
  void (async () => {
    for await (const chunk of client.stderr) stderrChunks.push(Buffer.from(chunk));
  })();

  // Send only the greeting first and deliberately keep stdin open. The server has greeted already
  // and is waiting for SUBSCRIBE, so nothing else will arrive until we send it — exactly the shape
  // that produced zero bytes from a buffered relay. Everything below must arrive anyway, and the
  // process must still end when the server closes, with stdin never closed.
  client.stdin.write(helloGreeting());
  await client.stdin.flush();

  const collect = () => {
    frames = [];
    frameOffset = 0;
    frameOffset = decodeFrames(Buffer.concat(stdoutChunks), frameOffset, frames);
  };

  const describe = () => {
    const stdout = Buffer.concat(stdoutChunks);
    const stderr = Buffer.concat(stderrChunks).toString("utf8");
    const kinds = frames.map((f) => kindName(f.kind)).join(", ") || "none";
    return (
      `stdout ${stdout.length} bytes (${stdout.subarray(0, 64).toString("hex") || "empty"}), ` +
      `frames [${kinds}], exit ${client.exitCode}` +
      (stderr ? `\nclient stderr:\n${stderr}` : "") +
      `\nserver stderr:\n${Buffer.concat(serverErr).toString()}`
    );
  };

  // Wait until `predicate` sees enough frames, or fail with the bytes we did get.
  async function waitFor(label, ms, predicate) {
    const deadline = Date.now() + ms;
    for (;;) {
      collect();
      if (predicate()) return;
      if (client.exitCode !== null || Date.now() >= deadline) break;
      await Bun.sleep(10);
    }
    collect();
    if (predicate()) return;
    throw new Error(`timed out after ${ms} ms waiting for ${label}; ${describe()}`);
  }

  // 1. HELLO first, validated field by field against § Handshake.
  await waitFor("the server's HELLO frame", 5000, () => frames.length >= 1);
  {
    const greeting = frames[0];
    assert.equal(greeting.kind, HELLO, `the first frame must be HELLO, got ${kindName(greeting.kind)}`);
    assert.equal(greeting.payload.length, 24, "HELLO's payload is the fixed 24-byte greeting");
    const p = greeting.payload;
    assert.equal(p.readUInt16LE(0) >> 8, 1, "HELLO.protocol major must be 1");
    assert.equal(p.readUInt16LE(2), 64, "HELLO.entry_size must be 64");
    assert.equal(p.readUInt8(4), 0, "HELLO.hash_algorithm must be wyhash64 (0)");
    assert.equal(p.readUInt8(5), 0, "HELLO.role must be server (0)");
    assert.equal(p.readUInt8(6) & ~0x03, 0, "HELLO.capabilities must not set reserved bits");
    assert.equal(p.readUInt8(7), 0, "HELLO.reserved must be 0");
    assert.ok(p.readBigUInt64LE(8) >= 1n, "the server should advertise at least generation 1");
    assert.ok(p.readBigUInt64LE(16) >= 24n, "HELLO.max_frame must at least hold a greeting");
    const protocol = p.readUInt16LE(0);
    console.log(`ok HELLO protocol 0x${protocol.toString(16).padStart(4, "0")}, generation ${p.readBigUInt64LE(8)}`);
  }

  // 2. Now subscribe. At least one further frame follows the greeting, while stdin is still open.
  // On this replay-only server the first one is START_BATCH{1, parent 0}.
  client.stdin.write(subscribe(0));
  await client.stdin.flush();
  await waitFor("at least one frame after HELLO", 5000, () => frames.length >= 2);
  {
    const next = frames[1];
    assert.notEqual(next.kind, HELLO, "the server should not send a second HELLO");
    assert.equal(next.kind, START_BATCH, `the replay should begin with START_BATCH, got ${kindName(next.kind)}`);
    assert.equal(next.payload.length, 24, "START_BATCH is three u64 fields");
    assert.equal(next.payload.readBigUInt64LE(0), 1n, "the first replayed generation is 1");
    assert.equal(next.payload.readBigUInt64LE(8), 0n, "generation 1's parent is 0");
    console.log(`ok ${kindName(next.kind)} ${next.payload.readBigUInt64LE(0)} after HELLO`);
  }

  // 3. The peer closes after replay. The process must exit even though stdin is still open.
  {
    const deadline = Date.now() + 5000;
    while (client.exitCode === null && Date.now() < deadline) await Bun.sleep(20);
    if (client.exitCode === null) {
      throw new Error(
        `socutil-cli did not exit within 5000 ms after the peer closed its side; stdin was never ` +
          `closed, which is the hang this test guards against (t1.join() before the socket pump)`,
      );
    }
    assert.equal(client.exitCode, 0, `socutil-cli should exit 0 after a clean peer close; ${describe()}`);
  }
  // Let the stdout pump see the final bytes before the last decode.
  await new Promise((resolve) => setTimeout(resolve, 50));
  collect();
  console.log(`ok client exited 0 with stdin still open (${frames.length} frames, ${Buffer.concat(stdoutChunks).length} bytes)`);

  // 4. The replay is complete and well-framed: START_BATCH, its CHANGE_ENTRY, END_BATCH.
  {
    const kinds = frames.map((frame) => frame.kind);
    assert.equal(frames.filter((frame) => frame.kind === HELLO).length, 1, "HELLO is sent once");
    assert.ok(kinds.includes(CHANGE_ENTRY), `the replayed batch should carry its entry; kinds ${kinds.map(kindName)}`);
    assert.ok(kinds.includes(END_BATCH), `the replayed batch should end with END_BATCH; kinds ${kinds.map(kindName)}`);
    for (const frame of frames) {
      assert.ok(
        [HELLO, START_BATCH, CHANGE_ENTRY, END_BATCH].includes(frame.kind),
        `unexpected frame kind ${kindName(frame.kind)} from a replay-only server`,
      );
    }
    const end = frames.find((frame) => frame.kind === END_BATCH);
    assert.equal(end.payload.length, 40, "END_BATCH is five u64 fields");
    assert.equal(end.payload.readBigUInt64LE(0), 1n, "END_BATCH closes generation 1");
    const entries = frames.filter((frame) => frame.kind === CHANGE_ENTRY);
    assert.equal(entries.length, 1, "generation 1 added exactly one file, so it has one CHANGE_ENTRY");
    const added = end.payload.readBigUInt64LE(8);
    assert.equal(added, BigInt(entries.length), "END_BATCH.added must match the CHANGE_ENTRY count");
    console.log(`ok replay boundary: START_BATCH 1, ${entries.length} CHANGE_ENTRY, END_BATCH added=${added}`);
  }

  console.log("PASS");
} catch (error) {
  console.error("\nFAIL: " + (error?.stack ?? error));
  console.error(
    "server stdout:\n" +
      Buffer.concat(serverOut).toString("utf8") +
      "\nserver stderr:\n" +
      Buffer.concat(serverErr).toString("utf8"),
  );
  if (stdoutChunks.length) {
    console.error("client stdout: " + Buffer.concat(stdoutChunks).subarray(0, 256).toString("hex"));
  }
  if (stderrChunks.length) {
    console.error("client stderr:\n" + Buffer.concat(stderrChunks).toString("utf8"));
  }
  exitCode = 1;
} finally {
  clearTimeout(watchdog);
  await teardown();
  process.exit(exitCode);
}

// Bounded teardown: close the client's stdin, kill both processes, wait a moment for each, and
// remove the scratch trio. Every step is individually tolerant so one failure cannot hide the
// others, and nothing here can block the run.
async function teardown() {
  try {
    await client?.stdin?.end();
  } catch {}
  for (const [name, child] of [
    ["socutil-cli", client],
    ["fsmeta", server],
  ]) {
    if (!child || child.exitCode !== null) continue;
    try {
      child.kill();
    } catch {}
    // `exited` resolving is the reliable signal: a force-killed process can have a null
    // exitCode on Windows, so polling exitCode would warn about a process that is already gone.
    const exited = await Promise.race([
      child.exited.then(() => true),
      Bun.sleep(2000).then(() => false),
    ]).catch(() => true);
    if (!exited) console.error(`warning: ${name} (${child.pid}) did not exit after kill`);
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    try {
      fs.rmSync(root, { recursive: true, force: true });
      return;
    } catch {
      await Bun.sleep(100);
    }
  }
  console.error(`warning: could not remove scratch root ${root}`);
}
