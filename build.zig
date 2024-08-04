const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const ecs_module = b.addModule("zig-ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .optimize = optimize,
        .target = target,
    });

    const examples = [_][2][]const u8{
        [_][]const u8{ "view_vs_group", "examples/view_vs_group.zig" },
        [_][]const u8{ "group_sort", "examples/group_sort.zig" },
        [_][]const u8{ "simple", "examples/simple.zig" },
    };

    for (examples, 0..) |example, i| {
        const name = if (i == 0) "ecs" else example[0];
        const source = example[1];

        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(source),
            .optimize = optimize,
            .target = target,
        });
        exe.root_module.addImport("ecs", ecs_module);
        exe.linkLibC();

        const docs = exe;
        const doc = b.step(b.fmt("{s}-docs", .{name}), "Generate documentation");
        doc.dependOn(&docs.step);

        const run_cmd = b.addRunArtifact(exe);
        b.installArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

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
        .root_source_file = b.path("src/tests.zig"),
        .optimize = optimize,
        .target = target,
        .name = "internal_tests",
    });
    b.installArtifact(internal_test);

    // public api tests
    const public_test = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .optimize = optimize,
        .target = target,
        .name = "public_tests",
    });
    public_test.root_module.addImport("ecs", ecs_module);
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

pub fn getModule(b: *std.Build, comptime prefix_path: []const u8) *std.Build.Module {
    return b.addModule(.{
        .root_source_file = .{.path = prefix_path ++ "src/ecs.zig"},
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .name = "ecs",
    });
}

/// prefix_path is used to add package paths. It should be the the same path used to include this build file
pub fn linkArtifact(b: *std.Build, artifact: *std.Build.Step.Compile, lib_type: LibType, comptime prefix_path: []const u8) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    switch (lib_type) {
        .static => {
            const lib = b.addStaticLibrary(.{ .name = "ecs", .root_source_file = "ecs.zig", .optimize = optimize, .target = target});
            b.installArtifact(lib);

            artifact.linkLibrary(lib);
        },
        .dynamic => {
            const lib = b.addSharedLibrary(.{ .name = "ecs", .root_source_file = "ecs.zig", .optimize = optimize, .target = target});
            b.installArtifact(lib);

            artifact.linkLibrary(lib);
        },
        else => {},
    }

    artifact.root_module.addImport("ecs", getModule(prefix_path));
}
