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
whole reason `socutil-cli` exists, and the reason the FIFO bridge below is worth knowing. (bash can
be given the same power by loading a builtin into it — see § 4.)

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

bash can load a compiled builtin into the running shell, which is zsh's capability built by hand:

```bash
enable -f ./probe.so probe      # once
enable probe                    # load_builtin registers it DISABLED
probe                           # native from here on: nothing forks
```

**Measured, and built with Zig** — no C and no bash headers. The whole object is a struct and one
function, and bash's own dynamic symbol table supplies the API (`bind_variable` and friends are
undefined in the object and resolve when bash dlopens it; the Ubuntu bash exports ~2200 symbols):

```zig
const Builtin = extern struct {
    name: ?[*:0]const u8,
    function: ?BuiltinFn,
    flags: c_int,
    long_doc: ?*const ?[*:0]const u8,
    short_doc: ?[*:0]const u8,
    handle: ?*anyopaque,
};

extern fn bind_variable(name: [*:0]const u8, value: ?[*:0]u8, flags: c_int) ?*anyopaque;   // SHELL_VAR *, not int

// `var`, not `const`: bash writes its dlopen handle into this struct.
export var probe_struct: Builtin = .{ ... };
```

It cross-compiles from Windows to the Linux target, and comes out tiny:

```sh
zig build-lib -dynamic -fPIC -O ReleaseSafe -fstrip -fallow-shlib-undefined \
    -target x86_64-linux-gnu.2.31 -lc --name probe probe.zig     # 3144 bytes
```

Three details decide whether it works, and each one is a silent failure otherwise:

- **The struct must be writable.** `enable -f` stores the `dlopen` handle into the struct it found,
  so a `const` places it in `.data.rel.ro`, which a full-RELRO link makes read-only after
  relocation — the write faults and bash segfaults inside `enable -f`. This is why an optimized
  build crashed while the Debug build worked: `var` moves it to `.data`.
- **`enable -f` leaves the builtin disabled.** `enable -n <name>` is what it reports afterwards, so
  a separate `enable <name>` must run **in the same shell**; put it in a pipeline and the enable
  happens in a subshell and is lost.
- **The lookup symbol is `<name>_struct`.** `enable -f file name` dlopens the file and looks for
  that exact symbol; the `struct builtin` name field should match, but the symbol is what is found.

Every field after `function` is left zero on purpose: `flags` and `long_doc` have changed order
between bash versions, and with both zero the ordering cannot be observed. So the same object loads
on any bash that exports its symbols.

### 5. An in-process host

If the shell is written in a language that has sockets, the connection is an ordinary object
call and nothing forks: PowerShell 7 on .NET (`UnixDomainSocketEndPoint`), or xonsh on Python.
These are not shell *features* — the interpreter is doing the work — but for Windows they are the
only fork-free option, since no Windows shell has a socket builtin. Windows PowerShell 5.1 is on
.NET Framework, which has no Unix socket endpoint at all: measured, the type does not exist.

## A command you can alias

Both recipes below give you a command that behaves like an ordinary executable: one argument (the
socket path), stdin in, stdout out, usable anywhere in a pipeline.

**Binary passes through.** Bytes never enter a shell variable — the shell holds only the descriptor
and `cat` moves the data kernel to kernel — so NUL and arbitrary bytes are unaffected. Verified end
to end with `\x00\x01\xffAB` in both shells: sent `00 01 ff 41 42`, received `00 01 ff 41 42`.

### bash: a builtin plus a function

Build once (`shell/sock.zig` ships with socutil; it cross-compiles from any host). Run it from the
`shell/` directory: `--name` puts the object where you are standing, and `-femit-bin` refuses a
`.so` argument.

```sh
cd shell
zig build-lib -dynamic -fPIC -O ReleaseSafe -fstrip -fallow-shlib-undefined \
    -target x86_64-linux-gnu.2.31 -lc --name sock sock.zig      # -> ./libsock.so
```

