const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const ecs_module = b.addModule("zig-ecs", .{
        .source_file = std.build.FileSource{ .path = "src/ecs.zig" },
    });

    // use a different cache folder for macos arm builds
    b.cache_root = .{
        .handle = std.fs.cwd(),
        .path = if (builtin.os.tag == .macos and builtin.target.cpu.arch == .aarch64) "zig-arm-cache" else "zig-cache",
    };

    const examples = [_][2][]const u8{
        [_][]const u8{ "view_vs_group", "examples/view_vs_group.zig" },
        [_][]const u8{ "group_sort", "examples/group_sort.zig" },
        [_][]const u8{ "simple", "examples/simple.zig" },
    };

    for (examples, 0..) |example, i| {
        const name = if (i == 0) "ecs" else example[0];
        const source = example[1];

        var exe = b.addExecutable(.{
            .name = name,
            .root_source_file = std.build.FileSource{ .path = source },
            .optimize = optimize,
        });
        // exe.setOutputDir(std.fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "bin" }) catch unreachable);
        // exe.output_dirname_source = .{ .path = std.fs.path.join(b.allocator, &[_][]const u8{ b.cache_root.path.?, "bin" }) catch unreachable, .step = &exe.step };
        exe.addModule("ecs", ecs_module);
        exe.linkLibC();

        const docs = exe;
        // docs.emit_docs = .emit;

        const doc = b.step(b.fmt("{s}-docs", .{name}), "Generate documentation");
        doc.dependOn(&docs.step);

        const run_cmd = b.addRunArtifact(exe);
        const exe_step = b.step(name, b.fmt("run {s}.zig", .{name}));
        exe_step.dependOn(&run_cmd.step);

        // first element in the list is added as "run" so "zig build run" works
        if (i == 0) {
            const run_exe_step = b.step("run", b.fmt("run {s}.zig", .{name}));
            run_exe_step.dependOn(&run_cmd.step);
        }
    }

    // internal tests
    const internal_test = b.addTest(.{
        .root_source_file = std.build.FileSource{ .path = "src/tests.zig" },
        .optimize = optimize,
        .target = target,
        .name = "internal_tests",
    });
    b.installArtifact(internal_test);

    // public api tests
    const public_test = b.addTest(.{
        .root_source_file = std.build.FileSource{ .path = "tests/tests.zig" },
        .optimize = optimize,
        .target = target,
        .name = "public_tests",
    });
    public_test.addModule("ecs", ecs_module);
    b.installArtifact(public_test);

    const test_cmd = b.step("test", "Run the tests");
    test_cmd.dependOn(b.getInstallStep());
    test_cmd.dependOn(&b.addRunArtifact(internal_test).step);
    test_cmd.dependOn(&b.addRunArtifact(public_test).step);
}

pub const LibType = enum(i32) {
    static,
    dynamic, // requires DYLD_LIBRARY_PATH to point to the dylib path
    exe_compiled,
};

pub fn getModule(comptime prefix_path: []const u8) std.build.Module {
    return .{
        .name = "ecs",
        .path = .{ .path = prefix_path ++ "src/ecs.zig" },
    };
}

/// prefix_path is used to add package paths. It should be the the same path used to include this build file
pub fn linkArtifact(b: *Builder, artifact: *std.build.LibExeObjStep, _: std.build.Target, lib_type: LibType, comptime prefix_path: []const u8) void {
    const optimize = b.standardOptimizeOption(.{});
    switch (lib_type) {
        .static => {
            const lib = b.addStaticLibrary(.{ .name = "ecs", .root_source_file = "ecs.zig", .optimize = optimize });
            lib.install();

            artifact.linkLibrary(lib);
        },
        .dynamic => {
            const lib = b.addSharedLibrary(.{ .name = "ecs", .root_source_file = "ecs.zig", .optimize = optimize });
            lib.install();

            artifact.linkLibrary(lib);
        },
        else => {},
    }

    artifact.addModule(getModule(prefix_path));
}
