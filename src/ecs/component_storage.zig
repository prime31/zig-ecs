const std = @import("std");
const utils = @import("utils.zig");

const Registry = @import("registry.zig").Registry;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Signal = @import("../signals/signal.zig").Signal;
const Sink = @import("../signals/sink.zig").Sink;

/// Stores an ArrayList of components along with a SparseSet of entities
pub fn ComponentStorage(comptime Component: type, comptime Entity: type) type {
    std.debug.assert(!utils.isComptime(Component));

    // empty (zero-sized) structs will not have an array created
    const is_empty_struct = @sizeOf(Component) == 0;

    // HACK: due to this being stored as untyped ptrs, when deinit is called we are casted to a Component of some random
    // non-zero sized type. That will make is_empty_struct false in deinit always so we can't use it. Instead, we stick
    // a small dummy struct in the instances ArrayList so it can safely be deallocated.
    // Perhaps we should just allocate instances with a dummy allocator or the tmp allocator?
    const ComponentOrDummy = if (is_empty_struct) struct { dummy: u1 } else Component;

    return struct {
        const Self = @This();

        set: *SparseSet(Entity),
        instances: std.ArrayListUnmanaged(ComponentOrDummy),
        allocator: std.mem.Allocator,
        /// doesnt really belong here...used to denote group ownership
        super: usize = 0,
        safeDeinit: *const fn (*Self) void,
        safeSwap: *const fn (*Self, Entity, Entity, bool) void,
        safeRemoveIfContains: *const fn (*Self, Entity) void,

        registry: *Registry = undefined,
        construction: Signal(.{ *Registry, Entity }),
        update: Signal(.{ *Registry, Entity }),
        destruction: Signal(.{ *Registry, Entity }),

        pub fn create(allocator: std.mem.Allocator) *Self {
            const store = allocator.create(Self) catch unreachable;
            store.* = Self.init(allocator);
            return store;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            var store = Self{
                .set = SparseSet(Entity).create(allocator),
                .instances = undefined,
                .safeDeinit = struct {
                    fn deinit(self: *Self) void {
                        if (!is_empty_struct) {
                            self.instances.deinit(self.allocator);
                        }
                    }
                }.deinit,
                .safeSwap = struct {
                    fn swap(self: *Self, lhs: Entity, rhs: Entity, instances_only: bool) void {
                        if (!is_empty_struct) {
                            std.mem.swap(Component, &self.instances.items[self.set.index(lhs)], &self.instances.items[self.set.index(rhs)]);
                        }
                        if (!instances_only) self.set.swap(lhs, rhs);
                    }
                }.swap,
                .safeRemoveIfContains = struct {
                    fn removeIfContains(self: *Self, entity: Entity) void {
                        if (self.contains(entity)) {
                            self.remove(entity);
                        }
                    }
                }.removeIfContains,
                .allocator = allocator,
                .construction = Signal(.{ *Registry, Entity }).init(allocator),
                .update = Signal(.{ *Registry, Entity }).init(allocator),
                .destruction = Signal(.{ *Registry, Entity }).init(allocator),
            };

            if (!is_empty_struct) {
                store.instances = std.ArrayListUnmanaged(ComponentOrDummy){};
            }

            return store;
        }

        pub fn deinit(self: *Self) void {
            // great care must be taken here. Due to how Registry keeps this struct as pointers anything touching a type
            // will be wrong since it has to cast to a random struct when deiniting. Because of all that, is_empty_struct
            // will allways be false here so we have to deinit the instances no matter what.
            self.safeDeinit(self);
            self.set.destroy();
            self.construction.deinit();
            self.update.deinit();
            self.destruction.deinit();
        }

        pub fn onConstruct(self: *Self) Sink(.{ *Registry, Entity }) {
            return self.construction.sink();
        }

        pub fn onUpdate(self: *Self) Sink(.{ *Registry, Entity }) {
            return self.update.sink();
        }

        pub fn onDestruct(self: *Self) Sink(.{ *Registry, Entity }) {
            return self.destruction.sink();
        }

        /// Increases the capacity of a component storage
        pub fn reserve(self: *Self, cap: usize) void {
            self.set.reserve(cap);
            if (!is_empty_struct) {
                self.instances.items.reserve(cap);
            }
        }

        /// Assigns an entity to a storage and assigns its object
        pub fn add(self: *Self, entity: Entity, value: Component) void {
            if (!is_empty_struct) {
                _ = self.instances.append(self.allocator, value) catch unreachable;
            }
            self.set.add(entity);
            self.construction.publish(.{ self.registry, entity });
        }

        /// Removes an entity from a storage
        pub fn remove(self: *Self, entity: Entity) void {
            self.destruction.publish(.{ self.registry, entity });
            if (!is_empty_struct) {
                _ = self.instances.swapRemove(self.set.index(entity));
            }
            self.set.remove(entity);
        }

        /// Checks if a view contains an entity
        pub fn contains(self: Self, entity: Entity) bool {
            return self.set.contains(entity);
        }

        pub fn removeIfContains(self: *Self, entity: Entity) void {
            if (Component == u1) {
                self.safeRemoveIfContains(self, entity);
            } else if (self.contains(entity)) {
                self.remove(entity);
            }
        }

        pub fn len(self: Self) usize {
            return self.set.len();
        }

        /// Direct access to the array of objects
        pub fn raw(self: Self) []Component {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            return self.instances.items;
        }

        /// Replaces the given component for an entity
        pub fn replace(self: *Self, entity: Entity, value: Component) void {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            self.get(entity).* = value;
            self.update.publish(.{ self.registry, entity });
        }

        /// Returns the object associated with an entity
        pub fn get(self: *Self, entity: Entity) *Component {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            std.debug.assert(self.contains(entity));
            return &self.instances.items[self.set.index(entity)];
        }

        pub fn getConst(self: *Self, entity: Entity) Component {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            return self.instances.items[self.set.index(entity)];
        }

        /// Returns a pointer to the object associated with an entity, if any.
        pub fn tryGet(self: *Self, entity: Entity) ?*Component {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            return if (self.set.contains(entity)) &self.instances.items[self.set.index(entity)] else null;
        }

        pub fn tryGetConst(self: *Self, entity: Entity) ?Component {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            return if (self.set.contains(entity)) self.instances.items[self.set.index(entity)] else null;
        }

        pub fn sortEmpty(self: Self, comptime T: type, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
            if (!is_empty_struct) {
                @compileError("This method is only available to zero-sized components");
            }
            std.debug.assert(T == Entity);
            self.set.sort(context, lessThan);
        }

        /// Sort Entities or Components according to the given comparison function. Valid types for T are Entity or Component.
        pub fn sort(self: *Self, comptime T: type, length: usize, context: anytype, comptime lessThan: *const fn (@TypeOf(context), T, T) bool) void {
            if (is_empty_struct) {
                @compileError("This method is not available to zero-sized components");
            }
            std.debug.assert(T == Entity or T == Component);

            // we have to perform a swap after the sort for all moved entities so we make a helper struct for that. In the
            // case of a Component sort we also wrap that into the struct so we can get the Component data to pass to the
            // lessThan method passed in.
            if (T == Entity) {
                const SortContext = struct {
                    storage: *Self,

                    pub fn swap(this: @This(), a: Entity, b: Entity) void {
                        this.storage.safeSwap(this.storage, a, b, true);
                    }
                };
                const swap_context = SortContext{ .storage = self };
                self.set.arrange(length, context, lessThan, swap_context);
            } else {
                const SortContext = struct {
                    storage: *Self,
                    wrapped_context: @TypeOf(context),
                    lessThan: *const fn (@TypeOf(context), T, T) bool,

                    fn sort(this: @This(), a: Entity, b: Entity) bool {
                        const real_a = this.storage.getConst(a);
                        const real_b = this.storage.getConst(b);
                        return this.lessThan(this.wrapped_context, real_a, real_b);
                    }

                    pub fn swap(this: @This(), a: Entity, b: Entity) void {
                        this.storage.safeSwap(this.storage, a, b, true);
                    }
                };

                const swap_context = SortContext{ .storage = self, .wrapped_context = context, .lessThan = lessThan };
                self.set.arrange(length, swap_context, SortContext.sort, swap_context);
            }
        }

        /// Direct access to the array of entities
        pub fn data(self: Self) []const Entity {
            return self.set.data();
        }

        /// Direct access to the array of entities
        pub fn dataPtr(self: Self) *const []Entity {
            return self.set.dataPtr();
        }

        /// Swaps entities and objects in the internal packed arrays
        pub fn swap(self: *Self, lhs: Entity, rhs: Entity) void {
            self.safeSwap(self, lhs, rhs, false);
        }

        pub fn clear(self: *Self) void {
            if (!is_empty_struct) {
                self.instances.items.len = 0;
            }
            self.set.clear();
        }
    };
}

