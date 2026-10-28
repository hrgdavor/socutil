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
// `bind_variable` returns a `SHELL_VAR *`, not an int: declaring it as c_int truncates the pointer
// and the success check becomes a coin flip on the low 32 bits.
extern fn bind_variable(name: [*:0]const u8, value: [*:0]u8, flags: c_int) ?*anyopaque;

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
    const target = std.mem.span(path);
    var address = std.mem.zeroes(SockaddrUn);
    address.family = AF_UNIX;
    if (target.len >= address.path.len) {
        complain("sock: socket path too long\n");
        return 1;
    }
    @memcpy(address.path[0..target.len], target);

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        complain("sock: cannot create socket\n");
        return 1;
    }
    if (connect(fd, @ptrCast(&address), @sizeOf(SockaddrUn)) != 0) {
        complain("sock: cannot connect\n");
        _ = close(fd);
        return 1;
    }

    var buffer: [16]u8 = undefined;
    const rendered = renderDescriptor(&buffer, fd);
    if (bind_variable(name, rendered.ptr, 0) == null) {
        complain("sock: cannot set the descriptor variable\n");
        _ = close(fd);
        return 1;
    }
    return 0;
}

fn sockCommand(list: ?*WordList) callconv(.c) c_int {
    const option = argument(list, 0) orelse {
        complain("sock: usage: sock -a VAR PATH | -w FD | -c FD\n");
        return 2;
    };
    const flag = std.mem.span(option);

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

    complain("sock: usage: sock -a VAR PATH | -w FD | -c FD\n");
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
