# Tests

From the project root, build once, then run the default suite with one command:

```sh
bun run build      # -> zig-out/bin/socutil[.exe] and socutil-cli[.exe]
bun run test       # the default suite: toolchain check, end-to-end test, CLI test
```

`bun run test` runs `run-tests.mjs`, which executes the steps below in order and stops at the first
failure. The runner only orchestrates — order, a bounded timeout per step, one line per step, a final
summary and a non-zero exit — and each script keeps its own assertions and `ok`/`PASS` output. A missing
build artifact is reported with the command that produces it (`bun run build`) rather than being skipped.

| Script          | What it covers                                      | In `bun run test`     |
| --------------- | --------------------------------------------------- | --------------------- |
| `check-zig.mjs` | resolves and validates the Zig 0.17 toolchain       | yes, first            |
| `e2e.mjs`       | the HTTP server end to end, both transports         | yes                   |
| `cli-test.mjs`  | `socutil-cli` against a live fs-meta socket         | yes                   |
| `ui-smoke.mjs`  | the page in a real browser                          | no, `bun run test:ui` |

The browser smoke test needs a real Chromium-compatible browser and is slow, so it is opt-in:

```sh
bun run test:ui    # bun ui-smoke.mjs
```

The Zig unit tests are separate (`zig build test`: session-id validation, query decoding, JSON escaping,
suffixes); `bun run test` is the process-level suite.

The end-to-end test builds nothing: build first (it says so if the binary is missing). It starts the
server on port 0, reads the port from the server's own startup line, and drives a real unix socket with a
greeting, an echo round trip, a clean `EOF` exit, and the error statuses above, over both transports. It
selects the socket by the name the listing returned, refuses a path sent as a name, and proves a `path`
parameter is not a selector at all. The WebSocket half also checks the 64 KiB refusal (`1009`), the version
check and the upgrade requirement. Its fixture lives under the project's `.tmp/socutil-e2e/`, and it
always tears the process and socket down, including on failure. Use `--exe <path>` to test another build.

The CLI test needs both binaries: `zig-out/bin/socutil-cli[.exe]` from this project and
`../fs-meta/zig-out/bin/fsmeta[.exe]` from fs-meta (`FSMETA_DIR` overrides that location). It creates a
scratch trio under fs-meta's `.tmp/`, serves it with `fsmeta serve <root>`, and drives `socutil-cli` over
`<root>/.fs-meta/socket`. It checks the HELLO frame byte for byte, that the greeting arrives before any
`SUBSCRIBE` and with stdin still open, the replayed `START_BATCH`/`CHANGE_ENTRY`/`END_BATCH` frames, and
that the client exits 0 when the peer closes even though stdin never did. Every wait is bounded, a 45 s
watchdog turns a stuck run into a failure, and `--exe`/`--fsmeta` test other builds.

The browser test is the half the end-to-end test cannot see — the page's own `WebSocket`/`EventSource`
wiring, base64 or binary decoding, form, status line, and the name it sends — driven over the Chrome
DevTools Protocol. It runs the same scenario twice: the default tunnel, then the page reloaded with
`?transport=sse`. It looks for Chrome or a Chromium on the usual paths (`CHROME`, or `--chrome <path>`,
overrides that) and prints `SKIP` and exits 0 when none is installed; the server-side test is the mandatory
one, and this one is an enhancement. Its profile and fixture live under the project's
`.tmp/socutil-ui-smoke/`.
