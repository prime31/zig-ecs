const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Entity = @import("registry.zig").Entity;

/// BasicGroups do not own any components
pub fn BasicGroup(comptime n_includes: usize, comptime n_excludes: usize) type {
    return struct {
        const Self = @This();

        entity_set: *SparseSet(Entity),
        registry: *Registry,
        type_ids: [n_includes]u32,
        exclude_type_ids: [n_excludes]u32,

        pub const Iterator = struct {
            group: *Self,
            index: usize = 0,
            entities: *const []Entity,

            pub fn init(group: *Self) Iterator {
                return .{
                    .group = group,
                    .entities = group.entity_set.data(),
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

        pub fn init(entity_set: *SparseSet(Entity), registry: *Registry, type_ids: [n_includes]u32, exclude_type_ids: [n_excludes]u32) Self {
            return Self{
                .entity_set = entity_set,
                .registry = registry,
                .type_ids = type_ids,
                .exclude_type_ids = exclude_type_ids,
            };
        }

        pub fn len(self: Self) usize {
            return self.entity_set.len();
        }

        /// Direct access to the array of entities
        pub fn data(self: Self) *const []Entity {
            return self.entity_set.data();
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
}

pub fn OwningGroup(comptime n_owned: usize, comptime n_includes: usize, comptime n_excludes: usize) type {
    return struct {
        const Self = @This();

        current: *usize,
        registry: *Registry,
        owned_type_ids: [n_owned]u32,
        include_type_ids: [n_includes]u32,
        exclude_type_ids: [n_excludes]u32,

        pub fn init(current: *usize, registry: *Registry, owned_type_ids: [n_owned]u32, include_type_ids: [n_includes]u32, exclude_type_ids: [n_excludes]u32) Self {
            return Self{
                .current = current,
                .registry = registry,
                .owned_type_ids = owned_type_ids,
                .include_type_ids = include_type_ids,
                .exclude_type_ids = exclude_type_ids,
            };
        }

        pub fn len(self: Self) usize {
            return self.current.*;
        }
    };
}

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

    var group = reg.group(.{}, .{ i32 }, .{ u32 });
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

    var group = reg.group(.{i32, u32}, .{}, .{});

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    std.testing.expectEqual(group.len(), 1);
}

test "OwningGroup add/remove" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{i32, u32}, .{}, .{});

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    std.testing.expectEqual(group.len(), 1);

    reg.remove(i32, e0);
    std.testing.expectEqual(group.len(), 0);
}