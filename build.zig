const std = @import("std");
const builtin = @import("builtin");

// socutil is developed and verified against exactly this compiler. 0.17 moved the whole I/O surface
// (`std.Io`, `std.process.Init`), so a different minor version does not build this code — and one line that
// says so is worth more than the first thousand mismatched symbols. The same check is in check-zig.mjs, so
// the message is available before a build starts.
const required_zig = "0.17";
const toolchain_hint = "D:\\wrk\\zig\\17\\zig.exe";
comptime {
    const actual = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        builtin.zig_version.major,
        builtin.zig_version.minor,
        builtin.zig_version.patch,
    });
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) {
        @compileError("socutil requires Zig " ++ required_zig ++ " (" ++ toolchain_hint ++ "), got " ++ actual);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library is the "web part": the HTTP server and the socket discovery, importable by other
    // packages (for example the fs-meta engine, which can serve an optional HTTP endpoint alongside
    // its own unix socket). It is what makes socutil a dependency. `addModule` registers the module
    // under its name so dependents can resolve it via `dep.module("socutil")`.
    const lib_module = b.addModule("socutil", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "socutil",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // The HTTP server + browser UI. A thin client of the library: it parses arguments into a Config
    // and hands off to lib.run.
    const exe = b.addExecutable(.{
        .name = "socutil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // The shell half: a socat alternative that talks to one unix-domain socket from the command line.
    const cli = b.addExecutable(.{
        .name = "socutil-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);

    // `zig build run -- --dir /run --port 0` passes the arguments through to the built executable.
    const run_step = b.step("run", "Run socutil: zig build run -- [options] [directory...]");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_tests.step);
}
