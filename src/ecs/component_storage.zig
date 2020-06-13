const std = @import("std");
const warn = std.debug.warn;
const utils = @import("utils.zig");

const SparseSet = @import("sparse_set.zig").SparseSet;
const Signal = @import("../signals/signal.zig").Signal;
const Sink = @import("../signals/sink.zig").Sink;

/// Stores an ArrayList of components along with a SparseSet of entities
pub fn ComponentStorage(comptime Component: type, comptime Entity: type) type {
    std.debug.assert(!utils.isComptime(Component));

    // empty (zero-sized) structs will not have an array created
    comptime const is_empty_struct = @sizeOf(Component) == 0;

    // HACK: due to this being stored as untyped ptrs, when deinit is called we are casted to a Component of some random
    // non-zero sized type. That will make is_empty_struct false in deinit always so we can't use it. Instead, we stick
    // a small dummy struct in the instances ArrayList so it can safely be deallocated.
    // Perhaps we should just allocate instances with a dummy allocator or the tmp allocator?
    comptime var ComponentOrDummy = if (is_empty_struct) struct { dummy: u1 } else Component;

    return struct {
        const Self = @This();

        set: *SparseSet(Entity),
        instances: std.ArrayList(ComponentOrDummy),
        allocator: ?*std.mem.Allocator,
        /// doesnt really belong here...used to denote group ownership
        super: usize = 0,
        safe_deinit: fn (*Self) void,
        safe_swap: fn (*Self, Entity, Entity, bool) void,
        construction: Signal(Entity),
        update: Signal(Entity),
        destruction: Signal(Entity),

        pub fn init(allocator: *std.mem.Allocator) Self {
            var store = Self{
                .set = SparseSet(Entity).initPtr(allocator),
                .instances = undefined,
                .safe_deinit = struct {
                    fn deinit(self: *Self) void {
                        if (!is_empty_struct) {
                            self.instances.deinit();
                        }
                    }
                }.deinit,
                .safe_swap = struct {
                    fn swap(self: *Self, lhs: Entity, rhs: Entity, instances_only: bool) void {
                        if (!is_empty_struct) {
                            std.mem.swap(Component, &self.instances.items[self.set.index(lhs)], &self.instances.items[self.set.index(rhs)]);
                        }
                        if (!instances_only) self.set.swap(lhs, rhs);
                    }
                }.swap,
                .allocator = null,
                .construction = Signal(Entity).init(allocator),
                .update = Signal(Entity).init(allocator),
                .destruction = Signal(Entity).init(allocator),
            };

            if (!is_empty_struct) {
                store.instances = std.ArrayList(ComponentOrDummy).init(allocator);
            }

            return store;
        }

        pub fn initPtr(allocator: *std.mem.Allocator) *Self {
            var store = allocator.create(Self) catch unreachable;
            store.set = SparseSet(Entity).initPtr(allocator);
            if (!is_empty_struct) {
                store.instances = std.ArrayList(ComponentOrDummy).init(allocator);
            }
            store.allocator = allocator;
            store.super = 0;
            store.construction = Signal(Entity).init(allocator);
            store.update = Signal(Entity).init(allocator);
            store.destruction = Signal(Entity).init(allocator);

            // since we are stored as a pointer, we need to catpure this
            store.safe_deinit = struct {
                fn deinit(self: *Self) void {
                    if (!is_empty_struct) {
                        self.instances.deinit();
                    }
                }
            }.deinit;

            store.safe_swap = struct {
                fn swap(self: *Self, lhs: Entity, rhs: Entity, instances_only: bool) void {
                    if (!is_empty_struct) {
                        std.mem.swap(Component, &self.instances.items[self.set.index(lhs)], &self.instances.items[self.set.index(rhs)]);
                    }
                    if (!instances_only) self.set.swap(lhs, rhs);
                }
            }.swap;

            return store;
        }

        pub fn deinit(self: *Self) void {
            // great care must be taken here. Due to how Registry keeps this struct as pointers anything touching a type
            // will be wrong since it has to cast to a random struct when deiniting. Because of all that, is_empty_struct
            // will allways be false here so we have to deinit the instances no matter what.
            self.safe_deinit(self);
            self.set.deinit();
            self.construction.deinit();
            self.update.deinit();
            self.destruction.deinit();

            if (self.allocator) |allocator| {
                allocator.destroy(self);
            }
        }

        pub fn onConstruct(self: *Self) Sink(Entity) {
            return self.construction.sink();
        }

        pub fn onUpdate(self: *Self) Sink(Entity) {
            return self.update.sink();
        }

        pub fn onDestruct(self: *Self) Sink(Entity) {
            return self.destruction.sink();
        }

        /// Increases the capacity of a component storage
        pub fn reserve(self: *Self, cap: usize) void {
            self.set.reserve(cap);
            if (!is_empty_struct) {
                elf.instances.items.reserve(cap);
            }
        }

        /// Assigns an entity to a storage and assigns its object
        pub fn add(self: *Self, entity: Entity, value: Component) void {
            if (!is_empty_struct) {
                _ = self.instances.append(value) catch unreachable;
            }
            self.set.add(entity);
            self.construction.publish(entity);
        }

        /// Removes an entity from a storage
        pub fn remove(self: *Self, entity: Entity) void {
            self.destruction.publish(entity);
            if (!is_empty_struct) {
                _ = self.instances.swapRemove(self.set.index(entity));
            }
            self.set.remove(entity);
        }

        /// Checks if a view contains an entity
        pub fn contains(self: Self, entity: Entity) bool {
            return self.set.contains(entity);
        }

        pub fn len(self: Self) usize {
            return self.set.len();
        }

        pub usingnamespace if (is_empty_struct)
            struct {
                /// Sort Entities according to the given comparison function. Only T == Entity is allowed. The constraint param only exists for
                /// parity with non-empty Components
                pub fn sort(self: Self, comptime T: type, context: var, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
                    std.debug.assert(T == Entity);
                    self.set.sort(context, lessThan);
                }
            }
        else
            struct {
                /// Direct access to the array of objects
                pub fn raw(self: Self) []Component {
                    return self.instances.items;
                }

                /// Replaces the given component for an entity
                pub fn replace(self: *Self, entity: Entity, value: Component) void {
                    self.get(entity).* = value;
                    self.update.publish(entity);
                }

                /// Returns the object associated with an entity
                pub fn get(self: *Self, entity: Entity) *Component {
                    std.debug.assert(self.contains(entity));
                    return &self.instances.items[self.set.index(entity)];
                }

                pub fn getConst(self: *Self, entity: Entity) Component {
                    return self.instances.items[self.set.index(entity)];
                }

                /// Returns a pointer to the object associated with an entity, if any.
                pub fn tryGet(self: *Self, entity: Entity) ?*Component {
                    return if (self.set.contains(entity)) &self.instances.items[self.set.index(entity)] else null;
                }

                pub fn tryGetConst(self: *Self, entity: Entity) ?Component {
                    return if (self.set.contains(entity)) self.instances.items[self.set.index(entity)] else null;
                }

                /// Sort Entities or Components according to the given comparison function. Valid types for T are Entity or Component.
                pub fn sort(self: *Self, comptime T: type, length: usize, context: var, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
                    std.debug.assert(T == Entity or T == Component);
                    if (T == Entity) {
                        // wtf? When an OwningGroup calls us we are gonna be fake-typed and if we are fake-typed its not safe to pass our slice to
                        // the SparseSet and let it handle sorting. Instead, we'll use swap _without a set swap_ and do it ourselves.
                        if (Component == u1) {
                            const SortContext = struct {
                                storage: *Self,

                                pub fn swap(this: @This(), a: Entity, b: Entity) void {
                                    this.storage.safe_swap(this.storage, a, b, true);
                                }
                            };
                            const swap_context = SortContext{.storage = self};
                            self.set.sortSwap(length, context, lessThan, swap_context);
                        } else {
                            self.set.sortSub(length, context, lessThan, Component, self.instances.items);
                        }
                    } else if (T == Component) {
                        self.set.sortSubSub(length, context, Component, lessThan, self.instances.items);
                    }
                }
            };

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
            self.safe_swap(self, lhs, rhs, false);
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
    var store = ComponentStorage(f32, u32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 66.45);
    std.testing.expectEqual(store.tryGetConst(3).?, 66.45);
    if (store.tryGet(3)) |found| {
        std.testing.expectEqual(@as(f32, 66.45), found.*);
    }

    store.remove(3);

    var val_null = store.tryGet(3);
    std.testing.expectEqual(val_null, null);

    store.clear();
}

test "add/get/remove" {
    var store = ComponentStorage(f32, u32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 66.45);
    if (store.tryGet(3)) |found| std.testing.expectEqual(@as(f32, 66.45), found.*);
    std.testing.expectEqual(store.tryGetConst(3).?, 66.45);

    store.remove(3);
    std.testing.expectEqual(store.tryGet(3), null);
}

test "iterate" {
    var store = ComponentStorage(f32, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(3, 66.45);
    store.add(5, 66.45);
    store.add(7, 66.45);

    for (store.data()) |entity, i| {
        if (i == 0) {
            std.testing.expectEqual(entity, 3);
        }
        if (i == 1) {
            std.testing.expectEqual(entity, 5);
        }
        if (i == 2) {
            std.testing.expectEqual(entity, 7);
        }
    }
}

test "empty component" {
    const Empty = struct {};

    var store = ComponentStorage(Empty, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(3, Empty{});
    store.remove(3);
}

fn construct(e: u32) void {
    std.debug.assert(e == 3);
}
fn update(e: u32) void {
    std.debug.assert(e == 3);
}
fn destruct(e: u32) void {
    std.debug.assert(e == 3);
}

test "signals" {
    var store = ComponentStorage(f32, u32).init(std.testing.allocator);
    defer store.deinit();

    store.onConstruct().connect(construct);
    store.onUpdate().connect(update);
    store.onDestruct().connect(destruct);

    store.add(3, 66.45);
    store.replace(3, 45.64);
    store.remove(3);

    store.onConstruct().disconnect(construct);
    store.onUpdate().disconnect(update);
    store.onDestruct().disconnect(destruct);

    store.add(4, 66.45);
    store.replace(4, 45.64);
    store.remove(4);
}

test "sort empty component" {
    const Empty = struct {};

    var store = ComponentStorage(Empty, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(1, Empty{});
    store.add(2, Empty{});
    store.add(0, Empty{});

    comptime const asc_u32 = std.sort.asc(u32);
    store.sort(u32, {}, asc_u32);
    for (store.data()) |e, i| {
        std.testing.expectEqual(@intCast(u32, i), e);
    }

    comptime const desc_u32 = std.sort.desc(u32);
    store.sort(u32, {}, desc_u32);
    var counter: u32 = 2;
    for (store.data()) |e, i| {
        std.testing.expectEqual(counter, e);
        if (counter > 0) counter -= 1;
    }
}

test "sort by entity" {
    var store = ComponentStorage(f32, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(22, @as(f32, 2.2));
    store.add(11, @as(f32, 1.1));
    store.add(33, @as(f32, 3.3));

    const SortContext = struct {
        store: *ComponentStorage(f32, u32),

        fn sort(this: @This(), a: u32, b: u32) bool {
            const real_a = this.store.getConst(a);
            const real_b = this.store.getConst(b);
            return real_a > real_b;
        }
    };
    const context = SortContext{ .store = store };
    store.sort(u32, store.len(), context, SortContext.sort);

    var compare: f32 = 5;
    for (store.raw()) |val, i| {
        std.testing.expect(compare > val);
        compare = val;
    }
}

test "sort by component" {
    var store = ComponentStorage(f32, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(22, @as(f32, 2.2));
    store.add(11, @as(f32, 1.1));
    store.add(33, @as(f32, 3.3));

    comptime const desc_f32 = std.sort.desc(f32);
    store.sort(f32, store.len(), {}, desc_f32);

    var compare: f32 = 5;
    for (store.raw()) |val, i| {
        std.testing.expect(compare > val);
        compare = val;
    }
}
