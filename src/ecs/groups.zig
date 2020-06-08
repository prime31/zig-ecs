const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Entity = @import("registry.zig").Entity;

/// BasicGroups do not own any components
pub const BasicGroup = struct {
    const Self = @This();

    registry: *Registry,
    group_data: *Registry.GroupData,

    pub const Iterator = struct {
        group: *Self,
        index: usize = 0,
        entities: *const []Entity,

        pub fn init(group: *Self) Iterator {
            return .{
                .group = group,
                .entities = group.group_data.entity_set.data(),
            };
        }

        pub fn next(it: *Iterator) ?Entity {
            if (it.index >= it.entities.len) return null;

            it.index += 1;
            return it.entities.*[it.index - 1];
        }

        // Reset the iterator to the initial index
        pub fn reset(it: *Iterator) void {
            it.index = 0;
        }
    };

    pub fn init(registry: *Registry, group_data: *Registry.GroupData) Self {
        return Self{
            .registry = registry,
            .group_data = group_data,
        };
    }

    pub fn len(self: Self) usize {
        return self.group_data.entity_set.len();
    }

    /// Direct access to the array of entities
    pub fn data(self: Self) *const []Entity {
        return self.group_data.entity_set.data();
    }

    pub fn get(self: *Self, comptime T: type, entity: Entity) *T {
        return self.registry.assure(T).get(entity);
    }

    pub fn getConst(self: *Self, comptime T: type, entity: Entity) T {
        return self.registry.assure(T).getConst(entity);
    }

    pub fn iterator(self: *Self) Iterator {
        return Iterator.init(self);
    }
};

pub const OwningGroup = struct {
    registry: *Registry,
    group_data: *Registry.GroupData,
    super: *usize,

    pub fn init(registry: *Registry, group_data: *Registry.GroupData, super: *usize) OwningGroup {
        return .{
            .registry = registry,
            .group_data = group_data,
            .super = super,
        };
    }

    pub fn len(self: OwningGroup) usize {
        return self.group_data.current;
    }

    pub fn sortable(self: OwningGroup, comptime T: type) bool {
        return self.group_data.super == self.group_data.size;
    }
};

test "BasicGroup creation" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ i32, u32 }, .{});
    std.testing.expectEqual(group.len(), 0);

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    std.debug.assert(group.len() == 1);

    var iterated_entities: usize = 0;
    var iter = group.iterator();
    while (iter.next()) |entity| {
        iterated_entities += 1;
    }
    std.testing.expectEqual(iterated_entities, 1);

    reg.remove(i32, e0);
    std.debug.assert(group.len() == 0);
}

test "BasicGroup excludes" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{i32}, .{u32});
    std.testing.expectEqual(group.len(), 0);

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));

    std.debug.assert(group.len() == 1);

    var iterated_entities: usize = 0;
    var iter = group.iterator();
    while (iter.next()) |entity| {
        iterated_entities += 1;
    }
    std.testing.expectEqual(iterated_entities, 1);

    reg.add(e0, @as(u32, 55));
    std.debug.assert(group.len() == 0);
}

test "BasicGroup create late" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    var group = reg.group(.{}, .{ i32, u32 }, .{});
    std.testing.expectEqual(group.len(), 1);
}

test "OwningGroup" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ i32, u32 }, .{}, .{});

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    std.testing.expectEqual(group.len(), 1);
}

test "OwningGroup add/remove" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ i32, u32 }, .{}, .{});

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    std.testing.expectEqual(group.len(), 1);

    reg.remove(i32, e0);
    std.testing.expectEqual(group.len(), 0);
}

test "multiple OwningGroups" {
    const Sprite = struct { x: f32 };
    const Transform = struct { x: f32 };
    const Renderable = struct { x: f32 };
    const Rotation = struct { x: f32 };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    // var group1 = reg.group(.{u64, u32}, .{}, .{});
    // var group2 = reg.group(.{u64, u32, u8}, .{}, .{});

    var group5 = reg.group(.{ Sprite, Transform }, .{ Renderable, Rotation }, .{});
    var group3 = reg.group(.{Sprite}, .{Renderable}, .{});
    var group4 = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});

    var last_size: u8 = 0;
    for (reg.groups.items) |grp| {
        std.testing.expect(last_size <= grp.size);
        last_size = grp.size;
        std.debug.warn("grp: {}\n", .{grp.size});
    }

    std.testing.expect(!reg.sortable(Sprite));

    // this will break the group
    // var group6 = reg.group(.{Sprite, Rotation}, .{}, .{});
}
