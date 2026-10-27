# Calling Unix Sockets from the Shell

How to call a compatible Unix-domain socket as if it were a shell command, and how to do it
without forking a helper process per call. "Without forking" means the shell itself holds the
connection — no `socat`, no `socutil-cli`, no child per message.

Everything marked **measured** below was run against a real `AF_UNIX` server, not inferred from
documentation. The shells tested were bash 5.0.17, dash 0.5.10, ksh93 2020.0.0, fish 4.1.1 and
zsh 5.8 on Ubuntu 20.04 (WSL2); PowerShell 5.1 on Windows.

## What each shell can do

| Shell           | Opens a Unix socket itself?  | No-fork route                                                           | Measured        |
| --------------- | ---------------------------- | ----------------------------------------------------------------------- | --------------- |
| **zsh**         | **yes** — `zsocket` builtin  | `zmodload zsh/net/socket`; `zsocket <path>`; read/write on the fd       | yes             |
| bash            | no                           | `/dev/tcp` only for TCP; for Unix either a bridge or a loadable builtin | yes             |
| dash / POSIX sh | no                           | FIFO bridge (see below)                                                 | yes             |
| ksh93           | no                           | `/dev/tcp` for TCP only; FIFO bridge for Unix                           | yes             |
| fish 4          | no                           | FIFO bridge                                                             | yes             |
| PowerShell 5.1  | no                           | .NET Framework has no Unix socket endpoint                              | yes             |
| PowerShell 7+   | yes, in-process (.NET)       | `System.Net.Sockets.UnixDomainSocketEndPoint`                           | not tested here |
| nushell, elvish | no                           | FIFO bridge or a helper                                                 | not tested      |

**Only zsh** among the traditional shells can connect to a Unix socket on its own. That is the
whole reason `socutil-cli` exists, and the reason the FIFO bridge below is worth knowing.

Two traps in the table, both verified:

- **bash's `/dev/tcp` is not Unix support.** It carries TCP (`exec 3<>/dev/tcp/host/port` round-trips),
  but `/dev/unix/...` does not exist, and opening a socket *node* as a file fails with
  `ENXIO` (`No such device or address`) — a socket is not a file you can open.
- **ksh93 has `/dev/tcp` too**, and no Unix equivalent. A shell having network builtins says
  nothing about Unix sockets.

## The forking path: `socutil-cli`

For a one-off call, fork — it is the most portable thing there is:

```sh
printf 'hello\n' | socutil-cli /path/to/socket
```

`socutil-cli` is a drop-in replacement for `socat - UNIX-CONNECT:/path`: stdin goes to the socket,
the socket's output goes to stdout, and it exits when either side closes.

## zsh: the socket is a file descriptor

zsh ships a socket module. The name matters: it is `zsh/net/socket`, **not** `zsh/socket`.

```zsh
zmodload zsh/net/socket

# Outbound connection. The path is positional; the descriptor lands in REPLY.
zsocket /path/to/socket
fd=$REPLY

printf 'hello\n' >&$fd      # printf is a builtin
read -u $fd response        # read is a builtin
print -r -- $response

exec {fd}>&-
```

| form                               | what it does                                           |
| ---------------------------------- | ------------------------------------------------------ |
| `zsocket [-v] [-d fd] filename`    | **outbound** connection; fd lands in `REPLY` (or `-d`) |
| `zsocket -l [-v] [-d fd] filename` | **listen** on `filename`; listener fd in `REPLY`       |
| `zsocket -a [-tv] [-d target] lid` | **accept** one inbound connection on listener `lid`    |

There is no `-u` option (Unix-domain is all this builtin speaks) and `-a` is *accept*, not
"allocate" — misreading those is the usual way this example gets copied wrongly.

As a function, so the socket is opened and closed per call:

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
```

**Measured**: the function above round-trips against a request/response socket, the shell's PID is
identical before and after, and the child count does not change. Binary is fine too, as long as it
stays out of variables — `printf '\000\001\377AB' >&$fd` then `cat <&$fd` echoed `00 01 ff 41 42`
exactly.

Note the boundary precisely: `zsocket`, `printf` and `read` are builtins, so a **text** protocol
forks nothing. Arbitrary **binary** needs redirection, and the usual `cat` is an external process —
the connection still needs no helper, but the byte copy may. And no shell variable can hold a NUL,
so binary must never pass through one.

## Bringing no-fork to the other shells

### 1. The FIFO bridge — works in every shell

A long-lived daemon owns the connection and publishes two named pipes. The shell then uses plain
redirection on a path, where `printf` and `read` are builtins in every shell:

```sh
printf 'request\n' > /run/socutil/req      # builtin printf + redirection: no process
IFS= read -r reply < /run/socutil/resp     # builtin read + redirection: no process
```

The fork happens once, when the bridge starts — the same shape as a server. FIFO open blocking
provides the rendezvous for free, and one request/one response is exactly the shape a
request/response socket already has.

**Measured** in bash, dash and fish against one socket, one daemon:

```
== bash ==   reply: echo:from-bash     printf: builtin, read: builtin
== dash ==   reply: echo:from-dash
== fish ==   reply: echo:from-fish
== bash: children before=1 after=1
```

Trade-offs, stated plainly:

- **Serialised.** One request is in flight at a time; this suits request/response, not a
  multiplexed stream.
- **Not streaming.** A protocol that keeps a connection open and pushes events (the fs-meta
  `serve` replay) does not fit the one-shot shape; the bridge would have to define how a session
  ends.
- **A daemon must exist.** Something has to own the connection — that is irreducible: a shell
  without a socket syscall cannot create one.
- **Permissions matter.** The FIFOs are a capability: create them in a private directory with
  mode `0600`, or another local user can borrow your connection.

This is the natural extension for `socutil`: a bridge mode that takes `--dir` like the server and
serves `req`/`resp`, so any shell gets fork-free access without a new binary per call.

### 2. TCP bridge + `/dev/tcp` — bash and ksh93

bash and ksh93 can open a TCP connection with no process, so anything exposed over TCP is
reachable fork-free. Both hops were measured:

```
bash, direct:   exec 3<>/dev/tcp/127.0.0.1/19555 ; printf 'hello\n' >&3 ; read -u 3 line
                -> got: tcp-echo:hello
