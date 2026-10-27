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

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const buf_len: usize = 8192;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var socket_path: ?[]const u8 = null;
    var verbose = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
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
        std.debug.print("socutil-cli: cannot connect to {s}: {s}\n", .{socket_path.?, @errorName(err)});
        std.process.exit(1);
    };
    defer stream.close(io);

    if (verbose) {
        std.debug.print("socutil-cli: connected; relaying stdin<->socket\n", .{});
    }

    var stdin_buf: [buf_len]u8 = undefined;
    var stdout_buf: [buf_len]u8 = undefined;
    var socket_read_buf: [buf_len]u8 = undefined;
    var socket_write_buf: [buf_len]u8 = undefined;

    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();

    var stdin_reader = Io.File.reader(stdin, io, &stdin_buf);
    var stdout_writer = Io.File.writer(stdout, io, &stdout_buf);
    var socket_reader = stream.reader(io, &socket_read_buf);
    var socket_writer = stream.writer(io, &socket_write_buf);

    const t1 = std.Thread.spawn(.{}, pump, .{ PumpArgs{ .reader = &stdin_reader.interface, .writer = &socket_writer.interface } }) catch |err| {
        std.debug.print("socutil-cli: cannot spawn thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const t2 = std.Thread.spawn(.{}, pump, .{ PumpArgs{ .reader = &socket_reader.interface, .writer = &stdout_writer.interface } }) catch |err| {
        std.debug.print("socutil-cli: cannot spawn thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    t1.join();
    t2.join();
}

const PumpArgs = struct {
    reader: *Io.Reader,
    writer: *Io.Writer,
};

fn pump(args: PumpArgs) void {
    var buf: [buf_len]u8 = undefined;
    while (true) {
        const n = args.reader.readSliceShort(&buf) catch return;
        if (n == 0) return;
        args.writer.writeAll(buf[0..n]) catch return;
        args.writer.flush() catch return;
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: socutil-cli [options] <socket-path>
        \\
        \\Connects to a unix-domain socket and relays stdin to the socket and the
        \\socket to stdout, byte for byte. A socat alternative for the shell.
        \\
        \\options:
        \\  -v, --verbose   print connection progress to stderr
        \\  -h, --help      show this help
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
