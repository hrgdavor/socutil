# socutil

A tiny browser UI for **unix-domain sockets**: it lists the sockets in the directories you name, connects
to one, and relays it to the page like a terminal. It is a library plus two binaries:

- **`socutil`** — the HTTP server with the page embedded (`@embedFile`), so there is nothing to install
  and no build step for the UI.
- **`socutil-cli`** — a `socat` alternative: connects to a Unix socket and relays stdin/stdout. A
  forking path for shell scripts that need a socket relay without a browser.

See [SHELL.md](SHELL.md) for how to call Unix sockets from the shell, and how to skip the fork where
the shell allows it.

Two transports share the relay:

- the **WebSocket byte tunnel** (`/api/ws`), the page's default: raw bytes both ways, no base64, no
  envelope;
- the **tail transport** (`/api/events` + `POST /api/input`), for a line-based socket: send the handshake
  command once, then follow the output as Server-Sent Events.

Sockets are **selected by name, never by path**. A configured directory has a name (`--dir db=/var/run`), a
socket in it is `<dir-name>.<file-name>` (`db.postgres.sock`), and that is the only selector a request may
send. Paths appear in the listing for display and nowhere in a request.

It was written to answer the everyday question *"what is listening on a unix socket right now, and what
does it say?"* without `socat`, `nc`, and a second terminal. The socket side is byte-transparent; the page
shows the bytes as UTF-8 text.

The page is **deliberately vanilla** — one self-contained file, no framework, no bundler, no
`node_modules`, no CDN and no network at view time. That is the minimal-UI half of DEC-027 (a JCodeBuddy
decision record, referenced by name because this project lives outside that checkout), and it is what
lets the binary embed the page and a fresh clone run the tool with no JavaScript build step. A page that grows navigation or
review workflows would be a different kind of page and would move to `jsx6`; this one is a list, a
terminal and a form.

## Build and run

The source is written against **Zig 0.17**, which moved the whole I/O surface (`std.Io`,
`std.process.Init`). A wrong compiler is refused by name instead of producing a wall of mismatched symbols.
`check-zig.mjs` resolves 0.17 via `--zig <path>`, `$ZIG`, the recorded checkout
`D:\wrk\zig\17\zig.exe`, then `zig` on `PATH`, and fails with the path to use.

From the project root:

```sh
bun check-zig.mjs                  # verify the toolchain first
zig build                          # -> zig-out/bin/socutil[.exe] and socutil-cli[.exe]
zig build run -- --dir /run        # build and run, arguments after `--` passed through
```

`zig build` uses the `zig` on `PATH`; when that is an older compiler, call the recorded path directly
(`D:\wrk\zig\17\zig.exe build`).

```sh
socutil                              # scan the platform defaults, listen on 127.0.0.1:8765
socutil --port 0 /run /tmp           # any free port; names derive from the basenames
socutil --dir db=/var/run --port 9000 # the sockets are named db.<file-name>
```

| Option                | Meaning                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------- |
| `--listen <host>`     | address to bind; also spelled `--host` (default `127.0.0.1`)                            |
| `--port <port>`       | TCP port to bind; `0` picks a free one (default `8765`)                                 |
| `--dir [name=]<path>` | a directory to scan; repeatable, and bare arguments work; default name is the basename  |
| `-h`, `--help`        | usage                                                                                   |

With no directory arguments the defaults are `$XDG_RUNTIME_DIR`, `/tmp`, `/var/run`, `/run` and `.` on
POSIX, and `%TEMP%`, `%TMP%` and `.` on Windows. The startup line prints the URL that was actually bound,
which is what the end-to-end test reads to find its port.

## Names, not paths

This is the API's central rule: **no request carries a filesystem path.** A request chooses a socket by
name; it cannot express a path at all.

- Each configured directory has a name: explicit with `--dir name=/path`, otherwise its basename
  (`/var/run` → `run`). The name is restricted to letters, digits, `-` and `_`, and made unique
  (`run`, `run-2`) so it can never contain a separator or a dot.
- A socket's name is `<directory-name>.<file-name>`, e.g. `run.postgres.sock`. That is what
  `/api/sockets` lists and what `/api/events` and `/api/ws` accept.