test "add/try-get/remove/clear" {
    const Entity = @import("entity.zig").DefaultEntity;
    var store = ComponentStorage(f32, Entity).init(std.testing.allocator);
    defer store.deinit();

    store.add(.{ .index = 3, .version = 0 }, 66.45);
    try std.testing.expectEqual(store.tryGetConst(.{ .index = 3, .version = 0 }).?, 66.45);
    if (store.tryGet(.{ .index = 3, .version = 0 })) |found| {
        try std.testing.expectEqual(@as(f32, 66.45), found.*);
    }

    store.remove(.{ .index = 3, .version = 0 });

    const val_null = store.tryGet(.{ .index = 3, .version = 0 });
    try std.testing.expectEqual(val_null, null);

    store.clear();
}

test "add/get/remove" {
    const Entity = @import("entity.zig").DefaultEntity;

    var store = ComponentStorage(f32, Entity).init(std.testing.allocator);
    defer store.deinit();

    store.add(.{ .index = 3, .version = 0 }, 66.45);
    if (store.tryGet(.{ .index = 3, .version = 0 })) |found| try std.testing.expectEqual(@as(f32, 66.45), found.*);
    try std.testing.expectEqual(store.tryGetConst(.{ .index = 3, .version = 0 }).?, 66.45);

    store.remove(.{ .index = 3, .version = 0 });
    try std.testing.expectEqual(store.tryGet(.{ .index = 3, .version = 0 }), null);
}

