// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `sock` — a bash loadable builtin that opens a unix-domain socket and hands back a descriptor.
//!
//! Build (cross-compiles from any host, no bash headers needed):
//!
//!     zig build-lib -dynamic -fPIC -O ReleaseSafe -fstrip -fallow-shlib-undefined \
//!         -target x86_64-linux-gnu.2.31 -lc --name sock sock.zig
//!
//! Load once per shell, then use it like any other command:
//!
//!     enable -f ./libsock.so sock && enable sock
//!     sock -a fd /path/to/socket     # connects, sets $fd
//!     sock -w "$fd"                  # half-close: peer sees EOF, we can still read
//!     sock -c "$fd"                  # close
//!
//! Why each subcommand exists:
//!
//!   -a is the whole point: bash has no socket syscall, so the connection cannot be made from
//!      the language. `socket(2)` + `connect(2)` here, and the fd is handed to the shell through
//!      `bind_variable`, so the shell owns it afterwards and can redirect to it like any fd.
//!   -w exists because closing your copy of the fd does NOT signal end-of-stream while a child
//!      (the `cat` reading the reply) still holds a duplicate. Only `shutdown(SHUT_WR)` sends FIN,
//!      which is what a peer that answers "after reading everything" is waiting for.
//!   -c closes explicitly so a function can clean up without relying on `exec {fd}>&-`.
//!
//! Bytes never pass through a shell variable: the shell moves them with redirection and `cat`,
//! so NUL and arbitrary binary are unaffected. Only the descriptor number is a shell string.

const std = @import("std");

// ── bash's loadable-builtin ABI, declared by hand ──────────────────────────────────────────────
// The bash headers are not required: the struct layout is stable, and every field after
// `function` is zero here precisely because `flags`/`long_doc` have swapped order between
// versions — with both zero the ordering cannot be observed.

const WordDesc = extern struct {
    word: ?[*:0]u8,
    flags: c_int,
};

const WordList = extern struct {
    next: ?*WordList,
    word: ?*WordDesc,
};

const BuiltinFn = *const fn (list: ?*WordList) callconv(.c) c_int;

const Builtin = extern struct {
    name: ?[*:0]const u8,
    function: ?BuiltinFn,
    flags: c_int,
    long_doc: ?*const ?[*:0]const u8,
    short_doc: ?[*:0]const u8,
    handle: ?*anyopaque,
};

// ── the handful of libc entry points this needs ────────────────────────────────────────────────

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SHUT_WR: c_int = 1;
const SHUT_RDWR: c_int = 2;

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

extern fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern fn shutdown(fd: c_int, how: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn poll(fds: [*]PollFd, count: c_ulong, timeout: c_int) c_int;
// `bind_variable` returns a `SHELL_VAR *`, not an int: declaring it as c_int truncates the pointer
// and the success check becomes a coin flip on the low 32 bits.
extern fn bind_variable(name: [*:0]const u8, value: [*:0]u8, flags: c_int) ?*anyopaque;

const POLLIN: c_short = 0x001;
const POLLERR: c_short = 0x008;
const POLLHUP: c_short = 0x010;
const STDIN: c_int = 0;
const STDOUT: c_int = 1;

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

/// Write the whole slice, retrying short writes. Returns false on any error.
fn writeAll(fd: c_int, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written <= 0) return false;
        offset += @intCast(written);
    }
    return true;
}

/// Connect to an AF_UNIX stream socket, or null. The descriptor is returned open; the caller owns it.
fn connectSocket(path: [*:0]const u8) ?c_int {
    const target = std.mem.span(path);
    var address = std.mem.zeroes(SockaddrUn);
    address.family = AF_UNIX;
    if (target.len >= address.path.len) {
        complain("sock: socket path too long\n");
        return null;
    }
    @memcpy(address.path[0..target.len], target);

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        complain("sock: cannot create socket\n");
        return null;
    }
    if (connect(fd, @ptrCast(&address), @sizeOf(SockaddrUn)) != 0) {
        complain("sock: cannot connect\n");
        _ = close(fd);
        return null;
    }
    return fd;
}

fn complain(message: []const u8) void {
    _ = write(2, message.ptr, message.len);
}

/// The n-th argument. bash hands a builtin the arguments *after* the command name, so index 0 is
/// the first argument (`-a`), not the builtin's own word.
fn argument(list: ?*WordList, index: usize) ?[*:0]const u8 {
    var node = list;
    var remaining = index;
    while (remaining > 0) : (remaining -= 1) {
        const current = node orelse return null;
        node = current.next;
    }
    const current = node orelse return null;
    const word = current.word orelse return null;
    return word.word;
}

