const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();

    // use a different cache folder for macos arm builds
    b.cache_root = if (builtin.os.tag == .macos and builtin.arch == builtin.Arch.aarch64) "zig-arm-cache" else "zig-cache";

    const examples = [_][2][]const u8{
        [_][]const u8{ "view_vs_group", "examples/view_vs_group.zig" },
        [_][]const u8{ "group_sort", "examples/group_sort.zig" },
        [_][]const u8{ "simple", "examples/simple.zig" },
    };

    for (examples) |example, i| {
        const name = if (i == 0) "ecs" else example[0];
        const source = example[1];

        var exe = b.addExecutable(name, source);
        exe.setBuildMode(b.standardReleaseOptions());
        exe.setOutputDir(std.fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "bin" }) catch unreachable);
        exe.addPackagePath("ecs", "src/ecs.zig");
        exe.linkSystemLibrary("c");

        const run_cmd = exe.run();
        const exe_step = b.step(name, b.fmt("run {s}.zig", .{name}));
        exe_step.dependOn(&run_cmd.step);

        // first element in the list is added as "run" so "zig build run" works
        if (i == 0) {
            const run_exe_step = b.step("run", b.fmt("run {s}.zig", .{name}));
            run_exe_step.dependOn(&run_cmd.step);
        }
    }

    // internal tests
    const internal_test_step = b.addTest("src/tests.zig");
    internal_test_step.setBuildMode(build_mode);

    // public api tests
    const test_step = b.addTest("tests/tests.zig");
    test_step.addPackagePath("ecs", "src/ecs.zig");
    test_step.setBuildMode(build_mode);

    const test_cmd = b.step("test", "Run the tests");
    test_cmd.dependOn(&internal_test_step.step);
    test_cmd.dependOn(&test_step.step);
}

pub const LibType = enum(i32) {
    static,
    dynamic, // requires DYLD_LIBRARY_PATH to point to the dylib path
    exe_compiled,
};

pub fn getPackage(comptime prefix_path: []const u8) std.build.Pkg {
    return .{
        .name = "ecs",
        .path = prefix_path ++ "src/ecs.zig",
    };
}

/// prefix_path is used to add package paths. It should be the the same path used to include this build file
pub fn linkArtifact(b: *Builder, artifact: *std.build.LibExeObjStep, _: std.build.Target, lib_type: LibType, comptime prefix_path: []const u8) void {
    const build_mode = b.standardReleaseOptions();
    switch (lib_type) {
        .static => {
            const lib = b.addStaticLibrary("ecs", "ecs.zig");
            lib.setBuildMode(build_mode);
            lib.install();

            artifact.linkLibrary(lib);
        },
        .dynamic => {
            const lib = b.addSharedLibrary("ecs", "ecs.zig", .unversioned);
            lib.setBuildMode(build_mode);
            lib.install();

            artifact.linkLibrary(lib);
        },
        else => {},
    }

    artifact.addPackage(getPackage(prefix_path));
}
