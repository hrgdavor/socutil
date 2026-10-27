#!/usr/bin/env bun
// Drive the socutil page in a real browser over CDP: list, connect, send, receive, disconnect.
//
//   bun ui-smoke.mjs
//   bun ui-smoke.mjs --chrome /path/to/chrome
//
// This is the half `e2e.mjs` cannot see: it proves the embedded page's own wiring (EventSource, base64
// decoding, the form, the status line) against a real engine. It needs a Chromium-compatible browser;
// when none is found it prints SKIP and exits 0, because the server-side e2e is the mandatory test and
// this one is an enhancement. Set CHROME to point at one that is not in the usual place.
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

const here = import.meta.dir;
const scratch = path.join(here, ".tmp", "socutil-ui-smoke");
const sockDir = path.join(scratch, "sockdir");
const sockPath = path.join(sockDir, "demo.sock");
const profile = path.join(scratch, "chrome-profile");
const exe = path.join(here, "zig-out", "bin", process.platform === "win32" ? "socutil.exe" : "socutil");

const argv = process.argv.slice(2);
const chromeAt = argv.indexOf("--chrome");
const candidates = [
  chromeAt >= 0 ? argv[chromeAt + 1] : undefined,
  process.env.CHROME,
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, "Google", "Chrome", "Application", "chrome.exe") : undefined,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
].filter(Boolean);
const chrome = candidates.find((candidate) => fs.existsSync(candidate));

if (!chrome) {
  console.log("SKIP: no Chromium-compatible browser found (set CHROME or use --chrome)");
  process.exit(0);
}
if (!fs.existsSync(exe)) {
  console.error(`socutil executable not found at ${exe}`);
  console.error("build it first: zig build (from the project root) - see README.md");
  process.exit(1);
}

fs.mkdirSync(sockDir, { recursive: true });
fs.rmSync(sockPath, { force: true });
fs.rmSync(profile, { recursive: true, force: true });

const fixture = net.createServer((socket) => {
  socket.write("demo online\n");
  socket.on("data", (data) => {
    if (data.toString("utf8").trim() === "bye") return socket.end();
    socket.write("echo:" + data.toString("utf8"));
  });
});
await new Promise((resolve, reject) => {
  fixture.once("error", reject);
  fixture.listen(sockPath, resolve);
});

const server = Bun.spawn([exe, "--port", "0", "--dir", sockDir], { stdout: "pipe", stderr: "pipe" });
let chromeProcess;

const cleanup = () => {
  try {
    chromeProcess?.kill();
  } catch {}
  try {
    server.kill();
  } catch {}
  try {
    fixture.close();
  } catch {}
  fs.rmSync(sockPath, { force: true });
};
process.on("exit", cleanup);

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
    console.error("socutil did not print a listening URL");
    await stop(1);
  }
}

let cdpPort;
for (let port = 9224; port < 9240 && !chromeProcess; port += 1) {
  const child = spawn(
    chrome,
    [
      "--headless=new",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      base + "/",
    ],
    { stdio: "ignore" },
  );
  await Bun.sleep(400);
  if (child.exitCode === null) {
    chromeProcess = child;
    cdpPort = port;
  }
}
if (!chromeProcess) {
  console.error("could not start a browser with a debugging port");
  await stop(1);
}

async function target() {
  for (let i = 0; i < 60; i += 1) {
    try {
      const listing = await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json();
      const page = listing.find((entry) => entry.type === "page" && entry.url.startsWith(base));
      if (page) return page;
    } catch {}
    await Bun.sleep(200);
  }
  throw new Error("the browser never offered a page target");
}

const page = await target();
const socket = new WebSocket(page.webSocketDebuggerUrl);
let next = 1;
const pending = new Map();
const exceptions = [];
socket.addEventListener("message", (message) => {
  const data = JSON.parse(message.data);
  if (data.method === "Runtime.exceptionThrown") {
    exceptions.push(
      data.params.exceptionDetails.exception?.description ?? data.params.exceptionDetails.text,
    );
  }
  const waiter = pending.get(data.id);
  if (waiter) {
    pending.delete(data.id);
    waiter(data);
  }
});
await new Promise((resolve) => socket.addEventListener("open", resolve));
await send("Runtime.enable", {});