test "iterate" {
    const Entity = @import("entity.zig").DefaultEntity;

    var store = ComponentStorage(f32, Entity).create(std.testing.allocator);
    defer store.destroy();

    store.add(.{ .index = 3, .version = 0 }, 66.45);
    store.add(.{ .index = 5, .version = 0 }, 66.45);
    store.add(.{ .index = 7, .version = 0 }, 66.45);

    for (store.data(), 0..) |entity, i| {
        if (i == 0) {
            try std.testing.expectEqual(@as(Entity, .{ .index = 3, .version = 0 }), entity);
        }
        if (i == 1) {
            try std.testing.expectEqual(@as(Entity, .{ .index = 5, .version = 0 }), entity);
        }
        if (i == 2) {
            try std.testing.expectEqual(@as(Entity, .{ .index = 7, .version = 0 }), entity);
        }
    }
}

test "empty component" {
    const Entity = @import("entity.zig").DefaultEntity;

    const Empty = struct {};

    var store = ComponentStorage(Empty, Entity).create(std.testing.allocator);
    defer store.destroy();

    store.add(.{ .index = 0, .version = 0 }, Empty{});
    store.remove(.{ .index = 0, .version = 0 });
}

test "signals" {
    const Entity = @import("entity.zig").DefaultEntity;

    var store = ComponentStorage(f32, Entity).init(std.testing.allocator);
    defer store.deinit();

    const Callbacks = struct {
        fn construct(_: *Registry, e: Entity) void {
            std.debug.assert(e.index == 3);
        }
        fn update(_: *Registry, e: Entity) void {
            std.debug.assert(e.index == 3);
        }
        fn destruct(_: *Registry, e: Entity) void {
            std.debug.assert(e.index == 3);
        }
    };

    store.onConstruct().connect(Callbacks.construct);
    store.onUpdate().connect(Callbacks.update);
    store.onDestruct().connect(Callbacks.destruct);

    store.add(.{ .index = 3, .version = 0 }, 66.45);
    store.replace(.{ .index = 3, .version = 0 }, 45.64);
    store.remove(.{ .index = 3, .version = 0 });

    store.onConstruct().disconnect(Callbacks.construct);
    store.onUpdate().disconnect(Callbacks.update);
    store.onDestruct().disconnect(Callbacks.destruct);

    store.add(.{ .index = 4, .version = 0 }, 66.45);
    store.replace(.{ .index = 4, .version = 0 }, 45.64);
    store.remove(.{ .index = 4, .version = 0 });
}

