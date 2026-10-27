#!/usr/bin/env bun
// The one command behind `bun run test`: run socutil's checks in order, stopping at the first failure.
//
//   bun run test          # check-zig.mjs, then e2e.mjs, then cli-test.mjs
//   bun run-tests.mjs
//
// This file orchestrates; it does not test. Each step is one of the existing scripts, run as its own
// process with a bounded timeout, so a wedged server, socket or client cannot hang the suite. The
// scripts keep their own assertions and print their own `ok`/`PASS` lines; the runner adds one line per
// step, a final summary, and a non-zero exit code on any failure. A missing binary is reported with the
// command that builds it, never skipped. `ui-smoke.mjs` is deliberately not a step: it needs a real
// Chrome and is slow, so it is opt-in through `bun run test:ui`.
import fs from "node:fs";
import path from "node:path";

const root = import.meta.dir;
const exeName = (stem) => (process.platform === "win32" ? `${stem}.exe` : stem);
const bin = (stem) => path.join(root, "zig-out", "bin", exeName(stem));
const fsMetaDir = process.env.FSMETA_DIR ?? path.resolve(root, "..", "fs-meta");

// Order matters: prove the compiler before building on it, and prove the server before the CLI that
// is a second client of the same relay. Later steps assume nothing about earlier ones except that they
// passed; keeping chronologically earlier checks first makes a failure message point at the cause.
const STEPS = [
  {
    label: "toolchain",
    script: "check-zig.mjs",
    timeoutMs: 60_000,
  },
  {
    label: "e2e",
    script: "e2e.mjs",
    timeoutMs: 120_000,
    prerequisites: [
      { path: bin("socutil"), hint: 'run "bun run build" from the project root' },
    ],
  },
  {
    label: "cli",
    script: "cli-test.mjs",
    timeoutMs: 180_000,
    prerequisites: [
      { path: bin("socutil-cli"), hint: 'run "bun run build" from the project root' },
      {
        path: path.join(fsMetaDir, "zig-out", "bin", exeName("fsmeta")),
        hint: 'run "zig build" from the fs-meta project root',
      },
    ],
  },
];

const startedAt = performance.now();
let passed = 0;
let failure = null;

console.log(`socutil tests: ${STEPS.length} steps (${STEPS.map((step) => step.label).join(", ")})`);

for (const [index, step] of STEPS.entries()) {
  const position = `${index + 1}/${STEPS.length}`;
  const scriptPath = path.join(root, step.script);
  const stepStartedAt = performance.now();

  console.log(`[${position}] ${step.label}: ${step.script}`);

  const missing = preflight(step, scriptPath);
  if (missing) {
    failure = { step, position, detail: missing, code: 1 };
    console.error(`FAIL [${position}] ${step.label}: ${missing}`);
    break;
  }

  let child;
  try {
    child = Bun.spawn([process.execPath, scriptPath], {
      cwd: root,
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
    });
  } catch (error) {
    failure = {
      step,
      position,
      detail: `could not start ${process.execPath}: ${error?.message ?? error}`,
      code: 1,
    };
    console.error(`FAIL [${position}] ${step.label}: ${failure.detail}`);
    break;
  }

  let timer;
  const outcome = await Promise.race([
    child.exited.then((code) => ({ code })),
    new Promise((resolve) => {
      timer = setTimeout(() => resolve({ timeout: true }), step.timeoutMs);
    }),
  ]);
  clearTimeout(timer);

  const seconds = ((performance.now() - stepStartedAt) / 1000).toFixed(1);

  if (outcome.timeout) {
    try {
      child.kill();
    } catch {}
    await Promise.race([child.exited, Bun.sleep(2000)]);
    failure = {
      step,
      position,
      detail: `timed out after ${Math.round(step.timeoutMs / 1000)}s and was killed`,
      code: 1,
    };
    console.error(`FAIL [${position}] ${step.label}: ${failure.detail}`);
    break;
  }

  if (outcome.code !== 0) {
    failure = { step, position, detail: `exit ${outcome.code}`, code: outcome.code ?? 1 };
    console.error(`FAIL [${position}] ${step.label}: exited ${outcome.code} after ${seconds}s`);
    break;
  }

  passed += 1;
  console.log(`ok   [${position}] ${step.label} (${seconds}s)`);
}

const elapsed = ((performance.now() - startedAt) / 1000).toFixed(1);

if (failure) {
  console.error(
    `\nFAILED: ${failure.step.label} (${failure.detail}); ` +
      `${passed}/${STEPS.length} steps passed in ${elapsed}s`,
  );
  process.exit(failure.code || 1);
}

console.log(`\nPASS: all ${STEPS.length} steps passed in ${elapsed}s`);

// A missing script means the step list and the tree disagree; a missing binary means the build was
// skipped. Both are reported before the step starts, so neither can look like a silent pass.
function preflight(step, scriptPath) {
  if (!fs.existsSync(scriptPath)) {
    return `script missing: ${path.relative(root, scriptPath)} (check STEPS in run-tests.mjs)`;
  }
  for (const { path: file, hint } of step.prerequisites ?? []) {
    if (!fs.existsSync(file)) {
      return `missing ${path.relative(root, file)} - ${hint}`;
    }
  }
  return null;
}
