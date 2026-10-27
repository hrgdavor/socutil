// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! socutil — a tiny browser UI for unix-domain sockets.
//!
//! It serves an embedded HTML/JS page, lists unix sockets from configured
//! directories, and relays one to the browser: a WebSocket byte tunnel by
//! default, or a Server-Sent Events tail with commands over a plain POST.
//!
//! This executable is a thin client of the `socutil` library (`lib.zig`): it parses
//! arguments into a `Config` and hands off to `lib.run`, which owns the listener and
//! the per-connection threads. The library is what an embedding package (fs-meta)
//! imports to get the same web part; `socutil-cli` is the shell half.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const lib = @import("lib.zig");
const sockets = lib.sockets;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var config: lib.Config = .{};
    parseArgs(args, arena, &config) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage();
            return;
        },
        else => {
            std.debug.print("socutil: {s}\n\n", .{@errorName(err)});
            printUsage();
            std.process.exit(2);
        },
    };

    if (config.dirs.items.len == 0) try addDefaultDirs(arena, init, &config);

    try lib.run(io, init.gpa, config);
}

fn parseArgs(args: []const [:0]const u8, arena: std.mem.Allocator, config: *lib.Config) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--listen") or std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try addDirOption(arena, config, args[i]);
        } else if (arg.len != 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            try addDir(arena, config, arg, null);
        }
    }
}

/// `--dir [name=]<path>`. The name is what clients see and send; it defaults to
/// the directory's basename. A value whose part before `=` contains a path
/// separator is a path that happens to contain `=`, not a name.
fn addDirOption(arena: std.mem.Allocator, config: *lib.Config, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '=')) |eq| {
        const prefix = value[0..eq];
        const suffix = value[eq + 1 ..];
        if (validDirName(prefix)) return addDir(arena, config, suffix, prefix);
        if (std.mem.indexOfAny(u8, prefix, "/\\") == null) return error.InvalidDirName;
    }
    try addDir(arena, config, value, null);
}

fn addDir(
    arena: std.mem.Allocator,
    config: *lib.Config,
    path: []const u8,
    explicit_name: ?[]const u8,
) !void {
    if (path.len == 0) return error.EmptyDirPath;
    for (config.dirs.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }

    const base = explicit_name orelse try derivedDirName(arena, path, config.dirs.items.len);
    var name = base;
    var suffix: usize = 2;
    while (dirNameTaken(config, name)) {
        if (explicit_name != null) return error.DuplicateDirName;
        name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, suffix });
        suffix += 1;
    }

    try config.dirs.append(arena, .{ .name = name, .path = path });
}

fn dirNameTaken(config: *const lib.Config, name: []const u8) bool {
    for (config.dirs.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return true;
    }
    return false;
}

/// A configured name has no path separator and no dot, so `<dir>.<file>` is
/// unambiguous and can never be mistaken for a path.
fn validDirName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn derivedDirName(arena: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const base = if (trimmed.len == 0) "" else std.fs.path.basename(trimmed);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return std.fmt.allocPrint(arena, "d{d}", .{index});
    }

    const out = try arena.alloc(u8, @min(base.len, 32));
    for (base[0..out.len], out) |c, *dest| {
        dest.* = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }
    return out;
}

fn addDefaultDirs(arena: std.mem.Allocator, init: std.process.Init, config: *lib.Config) !void {
    if (init.environ_map.get("XDG_RUNTIME_DIR")) |path| try addDir(arena, config, path, null);
    if (builtin.os.tag == .windows) {
        if (init.environ_map.get("TEMP")) |path| try addDir(arena, config, path, null);
        if (init.environ_map.get("TMP")) |path| try addDir(arena, config, path, null);
    } else {
        try addDir(arena, config, "/tmp", null);
        try addDir(arena, config, "/var/run", null);
        try addDir(arena, config, "/run", null);
    }
    try addDir(arena, config, ".", null);
}

fn printUsage() void {
    std.debug.print(
        \\usage: socutil [options] [directory...]
        \\
        \\Serves a small browser UI that lists unix-domain sockets found in the
        \\given directories and relays one of them, over a WebSocket byte tunnel
        \\or a Server-Sent Events tail with commands sent by POST.
        \\
        \\options:
        \\  --listen <host>     address to bind (default 127.0.0.1)
        \\  --port <port>       TCP port to bind (default 8765, 0 = any free port)
        \\  --dir [name=]<path> directory to scan; may be repeated; the name
        \\                      defaults to the directory's basename
        \\  -h, --help          show this help
        \\
        \\A socket is selected by name, never by path: the name is
        \\"<directory-name>.<file-name>" and the server resolves it against a fresh
        \\scan, so a request can only choose from the listed sockets.
        \\
        \\With no directory arguments, platform defaults are used:
        \\  POSIX:   $XDG_RUNTIME_DIR, /tmp, /var/run, /run, .
        \\  Windows: %TEMP%, %TMP%, .
        \\
        \\This is the HTTP half of socutil. The shell half is `socutil-cli`, a socat
        \\alternative that talks to one socket from the command line; see SHELL.md for
        \\how to call compatible unix sockets from a shell, and how to skip the fork
        \\where a shell allows it.
        \\
    , .{});
}

test "directory names are configuration, not paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var config: lib.Config = .{};
    try addDir(a, &config, "/run", null);
    try addDir(a, &config, "/var/run", null); // same basename: run -> run-2
    try addDirOption(a, &config, "db=/tmp"); // explicit name
    try addDirOption(a, &config, "/tmp/db=prod"); // '=' with separators is a path

    try std.testing.expectEqualStrings("run", config.dirs.items[0].name);
    try std.testing.expectEqualStrings("run-2", config.dirs.items[1].name);
    try std.testing.expectEqualStrings("db", config.dirs.items[2].name);
    try std.testing.expectEqualStrings("/tmp/db=prod", config.dirs.items[3].path);

    for (config.dirs.items) |dir| {
        try std.testing.expect(std.mem.indexOfAny(u8, dir.name, "/\\.") == null);
    }

    try std.testing.expectError(error.InvalidDirName, addDirOption(a, &config, "bad name=/tmp"));
    try std.testing.expectError(error.DuplicateDirName, addDirOption(a, &config, "db=/var/tmp"));
}

test {
    _ = @import("lib.zig");
}
