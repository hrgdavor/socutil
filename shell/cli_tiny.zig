// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! A deliberately tiny client for a unix socket.
//!
//! Two shapes:
//!
//!   tiny --socket <path> <script> [args...]
//!   TINY_SOCKET=<path> tiny <script> [args...]
//!       Send the script call — argv[0] (this client), the script path, then its parameters — one per line. After
//!       the last line, half-close the socket; copy the reply to stdout and exit. tiny's own options (`--socket`,
//!       `-t`) are consumed and are not part of the call.
//!
//!   tiny <socket-path>
//!   tiny --relay <socket-path>
//!       The original byte pump: relay stdin to the socket and the socket to stdout, both directions at once.
//!
//! Built for the case where a daemon does the real work and the client must not be the slow part:
//!
//!     zig build-exe -target x86_64-linux-musl -O ReleaseSmall -fstrip -fsingle-threaded \
//!         -fno-llvm -lc none ... cli_tiny.zig
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
//!
//! In relay mode there is no framing: the request is a byte buffer and the reply is copied
//! straight to stdout. In argument mode the framing is one line per argument and EOF; it is a small,
//! explicit protocol, not a guess about the peer's.

const std = @import("std");
const linux = std.os.linux;

const AF_UNIX: u32 = 1;
const SOCK_STREAM: u32 = 1;
const SHUT_WR: u32 = 1;
const STDIN: i32 = 0;
const STDOUT: i32 = 1;
const STDERR_FILENO: i32 = 2;

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

const chunk = 1 << 14;

/// A fixed ceiling instead of an allocator: a script call with more than this many arguments is a mistake, not a
/// workload. The array lives on the stack and costs nothing until it is used.
const max_positionals = 1024;

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

fn usage() void {
    complain(
        \\tiny: tiny [options] <socket-path>                 relay stdin to the socket (legacy)
        \\      tiny --relay <socket-path>                   relay stdin, explicit
        \\      tiny --socket <path> <script> [args...]      send client, script and args, one per line
        \\      TINY_SOCKET=<path> tiny <script> [args...]   same, endpoint from the environment
        \\  -t, --timeout <ms>   give up when no activity for this long (exit 124)
        \\  -h, --help           this text
        \\
    );
}

/// Exit code when the opt-in timeout fires: the same one `timeout(1)` uses, so a script that already
/// checks for 124 keeps working.
const timeout_exit: u8 = 124;

