// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! socutil-cli — a socat alternative: talk to one unix-domain socket from the shell.
//!
//! Connects to a unix-domain socket and relays stdin to the socket and the socket
//! to stdout, byte for byte. It is the shell half of socutil: where `socutil` is the
//! browser UI, `socutil-cli` is the command-line relay.
//!
//! This is a forking alternative to `socat`: one lightweight process per call, no
//! per-message fork. See SHELL.md for how to call compatible unix sockets from a
//! shell, and how to skip the fork entirely where a shell allows it (via shell
//! functions that hold the connection open).
//!
//! Termination, in both directions. The socket->stdout pump owns the process
//! lifetime: when the peer closes it flushes what it has and exits the process, so a
//! closed peer can never leave us alive reading stdin — a blocked stdin read cannot
//! be interrupted portably, so exiting is the only honest way to release it. When
//! stdin ends first we half-close the socket's write side (`shutdown(.send)`) so a
//! peer waiting for input sees end-of-stream, then keep draining the socket until the
//! peer closes; exiting at stdin EOF instead would truncate the reply that the peer
//! is about to send.
//!
//! The relay reads whatever has arrived, never a full buffer's worth. `readSliceShort`
//! would be wrong here: it keeps reading until its buffer is full or the stream ends,
//! so an interactive peer that sends a 32-byte greeting would be held back until 8 KiB
//! arrived or the connection closed.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const buf_len: usize = 8192;

/// When the relay last moved a byte, on the monotonic clock, shared by the pumps and the watchdog.
/// Only meaningful when `-t` was given; the default keeps the old "wait as long as the peer does".
var last_activity_ns: std.atomic.Value(u64) = .init(0);

fn touch(io: Io) void {
    last_activity_ns.store(@intCast(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds), .monotonic);
}

