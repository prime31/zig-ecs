const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const Storage = @import("registry.zig").Storage;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Entity = @import("registry.zig").Entity;

/// BasicGroups do not own any components. Internally, they keep a SparseSet that is always kept up-to-date with the matching
/// entities.
pub const BasicGroup = struct {
    registry: *Registry,
    group_data: *Registry.GroupData,

    pub fn init(registry: *Registry, group_data: *Registry.GroupData) BasicGroup {
        return .{
            .registry = registry,
            .group_data = group_data,
        };
    }

    pub fn len(self: BasicGroup) usize {
        return self.group_data.entity_set.len();
    }

    /// Direct access to the array of entities
    pub fn data(self: BasicGroup) []const Entity {
        return self.group_data.entity_set.data();
    }

    pub fn get(self: BasicGroup, comptime T: type, entity: Entity) *T {
        return self.registry.assure(T).get(entity);
    }

    pub fn getConst(self: BasicGroup, comptime T: type, entity: Entity) T {
        return self.registry.assure(T).getConst(entity);
    }

    /// iterates the matched entities backwards, so the current entity can always be removed safely
    /// and newly added entities wont affect it.
    pub fn iterator(self: BasicGroup) utils.ReverseSliceIterator(Entity) {
        return self.group_data.entity_set.reverseIterator();
    }

    pub fn sort(self: BasicGroup, comptime T: type, context: anytype, comptime lessThan: *const fn (@TypeOf(context), T, T) bool) void {
        if (T == Entity) {
            self.group_data.entity_set.sort(context, lessThan);
        } else {
            // TODO: in debug mode, validate that T is present in the group
            const SortContext = struct {
                group: BasicGroup,
                wrapped_context: @TypeOf(context),
                lessThan: *const fn (@TypeOf(context), T, T) bool,

                fn sort(this: @This(), a: Entity, b: Entity) bool {
                    const real_a = this.group.getConst(T, a);
                    const real_b = this.group.getConst(T, b);
                    return this.lessThan(this.wrapped_context, real_a, real_b);
                }
            };
            const wrapper = SortContext{ .group = self, .wrapped_context = context, .lessThan = lessThan };
            self.group_data.entity_set.sort(wrapper, SortContext.sort);
        }
    }
};