- The server resolves a name against a **fresh scan of the configured directories**. An unknown name — and
  a path sent where a name belongs is just an unknown name — is `404`. Nothing from a request is ever
  joined into a path, so a request can only reach a socket those directories contain.
- The listing still shows `dir`, `path` and `file` for display and for copy/paste into a shell. They are
  output only.

## How a socket is recognised

Discovery differs by platform, and the difference is not cosmetic:

- **POSIX** — the directory entry reports `File.Kind.unix_domain_socket`, or a stat of it does; that is
  authoritative.
- **Windows** — an `AF_UNIX` socket is a reparse point. A directory entry shows up as a symlink and
  `statFile` fails with `IO_REPARSE_TAG_NOT_HANDLED`, so there is no portable way to tell it from an
  ordinary symlink without connecting. Windows therefore uses the **name convention**: an entry ending in
  `.sock` or `.socket` (case-insensitive) is offered as a socket. Name your Windows sockets accordingly.

A directory that cannot be opened is logged and skipped — one bad default directory must not hide the
sockets in the rest.

## HTTP API

Every plain response uses `connection: close`; a WebSocket request upgrades instead and stays open.

| Request                          | Response                                                                     |
| -------------------------------- | ---------------------------------------------------------------------------- |
| `GET /`                          | the embedded page (`/index.html` is the same)                                |
| `GET /app.js`, `GET /style.css`  | the embedded assets                                                          |
| `GET /api/sockets`               | `{"dirs":[{"name","path"}],"sockets":[{"name","file","dirName","dir","path"}]}` — a fresh scan, sorted by path |
| `GET /api/events?id=&name=`      | an SSE stream for one listed socket: `ready`, then `out` events, then `exit` |
| `GET /api/ws?id=&name=`          | a WebSocket byte tunnel (see below); a plain request is `426`                |
| `POST /api/input?id=`            | writes the request body to the socket; `{"ok":true,"written":<bytes>}`       |
| `POST /api/close?id=`            | shuts the socket down and ends the session                                   |
| `GET /favicon.ico`               | `204`                                                                        |

`name` must be `<directory-name>.<file-name>` for a socket the fresh scan finds: the request never carries a
path, and a name the server cannot resolve is `404`. Session ids are 1–64 alphanumeric, `-` or `_`
characters, and identify the live connection on later `POST`s for either transport.

With `--dir db=/var/run`, the socket `/var/run/postgres.sock` is listed as:

```json
{"name":"db.postgres.sock","file":"postgres.sock","dirName":"db","dir":"/var/run","path":"/var/run/postgres.sock"}
```

and every request refers to it as `name=db.postgres.sock`.

The page uses the tunnel by default; add `?transport=sse` to the page URL to use the tail transport.

The SSE stream carries three event types:

```
event: ready
data: {"id":"…","path":"…"}

event: out
data: {"b":"<base64 of the socket bytes>"}

event: exit
data: {"reason":"eof"}
```

`out` data is base64 so arbitrary bytes survive the text protocol; the page decodes it with one streaming
`TextDecoder` per session, so a multi-byte character split across chunks is still decoded once. A
`: keepalive` comment is sent after about 15 seconds of silence. The reason on `exit` is one of `eof`,
`reset`, `closed`, `timeout`, `canceled`, `io error`, or `buffer overflow`. A failed keepalive write is how
a vanished browser is noticed, which then shuts the socket down.

### The WebSocket tunnel (`/api/ws`)

`GET /api/ws?id=<id>&name=<name>` upgrades a standard WebSocket (`sec-websocket-version: 13`; any other
version is `400`, and a plain request is `426`). After the `101`:

- the server sends one **binary** frame per read from the unix socket, up to 64 KiB;
- every **text or binary** frame from the browser is written to the socket unchanged — no newline is
  added and nothing is interpreted;
- a ping is answered with a pong, and the server pings after about 15 seconds of silence;
- a socket EOF closes with code `1000` and the reason, a frame over the read buffer is refused with
  `1009` (`message too big`), and a close frame from the browser shuts the socket down.