/// The opt-in idle timeout. A watchdog thread rather than a read timeout on purpose: the timeout is
/// about *either* direction being quiet, and a socket receive timeout would fire while stdin was
/// still streaming. It sleeps in short steps so the deadline is honest to within that step.
fn watchdog(io: Io, timeout_ms: u64) void {
    const timeout_ns = timeout_ms * std.time.ns_per_ms;
    const step_ms: u64 = @max(1, @min(50, timeout_ms / 4));
    while (true) {
        io.sleep(.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
        const now: u64 = @intCast(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
        const last = last_activity_ns.load(.monotonic);
        if (now > last and now - last >= timeout_ns) {
            std.debug.print("socutil-cli: no activity before the timeout\n", .{});
            // 124 is what timeout(1) uses, and what tiny exits with.
            std.process.exit(124);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var socket_path: ?[]const u8 = null;
    var verbose = false;
    var timeout_ms: ?u64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("socutil-cli: -t needs a number of milliseconds\n\n", .{});
                std.process.exit(2);
            }
            timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("socutil-cli: -t needs a number of milliseconds\n\n", .{});
                std.process.exit(2);
            };
        } else if (arg.len != 0 and arg[0] == '-') {
            std.debug.print("socutil-cli: unknown option {s}\n\n", .{arg});
            printUsage();
            std.process.exit(2);
        } else {
            socket_path = arg;
            break;
        }
    }

    if (socket_path == null) {
        std.debug.print("socutil-cli: no socket path given\n\n", .{});
        printUsage();
        std.process.exit(2);
    }

    if (verbose) {
        std.debug.print("socutil-cli: connecting to {s}\n", .{socket_path.?});
    }

    const address = net.UnixAddress.init(socket_path.?) catch |err| {
        std.debug.print("socutil-cli: cannot init address: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const stream = address.connect(io) catch |err| {
        std.debug.print("socutil-cli: cannot connect to {s}: {s}\n", .{ socket_path.?, @errorName(err) });
        std.process.exit(1);
    };
    defer stream.close(io);

    if (verbose) {
        std.debug.print("socutil-cli: connected; relaying stdin<->socket\n", .{});
    }

    var stdout_buf: [buf_len]u8 = undefined;
    var socket_read_buf: [buf_len]u8 = undefined;
    var socket_write_buf: [buf_len]u8 = undefined;

    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();

    var stdout_writer = Io.File.writer(stdout, io, &stdout_buf);
    var socket_reader = stream.reader(io, &socket_read_buf);
    var socket_writer = stream.writer(io, &socket_write_buf);

    // Only started when asked: the default costs no thread, which is why `-t` is opt-in.
    touch(io);
    if (timeout_ms) |ms| {
        const watcher = std.Thread.spawn(.{}, watchdog, .{ io, ms }) catch |err| {
            std.debug.print("socutil-cli: cannot start the timeout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        watcher.detach();
    }

    const t1 = std.Thread.spawn(.{}, pumpStdinToSocket, .{StdinPump{
        .io = io,
        .stdin = stdin,
        .stream = stream,
        .socket_writer = &socket_writer.interface,
    }}) catch |err| {
        std.debug.print("socutil-cli: cannot spawn thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    // Nobody joins the stdin pump: the process ends when the socket pump does, and a
    // detached thread is exactly what lets that happen while it is blocked in a read.
    t1.detach();

    const t2 = std.Thread.spawn(.{}, pumpSocketToStdout, .{SocketPump{
        .io = io,
        .reader = &socket_reader.interface,
        .stdout_writer = &stdout_writer.interface,
    }}) catch |err| {
        std.debug.print("socutil-cli: cannot spawn thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    // The socket->stdout pump exits the process when the peer closes; joining it is
    // only here to keep `main` from returning while the relay still has data to drain.
    t2.join();
}

/// stdin -> socket. On end of input, send FIN and let the socket pump drain the reply.
fn pumpStdinToSocket(args: StdinPump) void {
    var buf: [buf_len]u8 = undefined;
    while (true) {
        // A single streaming read returns as soon as any bytes are available (or
        // `error.EndOfStream`), unlike a buffered reader that fills its buffer.
        const n = args.stdin.readStreaming(args.io, &.{&buf}) catch break;
        if (n == 0) break;
        touch(args.io);
        args.socket_writer.writeAll(buf[0..n]) catch break;
        args.socket_writer.flush() catch break;
    }
    // Half-close so a peer that waits for more input sees end-of-stream and closes.
    // If the peer is already gone this fails harmlessly; the socket pump owns exit.
    args.stream.shutdown(args.io, .send) catch {};
}

/// socket -> stdout. When the peer closes (or either side fails), flush and exit:
/// this is the direction that decides the process lifetime.
fn pumpSocketToStdout(args: SocketPump) void {
    var buf: [buf_len]u8 = undefined;
    var data = [_][]u8{&buf};
    var ok = true;
    while (true) {
        // One `readVec` call forwards exactly what has arrived. `readSliceShort`
        // must not be used: it keeps reading until the buffer is full or the peer
        // closes, so a small frame would be held back and a live peer would look
        // like a dead one.
        const n = args.reader.readVec(&data) catch |err| switch (err) {
            // The peer closing is the normal end of a relay, not a failure.
            error.EndOfStream => break,
            else => {
                ok = false;
                break;
            },
        };
        if (n == 0) break;
        touch(args.io);
        args.stdout_writer.writeAll(buf[0..n]) catch {
            ok = false;
            break;
        };
        args.stdout_writer.flush() catch {
            ok = false;
            break;
        };
    }
    std.process.exit(if (ok) 0 else 1);
}

const StdinPump = struct {
    io: Io,
    stdin: Io.File,
    stream: net.Stream,
    socket_writer: *Io.Writer,
};

const SocketPump = struct {
    io: Io,
    reader: *Io.Reader,
    stdout_writer: *Io.Writer,
};

fn printUsage() void {
    std.debug.print(
        \\usage: socutil-cli [options] <socket-path>
        \\
        \\Connects to a unix-domain socket and relays stdin to the socket and the
        \\socket to stdout, byte for byte. A socat alternative for the shell.
        \\
        \\options:
        \\  -t, --timeout <ms>  give up when neither side moves for this long (default: wait)
        \\  -v, --verbose       print connection progress to stderr
        \\  -h, --help          show this help
        \\
        \\The timeout is an idle timeout and exits with status 124, the same code `timeout(1)`
        \\uses. Without it the relay waits as long as the peer does.
        \\
        \\Examples:
        \\  echo "ping" | socutil-cli /tmp/myapp.sock
        \\  socutil-cli /tmp/myapp.sock < command.txt > response.txt
        \\
        \\See SHELL.md for how to call compatible unix sockets from a shell, and how
        \\to skip the fork where a shell allows it.
        \\
    , .{});
}