/// Connect to `path`. Returns null after printing the reason; the caller maps that to exit 1.
fn connectTo(path: []const u8) ?i32 {
    var address = std.mem.zeroes(SockaddrUn);
    address.family = AF_UNIX;
    if (path.len >= address.path.len) {
        complain("tiny: socket path too long\n");
        return null;
    }
    @memcpy(address.path[0..path.len], path);

    const created = linux.socket(AF_UNIX, SOCK_STREAM, 0);
    if (failed(created)) {
        complain("tiny: cannot create socket\n");
        return null;
    }
    const fd: i32 = @intCast(created);
    if (failed(linux.connect(fd, @ptrCast(&address), @sizeOf(SockaddrUn)))) {
        complain("tiny: cannot connect\n");
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// The original byte pump: stdin → socket, socket → stdout, both directions at once, single-threaded.
fn relay(fd: i32, timeout_ms: ?i32) u8 {
    var buffer: [chunk]u8 = undefined;
    var stdin_open = true;
    var socket_open = true;
    while (socket_open) {
        var fds = [2]std.posix.pollfd{
            .{ .fd = STDIN, .events = if (stdin_open) std.posix.POLL.IN else 0, .revents = 0 },
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, timeout_ms orelse -1) catch break;
        if (ready == 0) {
            // Only reachable when `-t` was given: `poll` with -1 cannot return 0.
            complain("tiny: no activity before the timeout\n");
            _ = linux.close(fd);
            return timeout_exit;
        }

        // Any revents means "ask this descriptor": a pipe at end-of-stream reports POLLHUP without
        // POLLIN, and reading is the only reliable way to learn it. Checking POLLIN alone spins.
        if (stdin_open and fds[0].revents != 0) {
            const got = linux.read(STDIN, &buffer, buffer.len);
            if (failed(got) or got == 0) {
                stdin_open = false;
                _ = linux.shutdown(fd, SHUT_WR);
            } else if (!writeAll(fd, buffer[0..got])) {
                break;
            }
        }
        if (fds[1].revents != 0) {
            const got = linux.read(fd, &buffer, buffer.len);
            if (failed(got) or got == 0) {
                socket_open = false;
                break;
            }
            if (!writeAll(STDOUT, buffer[0..got])) break;
        }
    }

    _ = linux.close(fd);
    return 0;
}

/// The script-call shape: write `program`, then every script/argument, one per line; half-close; copy the reply.
fn argumentMode(fd: i32, program: []const u8, script_args: []const []const u8, timeout_ms: ?i32) u8 {
    if (!writeAll(fd, program) or !writeAll(fd, "\n")) {
        _ = linux.close(fd);
        return 1;
    }
    for (script_args) |arg| {
        if (!writeAll(fd, arg) or !writeAll(fd, "\n")) {
            _ = linux.close(fd);
            return 1;
        }
    }
    _ = linux.shutdown(fd, SHUT_WR);

    var buffer: [chunk]u8 = undefined;
    while (true) {
        if (timeout_ms) |ms| {
            var fds = [1]std.posix.pollfd{
                .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, ms) catch {
                _ = linux.close(fd);
                return 1;
            };
            if (ready == 0) {
                complain("tiny: no activity before the timeout\n");
                _ = linux.close(fd);
                return timeout_exit;
            }
        }

        const got = linux.read(fd, &buffer, buffer.len);
        if (failed(got)) {
            _ = linux.close(fd);
            return 1;
        }
        if (got == 0) break;
        if (!writeAll(STDOUT, buffer[0..got])) {
            _ = linux.close(fd);
            return 1;
        }
    }

    _ = linux.close(fd);
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return 2;
    defer args.deinit();
    const program = args.next() orelse "tiny";

    var timeout_ms: ?i32 = null;
    var endpoint: ?[]const u8 = null;
    if (init.environ_map.get("TINY_SOCKET")) |value| {
        if (value.len != 0) endpoint = value;
    }

    // The first positional decides the mode: with an endpoint it is the script; without one it is the legacy
    // relay's socket. Options are still parsed after a relay socket (so `tiny socket -t 500` keeps working), but
    // stop at the script, because everything after a script is a script argument even when it starts with `-`.
    var relay_mode = false;
    var arg_mode = endpoint != null;
    var socket_path: ?[]const u8 = null;
    var positionals: [max_positionals][]const u8 = undefined;
    var positional_count: usize = 0;
    var parsing_options = true;

    while (args.next()) |arg| {
        if (parsing_options) {
            if (std.mem.eql(u8, arg, "--")) {
                parsing_options = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                usage();
                return 0;
            }
            if (std.mem.eql(u8, arg, "--relay") or std.mem.eql(u8, arg, "-r")) {
                relay_mode = true;
                arg_mode = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--socket") or std.mem.eql(u8, arg, "-s")) {
                endpoint = args.next() orelse {
                    complain("tiny: --socket needs a path\n");
                    return 2;
                };
                arg_mode = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--socket=")) {
                const value = arg["--socket=".len..];
                if (value.len == 0) {
                    complain("tiny: --socket needs a path\n");
                    return 2;
                }
                endpoint = value;
                arg_mode = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
                const text = args.next() orelse {
                    complain("tiny: -t needs a number of milliseconds\n");
                    return 2;
                };
                timeout_ms = std.fmt.parseInt(i32, text, 10) catch {
                    complain("tiny: -t needs a number of milliseconds\n");
                    return 2;
                };
                if (timeout_ms.? < 0) {
                    complain("tiny: -t needs a non-negative number of milliseconds\n");
                    return 2;
                }
                continue;
            }
            if (arg.len > 0 and arg[0] == '-') {
                usage();
                return 2;
            }
        }

        // A positional.
        if (!arg_mode) {
            // Legacy relay: one positional, the socket. Options may still follow it.
            if (socket_path != null) {
                usage();
                return 2;
            }
            socket_path = arg;
            relay_mode = true;
            continue;
        }

        // Argument mode: the script and then its parameters. After this point every argument is a script argument.
        if (positional_count == max_positionals) {
            complain("tiny: too many arguments\n");
            return 2;
        }
        positionals[positional_count] = arg;
        positional_count += 1;
        parsing_options = false;
    }

    if (relay_mode) {
        const path = socket_path orelse endpoint orelse {
            usage();
            return 2;
        };
        if (positional_count != 0) {
            usage();
            return 2;
        }
        const fd = connectTo(path) orelse return 1;
        return relay(fd, timeout_ms);
    }

    if (endpoint == null or positional_count == 0) {
        usage();
        return 2;
    }

    // One line per argument cannot carry a newline. Refuse before connecting, so nothing is sent.
    if (std.mem.indexOfScalar(u8, program, '\n') != null) {
        complain("tiny: an argument contains a newline; use --relay for byte payloads\n");
        return 2;
    }
    for (positionals[0..positional_count]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '\n') != null) {
            complain("tiny: an argument contains a newline; use --relay for byte payloads\n");
            return 2;
        }
    }

    const fd = connectTo(endpoint.?) orelse return 1;
    return argumentMode(fd, program, positionals[0..positional_count], timeout_ms);
}