test "sort empty component" {
    const Entity = @import("entity.zig").DefaultEntity;

    const Empty = struct {};

    var store = ComponentStorage(Empty, Entity).create(std.testing.allocator);
    defer store.destroy();

    store.add(.{ .index = 1, .version = 0 }, Empty{});
    store.add(.{ .index = 2, .version = 0 }, Empty{});
    store.add(.{ .index = 0, .version = 0 }, Empty{});

    const asc = struct {
        fn sort(_: void, a: Entity, b: Entity) bool {
            return a.index < b.index;
        }
    }.sort;

    store.sortEmpty(Entity, {}, asc);
    for (store.data(), 0..) |e, i| {
        try std.testing.expectEqual(@as(Entity, .{ .index = @intCast(i), .version = 0 }), e);
    }

    const desc = struct {
        fn sort(_: void, a: Entity, b: Entity) bool {
            return a.index > b.index;
        }
    }.sort;

    store.sortEmpty(Entity, {}, desc);
    var counter: Entity.Index = 2;
    for (store.data()) |e| {
        try std.testing.expectEqual(@as(Entity, .{ .index = counter, .version = 0 }), e);
        if (counter > 0) counter -= 1;
    }
}

test "sort by entity" {
    const Entity = @import("entity.zig").DefaultEntity;

    var store = ComponentStorage(f32, Entity).create(std.testing.allocator);
    defer store.destroy();

    store.add(.{ .index = 22, .version = 0 }, @as(f32, 2.2));
    store.add(.{ .index = 11, .version = 0 }, @as(f32, 1.1));
    store.add(.{ .index = 33, .version = 0 }, @as(f32, 3.3));

    const SortContext = struct {
        store: *ComponentStorage(f32, Entity),

        fn sort(this: @This(), a: Entity, b: Entity) bool {
            const real_a = this.store.getConst(a);
            const real_b = this.store.getConst(b);
            return real_a > real_b;
        }
    };
    const context = SortContext{ .store = store };
    store.sort(Entity, store.len(), context, SortContext.sort);

    var compare: f32 = 5;
    for (store.raw()) |val| {
        try std.testing.expect(compare > val);
        compare = val;
    }
}

test "sort by component" {
    const Entity = @import("entity.zig").DefaultEntity;

    var store = ComponentStorage(f32, Entity).create(std.testing.allocator);
    defer store.destroy();

    store.add(.{ .index = 22, .version = 0 }, @as(f32, 2.2));
    store.add(.{ .index = 11, .version = 0 }, @as(f32, 1.1));
    store.add(.{ .index = 33, .version = 0 }, @as(f32, 3.3));

    const desc_f32 = comptime std.sort.desc(f32);
    store.sort(f32, store.len(), {}, desc_f32);

    var compare: f32 = 5;
    for (store.raw()) |val| {
        try std.testing.expect(compare > val);
        compare = val;
    }
}
