const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const Entity = @import("registry.zig").Entity;
const ReverseSliceIterator = @import("utils.zig").ReverseSliceIterator;

/// single item view. Iterating raw() directly is the fastest way to get at the data. An iterator is also available to iterate
/// either the Entities or the Components. If T is sorted note that raw() will be in the reverse order so it should be looped
/// backwards. The iterators will return data in the sorted order though.
pub fn BasicView(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: *Storage(T),

        pub fn init(storage: *Storage(T)) Self {
            return Self{
                .storage = storage,
            };
        }

        pub fn len(self: Self) usize {
            return self.storage.len();
        }

        /// Direct access to the array of components
        pub fn raw(self: Self) []T {
            return self.storage.raw();
        }

        /// Direct access to the array of entities
        pub fn data(self: Self) []const Entity {
            return self.storage.data();
        }

        /// Returns the object associated with an entity
        pub fn get(self: Self, entity: Entity) *T {
            return self.storage.get(entity);
        }

        pub fn getConst(self: *Self, entity: Entity) T {
            return self.storage.getConst(entity);
        }

        pub fn iterator(self: Self) utils.ReverseSliceIterator(T) {
            return utils.ReverseSliceIterator(T).init(self.storage.instances.items);
        }

        pub fn mutIterator(self: Self) utils.ReverseSlicePointerIterator(T) {
            return utils.ReverseSlicePointerIterator(T).init(self.storage.instances.items);
        }

        pub fn entityIterator(self: Self) utils.ReverseSliceIterator(Entity) {
            return self.storage.set.reverseIterator();
        }
    };
}

pub fn MultiView(comptime n_includes: usize, comptime n_excludes: usize) type {
    return struct {
        const Self = @This();

        registry: *Registry,
        type_ids: [n_includes]u32,
        exclude_type_ids: [n_excludes]u32,

        pub const Iterator = struct {
            view: *Self,
            internal_it: ReverseSliceIterator(Entity),

            pub fn init(view: *Self) Iterator {
                const ptr = view.registry.components.get(view.type_ids[0]).?;
                const internal_it = @as(*Storage(u8), @ptrFromInt(ptr)).set.reverseIterator();
                return .{ .view = view, .internal_it = internal_it };
            }

            pub fn next(it: *Iterator) ?Entity {
                while (it.internal_it.next()) |entity| blk: {
                    // entity must be in all other Storages
                    for (it.view.type_ids) |tid| {
                        const ptr = it.view.registry.components.get(tid).?;
                        if (!@as(*Storage(u1), @ptrFromInt(ptr)).contains(entity)) {
                            break :blk;
                        }
                    }

                    // entity must not be in all other excluded Storages
                    for (it.view.exclude_type_ids) |tid| {
                        const ptr = it.view.registry.components.get(tid).?;
                        if (@as(*Storage(u1), @ptrFromInt(ptr)).contains(entity)) {
                            break :blk;
                        }
                    }

                    return entity;
                }
                return null;
            }

            // Reset the iterator to the initial index
            pub fn reset(it: *Iterator) void {
                // Assign new iterator instance in case entities have been
                // removed or added.
                it.internal_it = it.getInternalIteratorInstance();
            }

            fn getInternalIteratorInstance(it: *Iterator) ReverseSliceIterator(Entity) {
                const ptr = it.view.registry.components.get(it.view.type_ids[0]).?;
                return @as(*Storage(u8), @ptrFromInt(ptr)).set.reverseIterator();
            }
        };

        pub fn init(registry: *Registry, type_ids: [n_includes]u32, exclude_type_ids: [n_excludes]u32) Self {
            return Self{
                .registry = registry,
                .type_ids = type_ids,
                .exclude_type_ids = exclude_type_ids,
            };
        }

        pub fn get(self: *Self, comptime T: type, entity: Entity) *T {
            return self.registry.assure(T).get(entity);
        }

        pub fn getConst(self: *Self, comptime T: type, entity: Entity) T {
            return self.registry.assure(T).getConst(entity);
        }

        fn sort(self: *Self) void {
            // get our component counts in an array so we can sort the type_ids based on how many entities are in each
            var sub_items: [n_includes]usize = undefined;
            for (self.type_ids, 0..) |tid, i| {
                const ptr = self.registry.components.get(tid).?;
                const store = @as(*Storage(u8), @ptrFromInt(ptr));
                sub_items[i] = store.len();
            }

            const asc_usize = struct {
                fn sort(_: void, a: usize, b: usize) bool {
                    return a < b;
                }
            };

            utils.sortSub(usize, u32, sub_items[0..], self.type_ids[0..], asc_usize.sort);
        }

        pub fn entityIterator(self: *Self) Iterator {
            self.sort();
            return Iterator.init(self);
        }
    };
}

test "single basic view" {
    var store = Storage(f32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 30);
    store.add(5, 50);
    store.add(7, 70);

    var view = BasicView(f32).init(&store);
    try std.testing.expectEqual(view.len(), 3);

    store.remove(7);
    try std.testing.expectEqual(view.len(), 2);

    var i: usize = 0;
    var iter = view.iterator();
    while (iter.next()) |comp| {
        if (i == 0) try std.testing.expectEqual(comp, 50);
        if (i == 1) try std.testing.expectEqual(comp, 30);
        i += 1;
    }

    i = 0;
    var entIter = view.entityIterator();
    while (entIter.next()) |ent| {
        if (i == 0) {
            try std.testing.expectEqual(ent, 5);
            try std.testing.expectEqual(view.getConst(ent), 50);
        }
        if (i == 1) {
            try std.testing.expectEqual(ent, 3);
            try std.testing.expectEqual(view.getConst(ent), 30);
        }
        i += 1;
    }
}

test "single basic view data" {
    var store = Storage(f32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 30);
    store.add(5, 50);
    store.add(7, 70);

    var view = BasicView(f32).init(&store);

    try std.testing.expectEqual(view.get(3).*, 30);

    for (view.data(), 0..) |entity, i| {
        if (i == 0)
            try std.testing.expectEqual(entity, 3);
        if (i == 1)
            try std.testing.expectEqual(entity, 5);
        if (i == 2)
            try std.testing.expectEqual(entity, 7);
    }

    for (view.raw(), 0..) |data, i| {
        if (i == 0)
            try std.testing.expectEqual(data, 30);
        if (i == 1)
            try std.testing.expectEqual(data, 50);
        if (i == 2)
            try std.testing.expectEqual(data, 70);
    }

    try std.testing.expectEqual(view.len(), 3);
}

test "basic multi view" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(u32, 0));
    reg.add(e2, @as(u32, 2));

    _ = reg.view(.{u32}, .{});
    var view = reg.view(.{ i32, u32 }, .{});

    var iterated_entities: usize = 0;
    var iter = view.entityIterator();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }

    try std.testing.expectEqual(iterated_entities, 2);
    iterated_entities = 0;

    reg.remove(u32, e0);

    iter.reset();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }

    try std.testing.expectEqual(iterated_entities, 1);
}

test "basic multi view with excludes" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(u32, 0));
    reg.add(e2, @as(u32, 2));

    reg.add(e2, @as(u8, 255));

    var view = reg.view(.{ i32, u32 }, .{u8});

    var iterated_entities: usize = 0;
    var iter = view.entityIterator();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }

    try std.testing.expectEqual(iterated_entities, 1);
    iterated_entities = 0;

    reg.remove(u8, e2);

    iter.reset();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }

    try std.testing.expectEqual(iterated_entities, 2);
}
