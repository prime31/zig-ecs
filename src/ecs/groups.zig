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

    // TODO: do we even need an iterator for a group?
    pub const Iterator = struct {
        index: usize = 0,
        entities: []const Entity, // TODO: should this be a pointer to the slice?

        pub fn init(entities: []const Entity) Iterator {
            return .{ .entities = entities };
        }

        pub fn next(it: *Iterator) ?Entity {
            if (it.index >= it.entities.len) return null;

            it.index += 1;
            return it.entities[it.index - 1];
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
    pub fn data(self: Self) []const Entity {
        return self.group_data.entity_set.data();
    }

    pub fn get(self: *Self, comptime T: type, entity: Entity) *T {
        return self.registry.assure(T).get(entity);
    }

    pub fn getConst(self: *Self, comptime T: type, entity: Entity) T {
        return self.registry.assure(T).getConst(entity);
    }

    pub fn iterator(self: *Self) Iterator {
        return Iterator.init(self.group_data.entity_set.data());
    }
};

pub const OwningGroup = struct {
    registry: *Registry,
    group_data: *Registry.GroupData,
    super: *usize,

    fn Iterator(comptime Components: var) type {
        return struct {
            index: usize = 0,
            group: OwningGroup,
            storage: *Storage(u1),
            component_ptrs: [@typeInfo(Components).Struct.fields.len][*]u8,

            pub fn init(group: OwningGroup) @This() {
                const component_info = @typeInfo(Components).Struct;

                var component_ptrs: [component_info.fields.len][*]u8 = undefined;
                inline for (component_info.fields) |field, i| {
                    const storage = group.registry.assure(field.field_type.Child);
                    component_ptrs[i] = @ptrCast([*]u8, storage.instances.items.ptr);
                }

                return .{
                    .group = group,
                    .storage = group.firstOwnedStorage(),
                    .component_ptrs = component_ptrs,
                };
            }

            pub fn next(it: *@This()) ?Components {
                if (it.index >= it.group.group_data.current) return null;

                const ent = it.storage.set.dense.items[it.index];
                const entity_index = it.storage.set.index(ent);
                it.index += 1;

                // fill and return the struct
                var comps: Components = undefined;
                inline for (@typeInfo(Components).Struct.fields) |field, i| {
                    const typed_ptr = @ptrCast([*]field.field_type.Child, @alignCast(@alignOf(field.field_type.Child), it.component_ptrs[i]));
                    @field(comps, field.name) = &typed_ptr[entity_index];
                }
                return comps;
            }

            pub fn entity(it: @This()) Entity {
                std.debug.assert(it.index > 0 and it.index <= it.group.group_data.current);
                return it.storage.set.dense.items[it.index - 1];
            }

            // Reset the iterator to the initial index
            pub fn reset(it: *@This()) void {
                it.index = 0;
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
        const ptr = self.registry.components.getValue(self.group_data.owned[0]).?;
        return @intToPtr(*Storage(u1), ptr);
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

    fn validate(self: OwningGroup, comptime Components: var) void {
        std.debug.assert(@typeInfo(Components) == .Struct);

        inline for (@typeInfo(Components).Struct.fields) |field| {
            std.debug.assert(@typeInfo(field.field_type) == .Pointer);
            const found = std.mem.indexOfScalar(u32, self.group_data.owned, utils.typeId(std.meta.Child(field.field_type)));
            std.debug.assert(found != null);
        }
    }

    pub fn getOwned(self: OwningGroup, entity: Entity, comptime Components: var) Components {
        self.validate(Components);
        const component_info = @typeInfo(Components).Struct;

        var component_ptrs: [component_info.fields.len][*]u8 = undefined;
        inline for (component_info.fields) |field, i| {
            const storage = self.registry.assure(field.field_type.Child);
            component_ptrs[i] = @ptrCast([*]u8, storage.instances.items.ptr);
        }

        // fill the struct
        const index = self.firstOwnedStorage().set.index(entity);
        var comps: Components = undefined;
        inline for (component_info.fields) |field, i| {
            const typed_ptr = @ptrCast([*]field.field_type.Child, @alignCast(@alignOf(field.field_type.Child), component_ptrs[i]));
            @field(comps, field.name) = &typed_ptr[index];
        }

        return comps;
    }

    pub fn each(self: OwningGroup, comptime func: var) void {
        const Components = switch (@typeInfo(@TypeOf(func))) {
            .BoundFn => |func_info| func_info.args[1].arg_type.?,
            .Fn => |func_info| func_info.args[0].arg_type.?,
            else => std.debug.assert("invalid func"),
        };
        self.validate(Components);

        // optionally we could just use an Iterator here and pay for some slight indirection for code sharing
        // var iter = self.iterator(Components);
        // while (iter.next()) |comps| {
        //     @call(.{ .modifier = .always_inline }, func, .{comps});
        // }

        const component_info = @typeInfo(Components).Struct;

        // get the data pointers for the requested component types
        var component_ptrs: [component_info.fields.len][*]u8 = undefined;
        inline for (component_info.fields) |field, i| {
            const storage = self.registry.assure(field.field_type.Child);
            component_ptrs[i] = @ptrCast([*]u8, storage.instances.items.ptr);
        }

        var storage = self.firstOwnedStorage();
        var index: usize = 0;
        while (index < self.group_data.current) : (index += 1) {
            const ent = storage.set.dense.items[index];
            const entity_index = storage.set.index(ent);

            var comps: Components = undefined;
            inline for (component_info.fields) |field, i| {
                const typed_ptr = @ptrCast([*]field.field_type.Child, @alignCast(@alignOf(field.field_type.Child), component_ptrs[i]));
                @field(comps, field.name) = &typed_ptr[entity_index];
            }

            @call(.{ .modifier = .always_inline }, func, .{comps});
        }
    }

    /// returns the component storage for the given type for direct access
    pub fn getStorage(self: *OwningGroup, comptime T: type) *Storage(T) {
        return self.registry.assure(T);
    }

    pub fn get(self: *OwningGroup, comptime T: type, entity: Entity) *T {
        return self.registry.assure(T).get(entity);
    }

    pub fn getConst(self: *OwningGroup, comptime T: type, entity: Entity) T {
        return self.registry.assure(T).getConst(entity);
    }

    pub fn sortable(self: OwningGroup) bool {
        return self.group_data.super == self.group_data.size;
    }

    /// returns an iterator with optimized access to the Components. Note that Components should be a struct with
    /// fields that are pointers to the component types that you want to fetch. Only types that are owned are valid!
    pub fn iterator(self: OwningGroup, comptime Components: var) Iterator(Components) {
        self.validate(Components);
        return Iterator(Components).init(self);
    }
};

test "BasicGroup creation/iteration" {
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

    iterated_entities = 0;
    for (group.data()) |entity| {
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
    std.testing.expect(group.contains(e0));

    std.testing.expectEqual(group.get(i32, e0).*, 44);
    std.testing.expectEqual(group.getConst(u32, e0), 55);

    var vals = group.getOwned(e0, struct { int: *i32, uint: *u32 });
    std.testing.expectEqual(vals.int.*, 44);
    std.testing.expectEqual(vals.uint.*, 55);

    vals.int.* = 666;
    var vals2 = group.getOwned(e0, struct { int: *i32, uint: *u32 });
    std.testing.expectEqual(vals2.int.*, 666);
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

test "OwningGroup iterate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    var e1 = reg.create();
    reg.add(e1, @as(i32, 666));
    reg.add(e1, @as(u32, 999));

    var group = reg.group(.{ i32, u32 }, .{}, .{});
    var iter = group.iterator(struct { int: *i32, uint: *u32 });
    while (iter.next()) |item| {
        if (iter.entity() == 0) {
            std.testing.expectEqual(item.int.*, 44);
            std.testing.expectEqual(item.uint.*, 55);
        } else {
            std.testing.expectEqual(item.int.*, 666);
            std.testing.expectEqual(item.uint.*, 999);
        }
    }
}

fn each(components: struct {
    int: *i32,
    uint: *u32,
}) void {
    std.testing.expectEqual(components.int.*, 44);
    std.testing.expectEqual(components.uint.*, 55);
}

test "OwningGroup each" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e0 = reg.create();
    reg.add(e0, @as(i32, 44));
    reg.add(e0, @as(u32, 55));

    const Thing = struct {
        fn each(self: @This(), components: struct {
            int: *i32,
            uint: *u32,
        }) void {
            std.testing.expectEqual(components.int.*, 44);
            std.testing.expectEqual(components.uint.*, 55);
        }
    };
    var thing = Thing{};

    var group = reg.group(.{ i32, u32 }, .{}, .{});
    group.each(thing.each);
    group.each(each);
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
