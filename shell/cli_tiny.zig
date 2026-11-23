// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! A deliberately tiny client for a unix socket.
//!
//! Two shapes:
//!
//!   tiny --socket <path> <command> [args...]
//!   TINY_SOCKET=<path> tiny <command> [args...]
//!       Send one JSON preamble line with `command`, `args`, the current directory and the environment, then relay
//!       stdin to the socket and the response to stdout. The protocol is TINY-PROTOCOL.md.
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

/// TINY-PROTOCOL.md § 9. The preamble is rejected before connecting if it would exceed this.
const max_preamble = 1 << 20;
const max_args = 4096;
const max_env = 4096;
const max_positionals = max_args + 1; // the command plus its arguments
const max_path = 4096;

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
        \\      tiny --socket <path> <command> [args...]      JSON preamble + stdin/stdout
        \\      TINY_SOCKET=<path> tiny <command> [args...]   same, endpoint from the environment
        \\  --no-env             omit the env key (the default sends the process environment)
        \\  -t, --timeout <ms>   give up when no activity for this long (exit 124)
        \\  -h, --help           this text
        \\  Protocol: TINY-PROTOCOL.md (one JSON line, then raw stdin/stdout).
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

/// A small buffered writer so JSON escaping does not cost a syscall per byte.
const JsonOut = struct {
    fd: i32,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    failed: bool = false,

    fn flush(self: *JsonOut) void {
        if (self.failed or self.len == 0) return;
        if (!writeAll(self.fd, self.buf[0..self.len])) self.failed = true;
        self.len = 0;
    }

    fn putByte(self: *JsonOut, byte: u8) void {
        if (self.failed) return;
        if (self.len == self.buf.len) self.flush();
        if (self.failed) return;
        self.buf[self.len] = byte;
        self.len += 1;
    }

    fn put(self: *JsonOut, bytes: []const u8) void {
        for (bytes) |byte| self.putByte(byte);
    }

    fn putHexByte(self: *JsonOut, byte: u8) void {
        const digits = "0123456789abcdef";
        self.putByte(digits[byte >> 4]);
        self.putByte(digits[byte & 0xf]);
    }

    /// A JSON string. `s` must already be valid UTF-8 and contain no NUL.
    fn putString(self: *JsonOut, s: []const u8) void {
        self.putByte('"');
        for (s) |byte| {
            switch (byte) {
                '"' => self.put("\\\""),
                '\\' => self.put("\\\\"),
                '\n' => self.put("\\n"),
                '\r' => self.put("\\r"),
                '\t' => self.put("\\t"),
                0x08 => self.put("\\b"),
                0x0c => self.put("\\f"),
                else => {
                    if (byte < 0x20 or byte == 0x7f) {
                        self.put("\\u00");
                        self.putHexByte(byte);
                    } else {
                        self.putByte(byte);
                    }
                },
            }
        }
        self.putByte('"');
    }
};