pub const OwningGroup = struct {
    registry: *Registry,
    group_data: *Registry.GroupData,
    super: *usize,

    /// iterator the provides the data from all the requested owned components in a single struct. Access to the current Entity
    /// being iterated is available via the entity() method, useful for accessing non-owned component data. The get() method can
    /// also be used to fetch non-owned component data for the currently iterated Entity.
    /// TODO: support const types in the Components struct in addition to the current ptrs
    fn Iterator(comptime Components: anytype) type {
        return struct {
            group: OwningGroup,
            index: usize,
            storage: *Storage(u1),
            component_ptrs: [@typeInfo(Components).@"struct".fields.len][*]u8,

            pub fn init(group: OwningGroup) @This() {
                const component_info = @typeInfo(Components).@"struct";

                var component_ptrs: [component_info.fields.len][*]u8 = undefined;
                inline for (component_info.fields, 0..) |field, i| {
                    const storage = group.registry.assure(@typeInfo(field.type).pointer.child);
                    component_ptrs[i] = @as([*]u8, @ptrCast(storage.instances.items.ptr));
                }

                return .{
                    .group = group,
                    .index = group.group_data.current,
                    .storage = group.firstOwnedStorage(),
                    .component_ptrs = component_ptrs,
                };
            }

            pub fn next(it: *@This()) ?Components {
                if (it.index == 0) return null;
                it.index -= 1;

                // fill and return the struct
                var comps: Components = undefined;
                inline for (@typeInfo(Components).@"struct".fields, 0..) |field, i| {
                    const typed_ptr = @as([*]@typeInfo(field.type).pointer.child, @ptrCast(@alignCast(it.component_ptrs[i])));
                    @field(comps, field.name) = &typed_ptr[it.index];
                }
                return comps;
            }

            pub fn entity(it: @This()) Entity {
                std.debug.assert(it.index >= 0 and it.index < it.group.group_data.current);
                return it.storage.set.dense.items[it.index];
            }

            pub fn get(it: @This(), comptime T: type) *T {
                return it.group.registry.get(T, it.entity());
            }

            // Reset the iterator to the initial index
            pub fn reset(it: *@This()) void {
                it.index = it.group.group_data.current;
            }
        };
    }

    pub fn init(registry: *Registry, group_data: *Registry.GroupData, super: *usize) OwningGroup {
        return .{
            .registry = registry,
            .group_data = group_data,
            .super = super,
        };
    }

    /// grabs an untyped (u1) reference to the first Storage(T) in the owned array
    fn firstOwnedStorage(self: OwningGroup) *Storage(u1) {
        const ptr = self.registry.components.get(self.group_data.owned[0]).?;
        return @as(*Storage(u1), @ptrFromInt(ptr));
    }

    /// total number of entities in the group
    pub fn len(self: OwningGroup) usize {
        return self.group_data.current;
    }

    /// direct access to the array of entities of the first owning group
    pub fn data(self: OwningGroup) []const Entity {
        return self.firstOwnedStorage().data();
    }

    pub fn contains(self: OwningGroup, entity: Entity) bool {
        var storage = self.firstOwnedStorage();
        return storage.contains(entity) and storage.set.index(entity) < self.len();
    }

    fn validate(self: OwningGroup, comptime Components: anytype) void {
        if (builtin.mode == .Debug and self.group_data.owned.len > 0) {
            std.debug.assert(@typeInfo(Components) == .@"struct");

            inline for (@typeInfo(Components).@"struct".fields) |field| {
                std.debug.assert(@typeInfo(field.type) == .pointer);
                const found = std.mem.indexOfScalar(u32, self.group_data.owned, utils.typeId(std.meta.Child(field.type)));
                std.debug.assert(found != null);
            }
        }
    }

    pub fn getOwned(self: OwningGroup, entity: Entity, comptime Components: anytype) Components {
        self.validate(Components);
        const component_info = @typeInfo(Components).@"struct";

        var component_ptrs: [component_info.fields.len][*]u8 = undefined;
        inline for (component_info.fields, 0..) |field, i| {
            const storage = self.registry.assure(std.meta.Child(field.type));
            component_ptrs[i] = @as([*]u8, @ptrCast(storage.instances.items.ptr));
        }

        // fill the struct
        const index = self.firstOwnedStorage().set.index(entity);
        var comps: Components = undefined;
        inline for (component_info.fields, 0..) |field, i| {
            const typed_ptr = @as([*]std.meta.Child(field.type), @ptrCast(@alignCast(component_ptrs[i])));
            @field(comps, field.name) = &typed_ptr[index];
        }

        return comps;
    }

    pub fn each(self: OwningGroup, comptime func: anytype) void {
        const Components = switch (@typeInfo(@TypeOf(func))) {
            .@"fn" => |func_info| func_info.params[0].type.?,
            else => std.debug.assert("invalid func"),
        };
        self.validate(Components);

        // optionally we could just use an Iterator here and pay for some slight indirection for code sharing
        var iter = self.iterator(Components);
        while (iter.next()) |comps| {
            @call(.always_inline, func, .{comps});
        }
    }

    /// returns the component storage for the given type for direct access
    pub fn getStorage(self: OwningGroup, comptime T: type) *Storage(T) {
        return self.registry.assure(T);
    }

    pub fn get(self: OwningGroup, comptime T: type, entity: Entity) *T {
        return self.registry.assure(T).get(entity);
    }

    pub fn getConst(self: OwningGroup, comptime T: type, entity: Entity) T {
        return self.registry.assure(T).getConst(entity);
    }

    pub fn sortable(self: OwningGroup) bool {
        return self.group_data.super == self.group_data.size;
    }

    /// returns an iterator with optimized access to the owend Components. Note that Components should be a struct with
    /// fields that are pointers to the component types that you want to fetch. Only types that are owned are valid! Non-owned
    /// types should be fetched via Iterator.get.
    pub fn iterator(self: OwningGroup, comptime Components: anytype) Iterator(Components) {
        self.validate(Components);
        return Iterator(Components).init(self);
    }

    pub fn entityIterator(self: OwningGroup) utils.ReverseSliceIterator(Entity) {
        return utils.ReverseSliceIterator(Entity).init(self.firstOwnedStorage().set.dense.items[0..self.group_data.current]);
    }

    pub fn sort(self: OwningGroup, comptime T: type, context: anytype, comptime lessThan: *const fn (@TypeOf(context), T, T) bool) void {
        var first_storage = self.firstOwnedStorage();

        if (T == Entity) {
            // only sort up to self.group_data.current
            first_storage.sort(Entity, self.group_data.current, context, lessThan);
        } else {
            // TODO: in debug mode, validate that T is present in the group
            const SortContext = struct {
                group: OwningGroup,
                wrapped_context: @TypeOf(context),
                lessThan: *const fn (@TypeOf(context), T, T) bool,

                fn sort(this: @This(), a: Entity, b: Entity) bool {
                    const real_a = this.group.getConst(T, a);
                    const real_b = this.group.getConst(T, b);
                    return this.lessThan(this.wrapped_context, real_a, real_b);
                }
            };
            const wrapper = SortContext{ .group = self, .wrapped_context = context, .lessThan = lessThan };
            first_storage.sort(Entity, self.group_data.current, wrapper, SortContext.sort);
        }

        // sync up the rest of the owned components
        var next: usize = self.group_data.current;
        while (true) : (next -= 1) {
            if (next == 0) break;
            const pos = next - 1;
            const entity = first_storage.data()[pos];

            // skip the first one since its what we are using to sort with
            for (self.group_data.owned[1..]) |type_id| {
                const other_ptr = self.registry.components.get(type_id).?;
                var storage = @as(*Storage(u1), @ptrFromInt(other_ptr));
                storage.swap(storage.data()[pos], entity);
            }
        }
    }
};