The transport does **not** reassemble WebSocket fragments and does not grow a buffer to fit a message: one
frame must fit the 64 KiB read buffer, and a protocol that needs to move more uses its own continuation.
That limit is a constant today and can become a flag; nothing above it has to change.

Errors are JSON `{"error":"…"}` with these statuses: `400` missing/invalid id, name or WebSocket version,
`404` unknown session or socket name, `405` wrong method (with `Allow`), `409` session id already in use,
`413` a body of 64 KiB or more, `426` `/api/ws` without an upgrade, `502` the socket could not be connected
to or written.

## What it is not

- **Not authenticated, by design.** It is a local tool: it binds `127.0.0.1` and has no access control.
  Exposing it is a decision for a proxy — Caddy, nginx, or whatever fronts it — which is also where TLS and
  authentication belong. The code does not grow its own.
- **Never path-driven.** No endpoint reads a path from a request. The worst a malformed or hostile request
  can do is name a socket that is not in the scan, which is a `404`; it cannot reach a file the configured
  directories do not contain.
- **The page types text; the tunnel is still byte-exact.** The input box encodes what you type as UTF-8 and
  appends a newline, and the page renders output as UTF-8 text. The WebSocket transport itself passes bytes
  unchanged in both directions, so a protocol that needs binary needs a different client (or a future raw
  input mode), not a different transport.
- **Bounded.** Up to 1 MiB of unread socket output is buffered per session; beyond that the oldest half is
  dropped so a stalled browser cannot make the server grow without bound. A WebSocket message must fit the
  64 KiB read buffer.

## Tests

Run these from the project root:

```sh
zig build test     # unit tests: session-id validation, query decoding, JSON escaping, suffixes
bun e2e.mjs        # end-to-end: fixture socket, real server, raw HTTP + SSE + WebSocket
bun ui-smoke.mjs   # the page in a real browser: both transports, list to disconnect
```

The end-to-end test builds nothing: build first (it says so if the binary is missing). It starts the
server on port 0, reads the port from the server's own startup line, and drives a real unix socket with a
greeting, an echo round trip, a clean `EOF` exit, and the error statuses above, over both transports. It
selects the socket by the name the listing returned, refuses a path sent as a name, and proves a `path`
parameter is not a selector at all. The WebSocket half also checks the 64 KiB refusal (`1009`), the version
check and the upgrade requirement. Its fixture lives under the project's `.tmp/socutil-e2e/`, and it
always tears the process and socket down, including on failure. Use `--exe <path>` to test another build.

The browser test is the half the end-to-end test cannot see — the page's own `WebSocket`/`EventSource`
wiring, base64 or binary decoding, form, status line, and the name it sends — driven over the Chrome
DevTools Protocol. It runs the same scenario twice: the default tunnel, then the page reloaded with
`?transport=sse`. It looks for Chrome or a Chromium on the usual paths (`CHROME`, or `--chrome <path>`,
overrides that) and prints `SKIP` and exits 0 when none is installed; the server-side test is the mandatory
one, and this one is an enhancement. Its profile and fixture live under the project's
`.tmp/socutil-ui-smoke/`.

## Layout

| Path                    | What it is                                                           |
| ----------------------- | -------------------------------------------------------------------- |
| `src/lib.zig`           | the library root: `Config`, `run`, re-exports `server` and `sockets` |
| `src/main.zig`          | the `socutil` binary: argument parsing, defaults, listener           |
| `src/cli.zig`           | the `socutil-cli` binary: a `socat` alternative, stdin/stdout relay  |
| `src/server.zig`        | HTTP routing, the SSE tail and WebSocket tunnel, session lifecycle   |
| `src/sockets.zig`       | socket discovery and the platform rules above                        |
| `src/ui/`               | the page, script and stylesheet, embedded at build time              |
| `SHELL.md`              | calling Unix sockets from the shell; fork-skipping per shell         |
| `check-zig.mjs`         | toolchain check: says which Zig to use instead of failing vaguely    |
| `e2e.mjs`               | the end-to-end test, both transports                                 |
| `ui-smoke.mjs`          | the page exercised in a real browser, both transports                |
