#!/usr/bin/env bun
// Build socutil with the Zig this project requires.
//
//   bun build.mjs                 # the same build `zig build` performs
//   bun build.mjs -- test ...     # arguments after `--` are passed through
//
// A bare `zig build` uses whichever `zig` is first on PATH, and on a machine that has an older Zig there
// that is a toolchain `build.zig` refuses on purpose. Resolving the compiler through `check-zig.mjs` means
// `bun run build` and the test suite agree about which Zig is being used, and the failure names the fix
// instead of burying a version mismatch in the build output. `ZIG` still overrides, exactly as it does for
// `bun check-zig.mjs`.
import { requireZig } from "./check-zig.mjs";

const resolved = requireZig();
console.log(`zig ${resolved.version} at ${resolved.path}`);

const passthrough = process.argv.slice(2);
const result = Bun.spawnSync([resolved.path, "build", ...passthrough], {
  cwd: import.meta.dir,
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
});

process.exit(result.exitCode ?? 1);