bash, via a TCP<->Unix bridge:  -> got: unix-echo:hello
```

One long-lived bridge process, started once, plus `exec 3<>/dev/tcp/...` per call. This is the
same niche the HTTP endpoint fills, minus HTTP: a raw byte tunnel. `dash` and `fish` have no
`/dev/tcp`, so this route is closed to them.

### 3. `coproc` — one fork per session, scoped

bash's `coproc` runs a relay and hands you its pipes. It still forks, but once per coprocess rather
than once per message, and the descriptors are ordinary fds afterwards:

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
```

The descriptor **directions** are the easy mistake: with `coproc SC`, `SC[0]` is the pipe the shell
**reads** (the coprocess's stdout) and `SC[1]` is the pipe the shell **writes** (its stdin).
Writing to `SC[0]` fails — measured.

Keep one coprocess alive for a whole script and the cost is one fork per session, not per call.
`fish` has no `coproc`; `dash` has no arrays, so this recipe is bash-only.

### 4. A loadable builtin — the only truly native option for bash

bash can load a compiled builtin into the running shell:

```bash
enable -f ./sock.so sock        # once
sock -a fd /path/to/socket      # native from then on
```

That is zsh's capability, built by hand: after `enable -f`, the connection is a shell builtin and
nothing forks. It costs a small C file against bash's builtin API (the `enable -f` route needs the
bash development headers), so it is worth it only where a hot path matters. Not measured here.

### 5. An in-process host

If the shell is written in a language that has sockets, the connection is an ordinary object
call and nothing forks: PowerShell 7 on .NET (`UnixDomainSocketEndPoint`), or xonsh on Python.
These are not shell *features* — the interpreter is doing the work — but for Windows they are the
only fork-free option, since no Windows shell has a socket builtin. Windows PowerShell 5.1 is on
.NET Framework, which has no Unix socket endpoint at all: measured, the type does not exist.

## Summary

| Shell        | Native?          | Cheapest no-fork route                  | Fully fork-free?        |
| ------------ | ---------------- | --------------------------------------- | ----------------------- |
| zsh          | yes              | `zsocket`                               | yes, for text protocols |
| bash         | no               | FIFO bridge, or `/dev/tcp` + TCP bridge | yes, per call           |
| dash         | no               | FIFO bridge                             | yes, per call           |
| ksh93        | no               | FIFO bridge, or `/dev/tcp` + TCP bridge | yes, per call           |
| fish         | no               | FIFO bridge                             | yes, per call           |
| PowerShell 7 | yes (in-process) | .NET socket                             | yes                     |

The single-sentence version: **zsh can do it natively; every other shell can do it only if some
long-lived process already owns the connection** — a FIFO bridge (universal), a TCP bridge
(bash/ksh93 via `/dev/tcp`), or an in-process runtime (PowerShell 7, xonsh).

## The HTTP path

When neither a fork nor a bridge is wanted, the `socutil` HTTP server proxies the socket to a
browser UI over WebSocket and SSE:

```sh
socutil --dir /path/to/socket-dir
```

Then open the printed URL: the UI lists the sockets in the directory, lets you select one, and
relays bytes interactively.

`fsmeta serve` exposes the same thing optionally, and the port is the only thing the flag chooses:

```sh
fsmeta serve /root --http        # port 8765
fsmeta serve /root --http=9000   # the port you name
fsmeta serve /root --http=0      # any free port; the bound one is announced on stdout
```

That starts the Unix-socket server (the binary protocol of `FORMAT.socket.md`) **and** an HTTP
endpoint over it. With `--http=0` the server prints `socutil listening on http://127.0.0.1:<port>/`,
which is how a script learns the port it got — useful when several servers must coexist.

The flag belongs to `serve` alone: any other command given it fails with
`fsmeta: --http is only valid for the serve command`.
