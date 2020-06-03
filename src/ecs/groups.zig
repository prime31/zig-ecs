const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const Entity = @import("registry.zig").Entity;

pub fn NonOwningGroup(comptime n_includes: usize, comptime n_excludes: usize) type {
    return struct {
        const Self = @This();

        registry: *Registry,
        type_ids: [n_includes]u32,
        exclude_type_ids: [n_excludes]u32,

        pub fn init(registry: *Registry, type_ids: [n_includes]u32, exclude_type_ids: [n_excludes]u32) Self {
            return Self{
                .registry = registry,
                .type_ids = type_ids,
                .exclude_type_ids = exclude_type_ids,
            };
        }
    };
}

test "group creation" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e0 = reg.create();
    reg.add(e0, @as(i32, -0));
    reg.add(e0, @as(u32, 0));

    var group = reg.group(.{}, .{i32}, .{});
    var group2 = reg.group(.{}, .{u32}, .{});
    var group23 = reg.group(.{}, .{i32}, .{});
}