Put the `.so` somewhere stable and load it in `~/.bashrc`:

```bash
enable -f /usr/local/lib/socutil/libsock.so sock 2>/dev/null && enable sock 2>/dev/null

fsmeta() {
    local sockpath=$1
    local fd reader
    sock -a fd "$sockpath" || return 1     # connect; $fd is ours
    cat <&$fd &                            # reader: socket -> stdout
    reader=$!
    cat >&$fd                              # writer: stdin -> socket
    sock -w "$fd"                          # FIN, so a peer waiting for EOF can answer
    wait "$reader"
    sock -c "$fd"
}
```

```sh
printf 'hello\n' | fsmeta /path/to/socket          # text
some-command | fsmeta /path/to/socket | grep ...   # in a pipeline
fsmeta /path/to/socket < request.bin > reply.bin   # binary, unchanged
```

`sock -w` is the part that is not obvious. Closing your copy of the descriptor does **not** signal
end-of-stream while the `cat` holding a duplicate still exists; only `shutdown(SHUT_WR)` sends FIN.
Without it, a server that answers "after reading everything" waits forever. That was measured: with
`-w` the reply arrives, without it the call hangs.

### zsh: no artifact at all

```zsh
zmodload zsh/net/socket

fsmeta() {
    local sockpath=$1        # NOT `path`: see the pitfalls
    local fd
    zsocket "$sockpath" || return 1
    fd=$REPLY
    cat >&$fd                # send all of stdin
    cat <&$fd                # then read every reply byte
    exec {fd}>&-
}
```

Measured on both shells against a real socket: text round trip, binary round trip, pipeline filter,
`grep`, and five sequential calls with no descriptor leak.

### What each recipe honestly cannot do

- **zsh has no half-close.** There is no `shutdown` builtin, and closing your copy cannot send FIN
  while another process holds a duplicate. So a server that replies only after end-of-stream will
  hang with the zsh recipe — use the bash one, `socutil-cli`, or a bridge for that peer. Protocols
  that answer on a request boundary (fs-meta's replay does) are fine.
- **The bash builtin is Linux-shaped as written**: `sockaddr_un.path` is the Linux layout, and the
  flag constants are Linux values. Porting is a struct and two constants, but it has not been done.
- **Both still fork `cat`** for the byte copy. The *connection* costs no process; the copy is one
  `cat` per call, and that is what buys binary safety. A `read`/`print` loop would avoid the fork
  and would also lose NUL bytes — the trade this section refuses to make.

### Three pitfalls, each measured

- **zsh: never name a variable `path`.** `path` is tied to `PATH`; `local path=$1` replaces the
  search path with the socket name, and every command in the function then fails with
  `command not found: cat`. This cost a debug cycle to find.
- **bash: `enable -f` registers the builtin disabled.** Follow it with `enable <name>` in the same
  shell — in a pipeline the enable runs in a subshell and is lost.
- **The builtin's struct must be `var`, never `const`** (§ 4): bash writes its `dlopen` handle into
  it, and a `const` in `.data.rel.ro` is read-only under full RELRO. A `one_of` here is a segfault
  inside `enable -f`, not an error message.

## Summary

| Shell        | Native?                        | Cheapest no-fork route                               | Fully fork-free?        |
| ------------ | ------------------------------ | ---------------------------------------------------- | ----------------------- |
| zsh          | yes                            | `zsocket`                                            | yes, for text protocols |
| bash         | no, unless a builtin is loaded | FIFO bridge, `/dev/tcp` + TCP bridge, or `enable -f` | yes, per call           |
| dash         | no                             | FIFO bridge                                          | yes, per call           |
| ksh93        | no                             | FIFO bridge, or `/dev/tcp` + TCP bridge              | yes, per call           |
| fish         | no                             | FIFO bridge                                          | yes, per call           |
| PowerShell 7 | yes (in-process)               | .NET socket                                          | yes                     |

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