fn validText(s: []const u8, allow_empty: bool) bool {
    if (!allow_empty and s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(s);
}

fn escapedLen(s: []const u8) usize {
    var n: usize = 2; // the quotes
    for (s) |byte| {
        n += switch (byte) {
            '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
            else => if (byte < 0x20 or byte == 0x7f) 6 else 1,
        };
    }
    return n;
}

/// TINY-PROTOCOL.md § 9: compute the preamble length before writing, so an over-limit request fails
/// before a byte is sent.
fn preambleLen(
    command: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    include_env: bool,
    env_keys: []const []const u8,
    env_values: []const []const u8,
) ?usize {
    var n: usize = "{\"v\":1,\"command\":".len;
    n += escapedLen(command);
    n += ",\"args\":[".len;
    for (args, 0..) |arg, i| {
        if (i != 0) n += 1;
        n += escapedLen(arg);
    }
    n += "],\"cwd\":".len;
    n += escapedLen(cwd);
    if (include_env) {
        n += ",\"env\":{".len;
        for (env_keys, env_values, 0..) |key, value, i| {
            if (i != 0) n += 1;
            n += escapedLen(key);
            n += 1; // colon
            n += escapedLen(value);
        }
        n += 1; // closing brace of env
    }
    n += "}\n".len;
    return if (n > max_preamble) null else n;
}

fn writePreamble(
    out: *JsonOut,
    command: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    include_env: bool,
    env_keys: []const []const u8,
    env_values: []const []const u8,
) void {
    out.put("{\"v\":1,\"command\":");
    out.putString(command);
    out.put(",\"args\":[");
    for (args, 0..) |arg, i| {
        if (i != 0) out.putByte(',');
        out.putString(arg);
    }
    out.put("],\"cwd\":");
    out.putString(cwd);
    if (include_env) {
        out.put(",\"env\":{");
        for (env_keys, env_values, 0..) |key, value, i| {
            if (i != 0) out.putByte(',');
            out.putString(key);
            out.putByte(':');
            out.putString(value);
        }
        out.putByte('}');
    }
    out.put("}\n");
    out.flush();
}

/// After the preamble: relay stdin to the socket, the socket to stdout; half-close at stdin EOF.
fn jsonMode(fd: i32, timeout_ms: ?i32) u8 {
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
            complain("tiny: no activity before the timeout\n");
            _ = linux.close(fd);
            return timeout_exit;
        }

        if (stdin_open and fds[0].revents != 0) {
            const got = linux.read(STDIN, &buffer, buffer.len);
            if (failed(got) or got == 0) {
                stdin_open = false;
                _ = linux.shutdown(fd, SHUT_WR);
            } else if (!writeAll(fd, buffer[0..got])) {
                // The server is not reading stdin. Stop sending, but keep reading its response.
                stdin_open = false;
                _ = linux.shutdown(fd, SHUT_WR);
            }
        }
        if (fds[1].revents != 0) {
            const got = linux.read(fd, &buffer, buffer.len);
            if (failed(got)) {
                _ = linux.close(fd);
                return 1;
            }
            if (got == 0) {
                socket_open = false;
                break;
            }
            if (!writeAll(STDOUT, buffer[0..got])) {
                _ = linux.close(fd);
                return 1;
            }
        }
    }

    _ = linux.close(fd);
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return 2;
    defer args.deinit();
    _ = args.next(); // the program itself; the command is the first positional

    var timeout_ms: ?i32 = null;
    var endpoint: ?[]const u8 = null;
    if (init.environ_map.get("TINY_SOCKET")) |value| {
        if (value.len != 0) endpoint = value;
    }

    // The first positional decides the mode: with an endpoint it is the command; without one it is the legacy
    // relay's socket. Options are still parsed after a relay socket (so `tiny socket -t 500` keeps working), but
    // stop at the command, because everything after a command is one of its arguments even when it starts with `-`.
    var relay_mode = false;
    var json_mode = endpoint != null;
    var send_env = true;
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
                json_mode = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--socket") or std.mem.eql(u8, arg, "-s")) {
                endpoint = args.next() orelse {
                    complain("tiny: --socket needs a path\n");
                    return 2;
                };
                json_mode = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--socket=")) {
                const value = arg["--socket=".len..];
                if (value.len == 0) {
                    complain("tiny: --socket needs a path\n");
                    return 2;
                }
                endpoint = value;
                json_mode = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-env")) {
                send_env = false;
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
        if (!json_mode) {
            // Legacy relay: one positional, the socket. Options may still follow it.
            if (socket_path != null) {
                usage();
                return 2;
            }
            socket_path = arg;
            relay_mode = true;
            continue;
        }

        // JSON mode: the command and then its arguments. After this point every argument is a command argument.
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

    const command = positionals[0];
    const command_args = positionals[1..positional_count];
    if (command_args.len > max_args) {
        complain("tiny: too many arguments\n");
        return 2;
    }

    if (!validText(command, false)) {
        complain("tiny: command is not valid UTF-8, or is empty\n");
        return 2;
    }
    for (command_args) |arg| {
        if (!validText(arg, true)) {
            complain("tiny: an argument is not valid UTF-8\n");
            return 2;
        }
    }

    var cwd_buf: [max_path]u8 = undefined;
    const got_cwd = linux.getcwd(cwd_buf[0..].ptr, cwd_buf.len);
    if (failed(got_cwd)) {
        complain("tiny: cannot get current directory\n");
        return 1;
    }
    const cwd_end = std.mem.indexOfScalar(u8, cwd_buf[0..], 0) orelse {
        complain("tiny: cannot get current directory\n");
        return 1;
    };
    const cwd = cwd_buf[0..cwd_end];
    if (cwd.len == 0 or cwd[0] != '/') {
        complain("tiny: current directory is not absolute\n");
        return 1;
    }
    if (!validText(cwd, false)) {
        complain("tiny: current directory is not valid UTF-8\n");
        return 2;
    }

    var env_keys: []const []const u8 = &.{};
    var env_values: []const []const u8 = &.{};
    if (send_env) {
        env_keys = init.environ_map.keys();
        env_values = init.environ_map.values();
    }
    if (env_keys.len > max_env) {
        complain("tiny: too many environment variables\n");
        return 2;
    }
    for (env_keys, env_values) |key, value| {
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null) {
            complain("tiny: invalid environment variable name\n");
            return 2;
        }
        if (!validText(key, false) or !validText(value, true)) {
            complain("tiny: an environment variable is not valid UTF-8\n");
            return 2;
        }
    }

    if (preambleLen(command, command_args, cwd, send_env, env_keys, env_values) == null) {
        complain("tiny: request preamble is too large\n");
        return 2;
    }

    const fd = connectTo(endpoint.?) orelse return 1;
    var out = JsonOut{ .fd = fd };
    writePreamble(&out, command, command_args, cwd, send_env, env_keys, env_values);
    if (out.failed) {
        _ = linux.close(fd);
        return 1;
    }
    return jsonMode(fd, timeout_ms);
}
