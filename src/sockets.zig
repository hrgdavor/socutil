//! Discovery of unix-domain sockets in configured directories.
//!
//! A socket is recognised differently per platform:
//!  * on POSIX the directory entry (or a stat of it) reports
//!    `File.Kind.unix_domain_socket` authoritatively;
//!  * on Windows an AF_UNIX socket is a reparse point, so a directory entry
//!    shows up as a symlink and stat returns `IO_REPARSE_TAG_NOT_HANDLED`.
//!    There is no portable way to tell it from an ordinary symlink without
//!    connecting, so on Windows the name convention (`.sock` / `.socket`) is
//!    used and documented in the README.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// A configured directory, with the name the API uses for sockets found in it.
pub const Dir = struct {
    /// The configured name. It has no path separator, so it can never be read
    /// as a path, and it is unique among the configured directories.
    name: []const u8,
    /// The directory, exactly as given on the command line.
    path: []const u8,
};

pub const Entry = struct {
    /// The API name: `<dir-name>.<file-name>`. This is the only selector a
    /// client may send, and it is resolved against a fresh scan of the
    /// configured directories — never joined into a filesystem path.
    name: []const u8,
    /// The configured directory's name.
    dir_name: []const u8,
    /// The configured directory, exactly as given (borrowed from `Dir`).
    dir: []const u8,
    /// The entry name within that directory, for display.
    file_name: []const u8,
    /// `dir` joined with `file_name`. The server connects to this; it is listed
    /// for the UI but never accepted from a request.
    path: []const u8,
};

pub const Scan = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Scan) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.file_name);
            self.allocator.free(entry.path);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn find(self: *const Scan, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// The name a socket is selected by. A `.` cannot occur in a directory name
/// (configured names are letters, digits, `-` and `_`), so this is unambiguous
/// and needs no parsing back from the client.
pub fn makeName(allocator: std.mem.Allocator, dir_name: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ dir_name, file_name });
}

/// Scan `dirs` for unix-domain sockets, sorted by path.
///
/// Directories that cannot be opened are reported through `std.log.warn` and
/// skipped: one bad default directory must not hide the sockets in the rest.
pub fn scan(
    allocator: std.mem.Allocator,
    io: Io,
    dirs: []const Dir,
) std.mem.Allocator.Error!Scan {
    var result: Scan = .{ .allocator = allocator };
    errdefer result.deinit();

    for (dirs) |dir| {
        var opened = openDir(io, dir.path) catch |err| {
            std.log.warn("socutil: cannot scan {s}: {s}", .{ dir.path, @errorName(err) });
            continue;
        };
        defer opened.close(io);

        var it = opened.iterate();
        while (it.next(io) catch |err| {
            std.log.warn("socutil: cannot read {s}: {s}", .{ dir.path, @errorName(err) });
            break;
        }) |dirent| {
            if (!isSocketEntry(io, opened, dirent)) continue;

            const file_name = try allocator.dupe(u8, dirent.name);
            errdefer allocator.free(file_name);
            const name = try makeName(allocator, dir.name, dirent.name);
            errdefer allocator.free(name);
            const path = try Io.Dir.path.join(allocator, &.{ dir.path, dirent.name });
            errdefer allocator.free(path);

            try result.entries.append(allocator, .{
                .name = name,
                .dir_name = dir.name,
                .dir = dir.path,
                .file_name = file_name,
                .path = path,
            });
        }
    }

    std.mem.sort(Entry, result.entries.items, {}, lessThanPath);
    return result;
}

fn lessThanPath(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn openDir(io: Io, path: []const u8) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) {
        return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn isSocketEntry(io: Io, dir: Io.Dir, dirent: Io.Dir.Entry) bool {
    switch (dirent.kind) {
        .unix_domain_socket => return true,
        .unknown => return statSaysSocket(io, dir, dirent.name),
        .sym_link => switch (builtin.os.tag) {
            // Windows AF_UNIX sockets are reparse points; stat cannot follow
            // them, so fall back to the documented naming convention.
            .windows => return hasSocketSuffix(dirent.name),
            else => return statSaysSocket(io, dir, dirent.name),
        },
        else => return false,
    }
}

fn statSaysSocket(io: Io, dir: Io.Dir, name: []const u8) bool {
    const stat = dir.statFile(io, name, .{}) catch return false;
    return stat.kind == .unix_domain_socket;
}

pub fn hasSocketSuffix(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".sock") or
        std.ascii.endsWithIgnoreCase(name, ".socket") or
        std.ascii.eqlIgnoreCase(name, "socket");
}

test "socket suffix convention" {
    try std.testing.expect(hasSocketSuffix("app.sock"));
    try std.testing.expect(hasSocketSuffix("APP.SOCK"));
    try std.testing.expect(hasSocketSuffix("x.socket"));
    // A socket with no suffix at all. fs-meta publishes its endpoint as
    // `<root>/.fs-meta/socket`, and on Windows an AF_UNIX endpoint is a reparse
    // point that `stat` cannot follow, so the name is all the scanner has.
    try std.testing.expect(hasSocketSuffix("socket"));
    try std.testing.expect(hasSocketSuffix("SOCKET"));
    try std.testing.expect(!hasSocketSuffix("app.socketx"));
    try std.testing.expect(!hasSocketSuffix("app"));
    // The bare name is exact, not a prefix or a substring: these must not pass.
    try std.testing.expect(!hasSocketSuffix("socketx"));
    try std.testing.expect(!hasSocketSuffix("mysocket"));
}

test "socket names are names, not paths" {
    const name = try makeName(std.testing.allocator, "run", "app.sock");
    defer std.testing.allocator.free(name);

    try std.testing.expectEqualStrings("run.app.sock", name);
    try std.testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, name, '\\') == null);
}
