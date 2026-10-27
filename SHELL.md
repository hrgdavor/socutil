# Calling Unix Sockets from the Shell

This document explains how to call compatible Unix-domain sockets from the shell, and how to
optimise that call to avoid forking a new process where the shell allows it.

## The two binaries

socutil ships two binaries:

| Binary        | Role                                                                                    |
| ------------- | --------------------------------------------------------------------------------------- |
| `socutil`     | HTTP server: a browser UI that proxies one or more Unix sockets over WebSocket and SSE. |
| `socutil-cli` | A `socat` alternative: connects to a Unix socket and relays stdin/stdout.               |

`socutil-cli` is the forking path. It is a drop-in replacement for `socat - UNIX-CONNECT:/path`:

```sh
socutil-cli /path/to/socket
```

Everything you type on stdin is written to the socket; everything the socket writes is printed
on stdout. When either side closes, the process exits.

## When forking is fine

For one-off calls, forking is the simplest and most portable approach:

```sh
# Send a single line and read the response
printf 'hello\n' | socutil-cli /path/to/socket
```

This forks one `socutil-cli` process per call. For interactive use or scripting where each call
is a separate invocation, that is acceptable.

## Skipping the fork: shell functions

Some shells can talk to a Unix socket **without forking a child process**. Where that is viable,
define a shell function that opens the socket directly and relays bytes through file descriptors.
The function replaces the `socutil-cli` fork with in-shell I/O.

### zsh — no fork

zsh has a built-in socket module (`zsh/net/socket`) that can open a Unix-domain socket directly from
the shell, with no child process. The module name matters: it is `zsh/net/socket`, not `zsh/socket`.

```zsh
# Load the socket module (once per shell session)
zmodload zsh/net/socket

# Open an outbound Unix-domain connection. The filename is a positional argument and the
# resulting file descriptor is stored in REPLY.
zsocket /path/to/socket
fd=$REPLY

# Write to the socket
printf 'hello\n' >&$fd

# Read from the socket
read -u $fd response
print -r -- $response

# Close
exec {fd}>&-
```

The `zsocket` sub-forms are easy to confuse, so they are worth stating:

| form                               | what it does                                           |
| ---------------------------------- | ------------------------------------------------------ |
| `zsocket [-v] [-d fd] filename`    | **outbound** connection; fd lands in `REPLY` (or `-d`) |
| `zsocket -l [-v] [-d fd] filename` | **listen** on `filename`; listener fd in `REPLY`       |
| `zsocket -a [-tv] [-d target] lid` | **accept** one inbound connection on listener `lid`    |

There is no `-u` option — Unix-domain is the only thing this builtin speaks — and `-a` is *accept*,
not "allocate". Getting that wrong is the usual way this example is copied incorrectly.

Wrap it in a function so the socket is opened and closed per call:

```zsh
fsmeta() {
    zmodload zsh/net/socket 2>/dev/null || { print -u2 'zsh/net/socket unavailable'; return 1 }
    local fd
    zsocket "$1" || return 1
    fd=$REPLY
    cat >&$fd                    # send everything that is on stdin
    local line
    while IFS= read -r -u $fd line; do
        print -r -- "$line"
    done
    exec {fd}>&-
}

# Usage:
fsmeta /path/to/socket
```

This does **not** fork. The shell itself owns the socket file descriptor.

### bash — coproc (still forks, but contained)

bash has no built-in Unix-socket support. The closest is `coproc` (bash 4+), which runs a
command in a coprocess and exposes its stdin/stdout as file descriptors. This still forks, but
the fork is contained within the function and the coprocess is cleaned up when the function
returns.

The direction of the two descriptors is the easy mistake: with `coproc NAME`, `NAME[0]` is the
pipe the shell **reads** from (the coprocess's stdout), and `NAME[1]` is the pipe the shell
**writes** to (the coprocess's stdin).

```bash
fsmeta() {
    coproc SC { socutil-cli "$1"; }
    local rfd=${SC[0]} wfd=${SC[1]} pid=$SC_PID line
    cat >&$wfd                   # send everything that is on stdin
    exec {wfd}>&-                # close our write end so the relay sees EOF
    while IFS= read -r line <&$rfd; do
        printf '%s\n' "$line"
    done
    exec {rfd}<&-
    wait $pid 2>/dev/null
}

# Usage:
fsmeta /path/to/socket
```

This forks one `socutil-cli` process per call, but the fork is scoped to the function and the
process is reaped before the function returns.

One caveat is inherent to a one-shot relay: `socutil-cli` exits when **either** side closes, so
closing the write end after `cat` can end the process before a slow reply is read. If the peer
answers only after it has consumed all input, keep the write end open (drop the `exec {wfd}>&-`)
and read until the socket closes instead.

### fish — no built-in

fish has no built-in Unix-socket support and no coproc equivalent. The forking path
(`socutil-cli`) is the only option:

```fish
printf 'hello\n' | socutil-cli /path/to/socket
```

## Summary

| Shell | No-fork path                          | Forking path                          |
| ----- | ------------------------------------- | ------------------------------------- |
| zsh   | `zmodload zsh/net/socket` + `zsocket` | `socutil-cli`                         |
| bash  | — (no built-in)                       | `coproc socutil-cli` (contained fork) |
| fish  | — (no built-in)                       | `socutil-cli`                         |

The no-fork path is viable only in zsh. In bash and fish, the forking path is the only option,
but bash's `coproc` keeps the fork contained within a function.

## The HTTP path

When forking is not viable or not desirable, the `socutil` HTTP server provides a browser UI
that proxies the socket over WebSocket and SSE. Start it with:

```sh
socutil --dir /path/to/socket-dir
```

Then open the printed URL in a browser. The UI lists the sockets in the directory and lets you
select one, open a WebSocket tunnel, and relay bytes interactively.

For `fsmeta serve`, the HTTP endpoint is optional, and the port is the only thing the flag
chooses:

```sh
fsmeta serve /root --http        # port 8765
fsmeta serve /root --http=9000   # the port you name
fsmeta serve /root --http=0      # any free port; the bound one is announced on stdout
```

That starts the Unix-socket server (the binary protocol of `FORMAT.socket.md`) **and** an HTTP
endpoint exposing the fs-meta socket through the socutil browser UI. With `--http=0` the server
prints `socutil listening on http://127.0.0.1:<port>/`, which is how a script learns the port it
got — useful when several servers must coexist on one machine.

The flag belongs to `serve` alone: any other command given it fails with
`fsmeta: --http is only valid for the serve command`.
