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

pub fn MultiView(comptime _includes: anytype, comptime _excludes: anytype) type {
    @setEvalBranchQuota(1_000_000);
    if (std.mem.indexOfAny(type, &_includes, &_excludes) != null) {
        @compileError("Included and excluded types must not overlap");
    }
    const include_type_ids = include_type_ids: {
        var ids: [_includes.len]u32 = undefined;
        for (_includes, 0..) |t, i| {
            ids[i] = utils.typeId(t);
        }
        break :include_type_ids ids;
    };
    const exclude_type_ids = exclude_type_ids: {
        var ids: [_excludes.len]u32 = undefined;
        for (_excludes, 0..) |t, i| {
            ids[i] = utils.typeId(t);
        }
        break :exclude_type_ids ids;
    };
    return struct {
        const Self = @This();

        comptime n_includes: usize = _includes.len,
        comptime n_excludes: usize = _excludes.len,
        comptime includes: @TypeOf(_includes) = _includes,
        comptime excludes: @TypeOf(_excludes) = _excludes,

        registry: *Registry,
        order: [_includes.len]u32 = include_type_ids,

        pub const Iterator = struct {
            view: *Self,
            internal_it: ReverseSliceIterator(Entity),

            pub fn init(view: *Self) Iterator {
                const ptr = view.registry.components.get(view.order[0]).?;
                const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                const internal_it = storage.set.reverseIterator();
                return .{ .view = view, .internal_it = internal_it };
            }

            pub fn next(it: *Iterator) ?Entity {
                while (it.internal_it.next()) |entity| blk: {
                    // entity must be in all other Storages
                    for (it.view.order) |tid| {
                        const ptr = it.view.registry.components.get(tid).?;
                        const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                        if (!storage.contains(entity)) {
                            break :blk;
                        }
                    }

                    // entity must not be in all other excluded Storages
                    inline for (exclude_type_ids) |tid| {
                        const ptr = it.view.registry.components.get(tid).?;
                        const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                        if (storage.contains(entity)) {
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
                const ptr = it.view.registry.components.get(it.view.order[0]).?;
                const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                return storage.set.reverseIterator();
            }
        };

        pub fn init(registry: *Registry) Self {
            inline for (_includes) |include_type| {
                _ = registry.assure(include_type);
            }
            inline for (_excludes) |exclude_type| {
                _ = registry.assure(exclude_type);
            }
            return Self{
                .registry = registry,
            };
        }

        pub fn get(self: *Self, comptime T: type, entity: Entity) *T {
            return self.registry.assure(T).get(entity);
        }

        pub fn getConst(self: *Self, comptime T: type, entity: Entity) T {
            return self.registry.assure(T).getConst(entity);
        }

        pub fn contains(self: *Self, entity: Entity) bool {
            // entity must be in all other Storages
            inline for (include_type_ids) |tid| {
                const ptr = self.registry.components.get(tid).?;
                const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                if (!storage.contains(entity)) {
                    return false;
                }
            }

            // entity must not be in all other excluded Storages
            inline for (exclude_type_ids) |tid| {
                const ptr = self.registry.components.get(tid).?;
                const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                if (storage.contains(entity)) {
                    return false;
                }
            }
            return true;
        }

        fn sort(self: *Self) void {
            // get our component counts in an array so we can sort the type_ids based on how many entities are in each
            var sub_items: [_includes.len]usize = undefined;
            for (include_type_ids, 0..) |tid, i| {
                const ptr = self.registry.components.get(tid).?;
                const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                sub_items[i] = storage.len();
            }

            const asc_usize = struct {
                fn sort(_: void, a: usize, b: usize) bool {
                    return a < b;
                }
            };

            utils.sortSub(usize, u32, sub_items[0..], self.order[0..], asc_usize.sort);
        }

        pub fn entityIterator(self: *Self) Iterator {
            self.sort();
            return Iterator.init(self);
        }

        fn countOverlap(a: []const type, b: []const type) usize {
            var found = 0;
            for (a) |a_elem| {
                if (std.mem.indexOfScalar(type, b, a_elem) != null) {
                    found += 1;
                }
            }
            return found;
        }

        fn copyFiltered(to: []type, from: []const type, filter: []const type) usize {
            var count = 0;
            for (from) |t| {
                if (std.mem.indexOfScalar(type, filter, t) != null) continue;
                to[count] = t;
                count += 1;
            }
            return count;
        }

        //// merge multiviews types, returning a new multiview type.
        pub fn extendType(comptime Diff: type) type {
            const diff_n_includes = std.meta.fieldInfo(Diff, .n_includes).defaultValue().?;
            const diff_n_excludes = std.meta.fieldInfo(Diff, .n_excludes).defaultValue().?;

            const diff_includes: [diff_n_includes]type = std.meta.fieldInfo(Diff, .includes).defaultValue().?;
            const diff_excludes: [diff_n_excludes]type = std.meta.fieldInfo(Diff, .excludes).defaultValue().?;

            const self_includes: [_includes.len]type = std.meta.fieldInfo(Self, .includes).defaultValue().?;
            const self_excludes: [_excludes.len]type = std.meta.fieldInfo(Self, .excludes).defaultValue().?;

            if (std.mem.indexOfAny(type, &self_includes, &diff_includes) != null) {
                @compileError(std.fmt.comptimePrint("Overlap between current include types {any} and new include types {any} detected!", .{ self_includes, diff_includes }));
            }
            if (std.mem.indexOfAny(type, &self_excludes, &diff_excludes) != null) {
                @compileError(std.fmt.comptimePrint("Overlap between current exclude types {any} and new exclude types {any} detected!", .{ self_excludes, diff_excludes }));
            }
            if (std.mem.indexOfAny(type, &diff_includes, &diff_excludes) != null) {
                @compileError(std.fmt.comptimePrint("Overlap between new include types {any} and new exclude types {any} detected!", .{ diff_includes, diff_excludes }));
            }

            const num_include_exclude_overlap = countOverlap(&self_includes, &diff_excludes);
            const num_exclude_include_overlap = countOverlap(&self_excludes, &diff_includes);

            var new_includes: [self_includes.len + diff_includes.len - num_include_exclude_overlap]type = undefined;
            const n_copied_self_includes = copyFiltered(&new_includes, &self_includes, &diff_excludes);
            std.mem.copyForwards(type, new_includes[n_copied_self_includes..], &diff_includes);

            var new_excludes: [self_excludes.len + diff_excludes.len - num_exclude_include_overlap]type = undefined;
            const n_copied_self_excludes = copyFiltered(&new_excludes, &self_excludes, &diff_includes);
            std.mem.copyForwards(type, new_excludes[n_copied_self_excludes..], &diff_excludes);

            return MultiView(new_includes, new_excludes);
        }

        /// extend current view, returning an instance of the new view type
        pub fn extend(self: *Self, new_includes: anytype, new_excludes: anytype) extendType(MultiView(new_includes, new_excludes)) {
            const NewMultiViewType = Self.extendType(MultiView(new_includes, new_excludes));
            return NewMultiViewType.init(self.registry);
        }

        /// extend current view with a new include type, returning an instance of the new view type
        pub fn include(self: *Self, comptime Include: type) extendType(MultiView(.{Include}, .{})) {
            return self.extend(.{Include}, .{});
        }

        /// extend current view with a new exclude type, returning an instance of the new view type
        pub fn exclude(self: *Self, comptime Exclude: type) extendType(MultiView(.{}, .{Exclude})) {
            return self.extend(.{}, .{Exclude});
        }
    };
}

test "single basic view" {
    var store = Storage(f32).init(std.testing.allocator);
    defer store.deinit();

    store.add(.{ .index = 3, .version = 0 }, 30);
    store.add(.{ .index = 5, .version = 0 }, 50);
    store.add(.{ .index = 7, .version = 0 }, 70);

    var view = BasicView(f32).init(&store);
    try std.testing.expectEqual(view.len(), 3);

    store.remove(.{ .index = 7, .version = 0 });
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
            try std.testing.expectEqual(@as(Entity, .{ .index = 5, .version = 0 }), ent);
            try std.testing.expectEqual(view.getConst(ent), 50);
        }
        if (i == 1) {
            try std.testing.expectEqual(ent, @as(Entity, .{ .index = 3, .version = 0 }));
            try std.testing.expectEqual(view.getConst(ent), 30);
        }
        i += 1;
    }
}

test "single basic view data" {
    var store = Storage(f32).init(std.testing.allocator);
    defer store.deinit();

    store.add(.{ .index = 3, .version = 0 }, 30);
    store.add(.{ .index = 5, .version = 0 }, 50);
    store.add(.{ .index = 7, .version = 0 }, 70);

    var view = BasicView(f32).init(&store);

    try std.testing.expectEqual(view.get(.{ .index = 3, .version = 0 }).*, 30);

    for (view.data(), 0..) |entity, i| {
        if (i == 0)
            try std.testing.expectEqual(entity, @as(Entity, .{ .index = 3, .version = 0 }));
        if (i == 1)
            try std.testing.expectEqual(entity, @as(Entity, .{ .index = 5, .version = 0 }));
        if (i == 2)
            try std.testing.expectEqual(entity, @as(Entity, .{ .index = 7, .version = 0 }));
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

test "extend view type with non overlapping types" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view = MultiView(.{}, .{})
        .extendType(MultiView(.{f32}, .{}))
        .extendType(MultiView(.{}, .{}))
        .extendType(MultiView(.{i32}, .{}))
        .extendType(MultiView(.{}, .{}))
        .extendType(MultiView(.{}, .{u8})).init(&reg);

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

test "extend view type with overlapping types (including an excluded type)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view = MultiView(.{f32}, .{i32})
        .extendType(MultiView(.{i32}, .{u8})).init(&reg);

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

test "extend view type with overlapping types (excluding an included type)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view = MultiView(.{ f32, bool, i32 }, .{})
        .extendType(MultiView(.{}, .{ bool, u8 })).init(&reg);

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

test "extend view type with overlapping types (excluding an included type and including an excluded type at the same time)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view = MultiView(.{ f32, bool }, .{i32})
        .extendType(MultiView(.{i32}, .{ bool, u8 })).init(&reg);

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

test "extend view with overlapping types, getting an instance of the new view type" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view1 = reg.view(.{ f32, bool }, .{i32});
    var view2 = view1.extend(.{i32}, .{ bool, u8 });

    var iterated_entities: usize = 0;
    var iter = view2.entityIterator();
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

test "include type in view" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view1 = reg.view(.{f32}, .{u8});
    var view2 = view1.include(i32);

    var iterated_entities: usize = 0;
    var iter = view2.entityIterator();
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

test "exclude type from view" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view1 = reg.view(.{ f32, i32 }, .{});
    var view2 = view1.exclude(u8);

    var iterated_entities: usize = 0;
    var iter = view2.entityIterator();
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

test "check if entity belongs to view without iterating over everything" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    const e1 = reg.create();
    const e2 = reg.create();
    const e4 = reg.create();

    reg.add(e0, @as(i32, 0));
    reg.add(e1, @as(i32, -1));
    reg.add(e2, @as(i32, -2));
    reg.add(e4, @as(i32, -3));

    reg.add(e0, @as(f32, 0.0));
    reg.add(e2, @as(f32, 2.0));

    reg.add(e2, @as(u8, 255));

    var view1 = reg.view(.{ f32, i32 }, .{});
    try std.testing.expect(view1.contains(e2));
    try std.testing.expect(view1.contains(e2));
    try std.testing.expect(!view1.contains(e4));
    var view2 = view1.exclude(u8);
    try std.testing.expect(!view2.contains(e2));

    var iterated_entities: usize = 0;
    var iter = view2.entityIterator();
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
