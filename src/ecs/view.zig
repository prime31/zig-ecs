const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const Entity = @import("registry.zig").Entity;


/// single item view. Iterating raw() directly is the fastest way to get at the data.
pub fn BasicView(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: *Storage(T),

        pub fn init(storage: *Storage(T)) Self {
            return Self {
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
        pub fn data(self: Self) *const []Entity {
            return self.storage.data();
        }

        /// Returns the object associated with an entity
        pub fn get(self: Self, entity: Entity) *T {
            return self.storage.get(entity);
        }
    };
}

pub fn BasicMultiView(comptime n: usize) type {
    return struct {
        const Self = @This();

        type_ids: [n]u32,
        registry: *Registry,

        pub const Iterator = struct {
            view: *Self,
            index: usize = 0,
            entities: *const []Entity,

            pub fn init(view: *Self) Iterator {
                const ptr = view.registry.components.getValue(@intCast(u8, view.type_ids[0])).?;
                return .{
                    .view = view,
                    .entities = @intToPtr(*Storage(u8), ptr).data(),
                };
            }

            pub fn next(it: *Iterator) ?Entity {
                if (it.index >= it.entities.len) return null;

                blk: while (it.index < it.entities.len) : (it.index += 1) {
                    const entity = it.entities.*[it.index];

                    // entity must be in all other Storages
                    for (it.view.type_ids) |tid| {
                        const ptr = it.view.registry.components.getValue(@intCast(u8, tid)).?;
                        if (!@intToPtr(*Storage(u8), ptr).contains(entity)) {
                            break :blk;
                        }
                    }
                    it.index += 1;
                    return entity;
                }

                return null;
            }

            // Reset the iterator to the initial index
            pub fn reset(it: *Iterator) void {
                it.index = 0;
            }
        };

        pub fn init(type_ids: [n]u32, registry: *Registry) Self {
            return Self{
                .type_ids = type_ids,
                .registry = registry,
            };
        }

        pub fn get(self: *Self, comptime T: type, entity: Entity) *T {
            const type_id = self.registry.typemap.get(T);
            const ptr = self.registry.components.getValue(type_id).?;
            const store = @intToPtr(*Storage(T), ptr);

            std.debug.assert(store.contains(entity));
            return store.get(entity);
        }

        pub fn getConst(self: *Self, comptime T: type, entity: Entity) T {
            const type_id = self.registry.typemap.get(T);
            const ptr = self.registry.components.getValue(type_id).?;
            const store = @intToPtr(*Storage(T), ptr);

            std.debug.assert(store.contains(entity));
            return store.getConst(entity);
        }

        fn sort(self: *Self) void {
            // get our component counts in an array so we can sort the type_ids based on how many entities are in each
            var sub_items: [n]usize = undefined;
            for (self.type_ids) |tid, i| {
                const ptr = self.registry.components.getValue(@intCast(u8, tid)).?;
                const store = @intToPtr(*Storage(u8), ptr);
                sub_items[i] = store.len();
            }

            utils.sortSub(usize, u32, sub_items[0..], self.type_ids[0..], std.sort.asc(usize));
        }

        pub fn iterator(self: *Self) Iterator {
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
    std.testing.expectEqual(view.len(), 3);

    store.remove(7);
    std.testing.expectEqual(view.len(), 2);
}

test "single basic view data" {
    var store = Storage(f32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 30);
    store.add(5, 50);
    store.add(7, 70);

    var view = BasicView(f32).init(&store);

    std.testing.expectEqual(view.get(3).*, 30);

    for (view.data().*) |entity, i| {
        if (i == 0)
            std.testing.expectEqual(entity, 3);
        if (i == 1)
            std.testing.expectEqual(entity, 5);
        if (i == 2)
            std.testing.expectEqual(entity, 7);
    }

    for (view.raw()) |data, i| {
        if (i == 0)
            std.testing.expectEqual(data, 30);
        if (i == 1)
            std.testing.expectEqual(data, 50);
        if (i == 2)
            std.testing.expectEqual(data, 70);
    }

    std.testing.expectEqual(view.len(), 3);
}

test "basic multi view" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e0 = reg.create();
    var e1 = reg.create();
    var e2 = reg.create();

    reg.add(e0, @as(i32, -0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(u32, 0));
    reg.add(e2, @as(u32, 2));

    var single_view = reg.view(.{u32});
    var view = reg.view(.{ i32, u32 });

    var iterated_entities: usize = 0;
    var iter = view.iterator();
    while (iter.next()) |entity| {
        iterated_entities += 1;
    }

    std.testing.expectEqual(iterated_entities, 2);
    iterated_entities = 0;

    reg.remove(u32, e0);

    iter.reset();
    while (iter.next()) |entity| {
        iterated_entities += 1;
    }

    std.testing.expectEqual(iterated_entities, 1);
}