test "BasicGroup creation/iteration" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ i32, u32 }, .{});
    try std.testing.expectEqual(group.len(), 0);

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    std.debug.assert(group.len() == 1);

    var iterated_entities: usize = 0;
    var iter = group.iterator();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }
    try std.testing.expectEqual(iterated_entities, 1);

    iterated_entities = 0;
    for (group.data()) |_| {
        iterated_entities += 1;
    }
    try std.testing.expectEqual(iterated_entities, 1);

    reg.remove(i32, e0);
    std.debug.assert(group.len() == 0);
}

test "BasicGroup excludes" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{i32}, .{u32});
    try std.testing.expectEqual(group.len(), 0);

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));

    std.debug.assert(group.len() == 1);

    var iterated_entities: usize = 0;
    var iter = group.iterator();
    while (iter.next()) |_| {
        iterated_entities += 1;
    }
    try std.testing.expectEqual(iterated_entities, 1);

    reg.add(e0, @as(u32, 55));
    std.debug.assert(group.len() == 0);
}

test "BasicGroup create late" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    var group = reg.group(.{}, .{ i32, u32 }, .{});
    try std.testing.expectEqual(group.len(), 1);
}

test "OwningGroup" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ i32, u32 }, .{}, .{});

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    try std.testing.expectEqual(group.len(), 1);
    try std.testing.expect(group.contains(e0));

    try std.testing.expectEqual(group.get(i32, e0).*, 44);
    try std.testing.expectEqual(group.getConst(u32, e0), 55);

    const vals = group.getOwned(e0, struct { int: *i32, uint: *u32 });
    try std.testing.expectEqual(vals.int.*, 44);
    try std.testing.expectEqual(vals.uint.*, 55);

    vals.int.* = 666;
    const vals2 = group.getOwned(e0, struct { int: *i32, uint: *u32 });
    try std.testing.expectEqual(vals2.int.*, 666);
}

test "OwningGroup add/remove" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ i32, u32 }, .{}, .{});

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    try std.testing.expectEqual(group.len(), 1);

    reg.remove(u32, e0);
    try std.testing.expectEqual(group.len(), 0);
}

test "OwningGroup iterate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));
    reg.add(e0, @as(u8, 11));

    const e1 = reg.create();
    reg.add(e1, @as(i32, 666));
    reg.add(e1, @as(u32, 999));
    reg.add(e1, @as(f32, 55.5));

    var group = reg.group(.{ i32, u32 }, .{}, .{});
    var iter = group.iterator(struct { int: *i32, uint: *u32 });
    while (iter.next()) |item| {
        if (iter.entity() == e0) {
            try std.testing.expectEqual(item.int.*, 44);
            try std.testing.expectEqual(item.uint.*, 55);
            try std.testing.expectEqual(iter.get(u8).*, 11);
        } else {
            try std.testing.expectEqual(item.int.*, 666);
            try std.testing.expectEqual(item.uint.*, 999);
            try std.testing.expectEqual(iter.get(f32).*, 55.5);
        }
    }
}

fn each(components: struct {
    int: *i32,
    uint: *u32,
}) void {
    std.testing.expectEqual(components.int.*, 44) catch unreachable;
    std.testing.expectEqual(components.uint.*, 55) catch unreachable;
}

test "OwningGroup each" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    const Thing = struct {
        fn each(_: @This(), components: struct {
            int: *i32,
            uint: *u32,
        }) void {
            std.testing.expectEqual(components.int.*, 44) catch unreachable;
            std.testing.expectEqual(components.uint.*, 55) catch unreachable;
        }
    };
    const thing = Thing{};

    const group = reg.group(.{ i32, u32 }, .{}, .{});
    // group.each(thing.each); // zig v0.10.0: error: no field named 'each' in struct 'ecs.groups.test.OwningGroup each.Thing'
    _ = thing;
    // group.each(each); // zig v0.10.0: error: expected type 'ecs.groups.each__struct_6297', found 'ecs.groups.each__struct_3365'
    _ = group;
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

    _ = reg.group(.{ Sprite, Transform }, .{ Renderable, Rotation }, .{});
    _ = reg.group(.{Sprite}, .{Renderable}, .{});
    _ = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});

    // ensure groups are ordered correctly internally
    var last_size: u8 = 0;
    for (reg.groups.items) |grp| {
        try std.testing.expect(last_size <= grp.size);
        last_size = grp.size;
    }

    try std.testing.expect(!reg.sortable(Sprite));

    // this will break the group
    // var group6 = reg.group(.{Sprite, Rotation}, .{}, .{});
}