function send(method, params) {
  return new Promise((resolve) => {
    const id = next++;
    pending.set(id, resolve);
    socket.send(JSON.stringify({ id, method, params }));
  });
}

const evaluate = async (expression) => {
  const answer = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (answer.result?.exceptionDetails) {
    throw new Error(
      answer.result.exceptionDetails.exception?.description ?? answer.result.exceptionDetails.text,
    );
  }
  return answer.result?.result?.value;
};

async function waitFor(expression, label, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return;
    await Bun.sleep(100);
  }
  throw new Error("timed out waiting for " + label);
}

const report = [];
const check = (name, ok, detail = "") =>
  report.push(`${ok ? "ok  " : "FAIL"} ${name}${detail ? " - " + detail : ""}`);

async function scenario(label, kind) {
  await waitFor("document.querySelectorAll('.socket').length === 1", `the socket list (${label})`);
  check(
    `[${label}] the page lists the fixture socket`,
    String(await evaluate("document.querySelector('.socket').title")) === sockPath,
  );
  check(
    `[${label}] the page reports idle`,
    String(await evaluate("document.getElementById('status').textContent")) === "idle",
  );

  await evaluate("document.querySelector('.socket').click(); true");
  await waitFor("document.getElementById('input').disabled === false", `the input to enable (${label})`);
  check(
    `[${label}] connecting enables input`,
    String(await evaluate("document.getElementById('status').textContent")) === "connected",
  );
  const actualKind = String(await evaluate("state.session && state.session.kind"));
  check(
    `[${label}] the session uses the ${kind} transport`,
    actualKind === kind,
    JSON.stringify(actualKind),
  );
  check(
    `[${label}] the session selects the socket by name`,
    String(await evaluate("state.session && state.session.name")) === "sockdir.demo.sock",
  );
  check(
    `[${label}] the page keeps the path for display only`,
    String(await evaluate("document.querySelector('.socket').title")) === sockPath,
  );
  await waitFor(
    "document.getElementById('output').textContent.includes('demo online')",
    `the greeting (${label})`,
  );

  await evaluate(
    "const input=document.getElementById('input'); input.value='hello'; document.getElementById('input-form').requestSubmit(); true",
  );
  await waitFor(
    "document.getElementById('output').textContent.includes('echo:hello')",
    `the echo (${label})`,
  );

  await evaluate("document.getElementById('disconnect').click(); true");
  await waitFor("document.getElementById('status').textContent === 'idle'", `the disconnect (${label})`);
  check(
    `[${label}] disconnect resets the page`,
    String(await evaluate("document.getElementById('target').textContent")) === "not connected",
  );
}

try {
  await scenario("ws", "ws");

  // The same page over the tail transport, reloaded with ?transport=sse.
  await send("Page.navigate", { url: base + "/?transport=sse" });
  await scenario("sse", "sse");

  check("no page exception was thrown", exceptions.length === 0, exceptions.join(" | "));
} catch (error) {
  report.push("FAIL " + (error?.stack ?? error));
}

console.log(report.join("\n"));
const failed = report.filter((line) => line.startsWith("FAIL")).length;
console.log(`${report.length - failed} ok, ${failed} failed`);
await stop(failed === 0 ? 0 : 1);

async function stop(code) {
  try {
    chromeProcess?.kill();
    await Promise.race([new Promise((resolve) => chromeProcess?.once("exit", resolve)), Bun.sleep(2000)]);
  } catch {}
  try {
    server.kill();
    await Promise.race([server.exited, Bun.sleep(2000)]);
  } catch {}
  try {
    await new Promise((resolve) => fixture.close(resolve));
  } catch {}
  fs.rmSync(sockPath, { force: true });
  process.exit(code);
}
