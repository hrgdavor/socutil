#!/usr/bin/env bun
// Verify that the toolchain socutil is built with is Zig 0.17.
//
//   bun check-zig.mjs [--zig <path>]
//
// Resolution order: `--zig`, then the `ZIG` environment variable, then the recorded checkout, then `zig` on
// PATH. A wrong version, or no compiler at all, fails with the path to use: the difference matters because
// 0.17 moved the whole I/O surface (`std.Io`, `std.process.Init`), and building this source with an older
// compiler produces a wall of mismatched-symbol errors instead of the one line that names the fix.
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

const RECORDED = "D:\\wrk\\zig\\17\\zig.exe";
const REQUIRED = "0.17";

const argv = process.argv.slice(2);
const at = argv.indexOf("--zig");
const explicit = at >= 0 ? argv[at + 1] : undefined;
if (at >= 0 && !explicit) {
  console.error("--zig needs a path to a Zig executable");
  process.exit(2);
}

const candidates = [explicit, process.env.ZIG, RECORDED, "zig"].filter(Boolean);

const started = performance.now();
let resolved;
let version;
for (const candidate of candidates) {
  if (candidate !== "zig" && !existsSync(candidate)) continue;
  const result = spawnSync(candidate, ["version"], { stdio: ["ignore", "pipe", "pipe"] });
  if (result.error || result.status !== 0) continue;
  resolved = candidate;
  version = String(result.stdout ?? "").trim();
  break;
}

if (!resolved) {
  console.error(`no Zig found - tried ${candidates.join(", ")}`);
  console.error(`install Zig ${REQUIRED} at ${RECORDED}, or set ZIG to it`);
  process.exit(1);
}

const majorMinor = version.split(".").slice(0, 2).join(".");
if (majorMinor !== REQUIRED) {
  console.error(`unsupported Zig ${version} at ${resolved} - socutil requires ${REQUIRED}`);
  console.error(`use ${RECORDED}, or set ZIG to a Zig ${REQUIRED} binary`);
  process.exit(1);
}

console.log(`zig ${version} at ${resolved}`);
console.log(`toolchain verified in ${Math.round(performance.now() - started)}ms (${REQUIRED})`);
