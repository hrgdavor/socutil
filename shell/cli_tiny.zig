// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! A deliberately tiny fallback client: connect to a unix socket, send stdin, stream the reply.
//!
//! Built for the case where a daemon does the real work and the client must not be the slow part:
//!
//!     zig build-exe -target x86_64-linux-musl -O ReleaseSmall -fstrip -fsingle-threaded \
//!         -fno-llvm -lc none ... cli-tiny.zig
//!
//! No `std.Io`, no thread pool, no allocator, no dynamic linker when built static. The measured
//! difference against `socutil-cli` is almost entirely what those cost at startup: `socutil-cli`
//! builds an `Io.Threaded` event loop and starts two pump threads for a transfer that a
//! `poll`-free single-threaded loop can do with `read`/`write`.
//!
//! ## One thing worth saying about the socket type
//!
//! This connects with `SOCK_STREAM`, not `SOCK_SEQPACKET`. A client cannot choose the type: the
//! type is fixed by the listener, and `FSMETA`/`socutil` listen with `SOCK_STREAM`. A SEQPACKET
//! `connect` to a stream listener fails with `EPROTOTYPE`, so a SEQPACKET client would only work
//! against a server that also listens with SEQPACKET — a different daemon, not a faster client.
//! There is no framing code here anyway: the request is a byte buffer and the reply is copied
//! straight to stdout, so there is nothing for message boundaries to save.
//!
//! The protocol is the one the peer speaks; this tool does not know it. That is the point: it is a
//! byte pump, so the same binary fronts a Java daemon, a Zig one, or anything else.

const std = @import("std");
const linux = std.os.linux;

const AF_UNIX: u32 = 1;
const SOCK_STREAM: u32 = 1;
const SHUT_WR: u32 = 1;
const STDIN: i32 = 0;
const STDOUT: i32 = 1;

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

const request_capacity = 1 << 16;
const reply_capacity = 1 << 16;

fn failed(result: usize) bool {
    return @as(isize, @bitCast(result)) < 0;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (failed(written)) return false;
        offset += written;
    }
    return true;
}

fn complain(message: []const u8) void {
    _ = writeAll(STDERR_FILENO, message);
}

const STDERR_FILENO: i32 = 2;

pub fn main(init: std.process.Init) u8 {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return 2;
    defer args.deinit();
    _ = args.next(); // the program itself
    const socket_path = args.next() orelse {
        complain("tiny: usage: tiny <socket-path>  (request on stdin, reply on stdout)\n");
        return 2;
    };

    // 1. The request, from stdin.
    var request: [request_capacity]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request.len) {
        const got = linux.read(STDIN, request[request_len..].ptr, request.len - request_len);
        if (failed(got) or got == 0) break;
        request_len += got;
    }

    // 2. Connect.
    var address = std.mem.zeroes(SockaddrUn);
    address.family = AF_UNIX;
    const target: []const u8 = socket_path;
    if (target.len >= address.path.len) {
        complain("tiny: socket path too long\n");
        return 1;
    }
    @memcpy(address.path[0..target.len], target);

    const created = linux.socket(AF_UNIX, SOCK_STREAM, 0);
    if (failed(created)) {
        complain("tiny: cannot create socket\n");
        return 1;
    }
    const fd: i32 = @intCast(created);
    if (failed(linux.connect(fd, @ptrCast(&address), @sizeOf(SockaddrUn)))) {
        complain("tiny: cannot connect\n");
        return 1;
    }

    // 3. Send, half-close, drain the reply to stdout.
    if (request_len > 0 and !writeAll(fd, request[0..request_len])) {
        complain("tiny: cannot write the request\n");
        return 1;
    }
    _ = linux.shutdown(fd, SHUT_WR);

    var reply: [reply_capacity]u8 = undefined;
    while (true) {
        const got = linux.read(fd, &reply, reply.len);
        if (failed(got) or got == 0) break;
        if (!writeAll(STDOUT, reply[0..got])) break;
    }

    _ = linux.close(fd);
    return 0;
}