fn parseDescriptor(text: []const u8) ?c_int {
    const value = std.fmt.parseInt(c_int, text, 10) catch return null;
    if (value < 0) return null;
    return value;
}

/// Render a small non-negative integer into `buffer` as a NUL-terminated decimal, returning the
/// slice including the terminator. Hand-rolled so the artifact carries no formatter at all.
fn renderDescriptor(buffer: *[16]u8, fd: c_int) [:0]u8 {
    var digits: [12]u8 = undefined;
    var count: usize = 0;
    var value: u32 = @intCast(fd);
    if (value == 0) {
        digits[0] = '0';
        count = 1;
    } else {
        while (value > 0) : (value /= 10) {
            digits[count] = '0' + @as(u8, @intCast(value % 10));
            count += 1;
        }
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        buffer[index] = digits[count - 1 - index];
    }
    buffer[count] = 0;
    return buffer[0..count :0];
}

fn connectCommand(name: [*:0]const u8, path: [*:0]const u8) c_int {
    const fd = connectSocket(path) orelse return 1;

    var buffer: [16]u8 = undefined;
    const rendered = renderDescriptor(&buffer, fd);
    if (bind_variable(name, rendered.ptr, 0) == null) {
        complain("sock: cannot set the descriptor variable\n");
        _ = close(fd);
        return 1;
    }
    return 0;
}

/// `-p`: connect and relay stdin to the socket and the socket to stdout, entirely inside the builtin.
///
/// This is what makes the command cost nothing: a bash function that connects and then runs `cat`
/// pays for a process (~1 ms measured), which is ten times the cost of a zero-fork text round trip.
/// Doing the copy here removes that: one builtin call, no child, and bytes are copied by `read`/
/// `write` so NUL and arbitrary binary are untouched.
///
/// The shape is the relay `socutil-cli` implements — `poll` both directions, half-close on stdin
/// end-of-stream, stop when the peer closes — with one difference: it returns instead of exiting,
/// because the process belongs to bash.
fn pumpCommand(path: [*:0]const u8) c_int {
    const fd = connectSocket(path) orelse return 1;
    return pumpFds(fd);
}

/// Write a decimal number without a formatter.
fn writeDecimal(fd: c_int, value: usize) bool {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    if (remaining == 0) {
        digits[0] = '0';
        count = 1;
    } else {
        while (remaining > 0) : (remaining /= 10) {
            digits[count] = '0' + @as(u8, @intCast(remaining % 10));
            count += 1;
        }
    }
    var out: [20]u8 = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) out[index] = digits[count - 1 - index];
    return writeAll(fd, out[0..count]);
}

/// `-x`: the `{{` dialect. The header carries the executable's parameters and environment; everything
/// after it is the program's stdin, and the reply is its stdout. Then it relays exactly like `-p`.
fn execCommand(path: [*:0]const u8, argv: []const []const u8, envp: []const []const u8) c_int {
    const fd = connectSocket(path) orelse return 1;

    var ok = writeAll(fd, "{{ exec ") and writeDecimal(fd, argv.len) and writeAll(fd, " ") and
        writeDecimal(fd, envp.len) and writeAll(fd, "\n");
    for (argv) |field| {
        if (!ok) break;
        ok = writeDecimal(fd, field.len) and writeAll(fd, " ") and writeAll(fd, field) and writeAll(fd, "\n");
    }
    for (envp) |field| {
        if (!ok) break;
        ok = writeDecimal(fd, field.len) and writeAll(fd, " ") and writeAll(fd, field) and writeAll(fd, "\n");
    }
    if (!ok) {
        complain("sock: cannot write the exec header\n");
        _ = close(fd);
        return 1;
    }
    return pumpFds(fd);
}

