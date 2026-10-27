// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! socutil library: the HTTP server and the socket discovery, importable by other packages.
//!
//! This is the "web part" of socutil. A dependent package (for example the fs-meta engine) can
//! include it to serve a browser UI over a TCP port, relaying any of the unix-domain sockets it
//! scans — one UI controlling many sockets. The two executables in this package are thin clients
//! of this library: `socutil` runs the server in the foreground, and `socutil-cli` is a socat
//! alternative that talks to one socket from the shell.
//!
//! ## Public surface
//!
//! | item       | what it is                                                              |
//! | ---------- | ------------------------------------------------------------------------- |
//! | `Config`   | the server configuration: host, port, and the directories to scan        |
//! | `run`      | start the HTTP server and serve until canceled (blocks)                   |
//! | `server`   | the HTTP routing, the SSE tail, the WebSocket tunnel, the session lifecycle |
//! | `sockets`  | the unix-socket discovery: `Dir`, `Entry`, `Scan`, `makeName`, `scan`      |
//!
//! `run` owns its own arena, so a caller only needs the I/O handle, a general-purpose allocator,
//! and a `Config`. The directories in `Config.dirs` are scanned fresh on every request, so a
//! running server always sees the current set of sockets.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub const server = @import("server.zig");
pub const sockets = @import("sockets.zig");

pub const default_port: u16 = 8765;

/// The server configuration. `dirs` is the set of directories to scan for unix-domain sockets;
/// a socket is addressed by name (`<dir-name>.<file-name>`), never by path.
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    dirs: std.ArrayList(sockets.Dir) = .empty,
};

/// Start the HTTP server and serve until the I/O is canceled. Blocks for the life of the process.
///
/// This is what the `socutil` executable calls, and what an embedding package (fs-meta) calls
/// from a worker thread when it wants an optional HTTP endpoint alongside its own socket.
pub fn run(io: Io, gpa: std.mem.Allocator, config: Config) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dirs = config.dirs.items;
    const app = try arena.create(server.App);
    app.* = .{
        .gpa = gpa,
        .io = io,
        .dirs = dirs,
    };

    const address = net.IpAddress.resolve(io, config.host, config.port) catch |err| {
        std.debug.print("socutil: cannot resolve {s}: {s}\n", .{ config.host, @errorName(err) });
        return error.ListenFailed;
    };
    var listener = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print(
            "socutil: cannot listen on {s}:{d}: {s}\n",
            .{ config.host, config.port, @errorName(err) },
        );
        return error.ListenFailed;
    };
    defer listener.deinit(io);

    try printListenUrl(io, config.host, listener.socket.address.getPort());

    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (err == error.Canceled) return;
            std.log.err("socutil: accept failed: {s}", .{@errorName(err)});
            io.sleep(.fromMilliseconds(20), .awake) catch {};
            continue;
        };
        const thread = std.Thread.spawn(.{}, server.connectionThread, .{ app, stream }) catch |err| {
            std.log.err("socutil: cannot spawn connection thread: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

pub fn printListenUrl(io: Io, host: []const u8, port: u16) !void {
    var buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &stdout.interface;

    try writer.writeAll("socutil listening on http://");
    if (std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "[")) {
        try writer.print("[{s}]", .{host});
    } else {
        try writer.writeAll(host);
    }
    try writer.print(":{d}/\n", .{port});
    try writer.flush();
}

test {
    _ = @import("server.zig");
    _ = @import("sockets.zig");
}
