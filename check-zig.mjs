#!/usr/bin/env bun
// Verify that the toolchain socutil is built with is Zig 0.17.
//
//   bun check-zig.mjs [--zig <path>]
//
// Resolution order: `--zig`, then the `ZIG` environment variable, then the recorded checkout, then `zig` on
// PATH. A wrong version, or no compiler at all, fails with the path to use: the difference matters because
// 0.17 moved the whole I/O surface (`std.Io`, `std.process.Init`), and building this source with an older
// compiler produces a wall of mismatched-symbol errors instead of the one line that names the fix.
//
// The resolution is exported so `build.mjs` builds with the compiler this check approves, rather than
// whatever `zig` the caller's PATH happens to name first. `bun run build` therefore cannot pick a toolchain
// that `build.zig` will refuse.
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

export const RECORDED = "D:\\wrk\\zig\\17\\zig.exe";
export const REQUIRED = "0.17";

/** The candidate list, in the documented order, with unset entries dropped. */
export function candidatesFor(explicit) {
  return [explicit, process.env.ZIG, RECORDED, "zig"].filter(Boolean);
}

/** The first candidate that answers `zig version`, as `{ path, version }`, or undefined. */
export function resolveZig(explicit) {
  for (const candidate of candidatesFor(explicit)) {
    if (candidate !== "zig" && !existsSync(candidate)) continue;
    const result = spawnSync(candidate, ["version"], { stdio: ["ignore", "pipe", "pipe"] });
    if (result.error || result.status !== 0) continue;
    return { path: candidate, version: String(result.stdout ?? "").trim() };
  }
  return undefined;
}

/** Resolve and require 0.17, exiting with the fix when that is impossible. */
export function requireZig(explicit) {
  const found = resolveZig(explicit);
  if (!found) {
    console.error(`no Zig found - tried ${candidatesFor(explicit).join(", ")}`);
    console.error(`install Zig ${REQUIRED} at ${RECORDED}, or set ZIG to it`);
    process.exit(1);
  }
  const majorMinor = found.version.split(".").slice(0, 2).join(".");
  if (majorMinor !== REQUIRED) {
    console.error(`unsupported Zig ${found.version} at ${found.path} - socutil requires ${REQUIRED}`);
    console.error(`use ${RECORDED}, or set ZIG to a Zig ${REQUIRED} binary`);
    process.exit(1);
  }
  return found;
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const at = argv.indexOf("--zig");
  const explicit = at >= 0 ? argv[at + 1] : undefined;
  if (at >= 0 && !explicit) {
    console.error("--zig needs a path to a Zig executable");
    process.exit(2);
  }

  const started = performance.now();
  const resolved = requireZig(explicit);
  console.log(`zig ${resolved.version} at ${resolved.path}`);
  console.log(`toolchain verified in ${Math.round(performance.now() - started)}ms (${REQUIRED})`);
}