/// Relay between stdin/stdout and a connected descriptor, then close it.
fn pumpFds(fd: c_int) c_int {
    var buffer: [16384]u8 = undefined;
    var stdin_open = true;
    var socket_open = true;

    while (socket_open) {
        var fds = [2]PollFd{
            .{ .fd = STDIN, .events = if (stdin_open) POLLIN else 0, .revents = 0 },
            .{ .fd = fd, .events = POLLIN, .revents = 0 },
        };
        const ready = poll(&fds, fds.len, -1);
        if (ready < 0) break;

        // Any revents means "ask this descriptor": a pipe at end-of-stream reports POLLHUP without
        // POLLIN, and reading is the only reliable way to learn that. Testing POLLIN alone leaves the
        // pump spinning and never sends the FIN the peer is waiting for.
        if (stdin_open and fds[0].revents != 0) {
            const got = read(STDIN, &buffer, buffer.len);
            if (got <= 0) {
                // End of input: FIN, so a peer that answers after reading everything can answer.
                stdin_open = false;
                _ = shutdown(fd, SHUT_WR);
            } else if (!writeAll(fd, buffer[0..@intCast(got)])) {
                break;
            }
        }

        if (fds[1].revents != 0) {
            const got = read(fd, &buffer, buffer.len);
            if (got <= 0) {
                socket_open = false;
                break;
            }
            if (!writeAll(STDOUT, buffer[0..@intCast(got)])) break;
        }
    }

    _ = close(fd);
    return 0;
}

fn sockCommand(list: ?*WordList) callconv(.c) c_int {
    const option = argument(list, 0) orelse {
        complain("sock: usage: sock -p PATH | -a VAR PATH | -w FD | -c FD\n");
        return 2;
    };
    const flag = std.mem.span(option);

    if (std.mem.eql(u8, flag, "-p")) {
        const path = argument(list, 1) orelse {
            complain("sock: -p needs a socket path\n");
            return 2;
        };
        return pumpCommand(path);
    }

    if (std.mem.eql(u8, flag, "-x")) {
        const path = argument(list, 1) orelse {
            complain("sock: -x needs a socket path\n");
            return 2;
        };
        var argv_buffer: [64][]const u8 = undefined;
        var env_buffer: [64][]const u8 = undefined;
        var argc: usize = 0;
        var envc: usize = 0;
        var index: usize = 2;
        // `-e NAME=VALUE` pairs come before the program word.
        while (true) {
            const word = argument(list, index) orelse break;
            if (!std.mem.eql(u8, std.mem.span(word), "-e")) break;
            const pair = argument(list, index + 1) orelse {
                complain("sock: -e needs NAME=VALUE\n");
                return 2;
            };
            if (envc == env_buffer.len) {
                complain("sock: too many environment entries\n");
                return 2;
            }
            env_buffer[envc] = std.mem.span(pair);
            envc += 1;
            index += 2;
        }
        while (argument(list, index)) |word| : (index += 1) {
            if (argc == argv_buffer.len) {
                complain("sock: too many arguments\n");
                return 2;
            }
            argv_buffer[argc] = std.mem.span(word);
            argc += 1;
        }
        if (argc == 0) {
            complain("sock: -x needs a program to run\n");
            return 2;
        }
        return execCommand(path, argv_buffer[0..argc], env_buffer[0..envc]);
    }

    if (std.mem.eql(u8, flag, "-a")) {
        const name = argument(list, 1) orelse {
            complain("sock: -a needs a variable name\n");
            return 2;
        };
        const path = argument(list, 2) orelse {
            complain("sock: -a needs a socket path\n");
            return 2;
        };
        return connectCommand(name, path);
    }

    if (std.mem.eql(u8, flag, "-w")) {
        const text = argument(list, 1) orelse {
            complain("sock: -w needs a descriptor\n");
            return 2;
        };
        const fd = parseDescriptor(std.mem.span(text)) orelse {
            complain("sock: -w needs a numeric descriptor\n");
            return 2;
        };
        if (shutdown(fd, SHUT_WR) != 0) {
            complain("sock: cannot half-close\n");
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, flag, "-c")) {
        const text = argument(list, 1) orelse {
            complain("sock: -c needs a descriptor\n");
            return 2;
        };
        const fd = parseDescriptor(std.mem.span(text)) orelse {
            complain("sock: -c needs a numeric descriptor\n");
            return 2;
        };
        _ = shutdown(fd, SHUT_RDWR);
        _ = close(fd);
        return 0;
    }

    complain("sock: usage: sock -p PATH | -a VAR PATH | -w FD | -c FD\n");
    return 2;
}

// `var`, not `const`: `enable -f` writes the dlopen handle into this struct, and a const would
// land in .data.rel.ro, which full RELRO makes read-only — the write then faults.
export var sock_struct: Builtin = .{
    .name = "sock",
    .function = &sockCommand,
    .flags = 0,
    .long_doc = null,
    .short_doc = null,
    .handle = null,
};
