const std = @import("std");
const warn = std.debug.warn;
const utils = @import("utils.zig");

const SparseSet = @import("sparse_set.zig").SparseSet;
const Signal = @import("../signals/signal.zig").Signal;
const Sink = @import("../signals/sink.zig").Sink;

/// Stores an ArrayList of components along with a SparseSet of entities
pub fn ComponentStorage(comptime CompT: type, comptime EntityT: type) type {
    std.debug.assert(!utils.isComptime(CompT));

    // empty (zero-sized) structs will not have an array created
    comptime const is_empty_struct = @sizeOf(CompT) == 0;

    // HACK: due to this being stored as untyped ptrs, when deinit is called we are casted to a CompT of some random
    // non-zero sized type. That will make is_empty_struct false in deinit always so we can't use it. Instead, we stick
    // a small dummy struct in the instances ArrayList so it can safely be deallocated.
    // Perhaps we should just allocate instances with a dummy allocator or the tmp allocator?
    comptime var CompOrAlmostEmptyT = CompT;
    if (is_empty_struct)
        CompOrAlmostEmptyT = struct { dummy: u1 };

    return struct {
        const Self = @This();

        set: *SparseSet(EntityT),
        instances: std.ArrayList(CompOrAlmostEmptyT),
        allocator: ?*std.mem.Allocator,
        super: usize = 0, /// doesnt really belong here...used to denote group ownership
        safe_deinit: fn (*Self) void,
        safe_swap: fn (*Self, EntityT, EntityT) void,
        construction: Signal(EntityT),
        update: Signal(EntityT),
        destruction: Signal(EntityT),

        pub fn init(allocator: *std.mem.Allocator) Self {
            var store = Self{
                .set = SparseSet(EntityT).initPtr(allocator),
                .instances = undefined,
                .safe_deinit = struct {
                    fn deinit(self: *Self) void {
                        if (!is_empty_struct)
                            self.instances.deinit();
                    }
                }.deinit,
                .safe_swap = struct {
                    fn swap(self: *Self, lhs: EntityT, rhs: EntityT) void {
                        if (!is_empty_struct)
                            std.mem.swap(CompT, &self.instances.items[self.set.index(lhs)], &self.instances.items[self.set.index(rhs)]);
                        self.set.swap(lhs, rhs);
                    }
                }.swap,
                .allocator = null,
                .construction = Signal(EntityT).init(allocator),
                .update = Signal(EntityT).init(allocator),
                .destruction = Signal(EntityT).init(allocator),
            };

            if (!is_empty_struct)
                store.instances = std.ArrayList(CompOrAlmostEmptyT).init(allocator);

            return store;
        }

        pub fn initPtr(allocator: *std.mem.Allocator) *Self {
            var store = allocator.create(Self) catch unreachable;
            store.set = SparseSet(EntityT).initPtr(allocator);
            if (!is_empty_struct)
                store.instances = std.ArrayList(CompOrAlmostEmptyT).init(allocator);
            store.allocator = allocator;
            store.super = 0;
            store.construction = Signal(EntityT).init(allocator);
            store.update = Signal(EntityT).init(allocator);
            store.destruction = Signal(EntityT).init(allocator);

            // since we are stored as a pointer, we need to catpure this
            store.safe_deinit = struct {
                fn deinit(self: *Self) void {
                    if (!is_empty_struct)
                        self.instances.deinit();
                }
            }.deinit;

            store.safe_swap = struct {
                fn swap(self: *Self, lhs: EntityT, rhs: EntityT) void {
                    if (!is_empty_struct)
                        std.mem.swap(CompT, &self.instances.items[self.set.index(lhs)], &self.instances.items[self.set.index(rhs)]);
                    self.set.swap(lhs, rhs);
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

            if (self.allocator) |allocator|
                allocator.destroy(self);
        }

        pub fn onConstruct(self: *Self) Sink(EntityT) {
            return self.construction.sink();
        }

        pub fn onUpdate(self: *Self) Sink(EntityT) {
            return self.update.sink();
        }

        pub fn onDestruct(self: *Self) Sink(EntityT) {
            return self.destruction.sink();
        }

        /// Increases the capacity of a component storage
        pub fn reserve(self: *Self, cap: usize) void {
            self.set.reserve(cap);
            if (!is_empty_struct)
                self.instances.items.reserve(cap);
        }

        /// Assigns an entity to a storage and assigns its object
        pub fn add(self: *Self, entity: EntityT, value: CompT) void {
            if (!is_empty_struct)
                _ = self.instances.append(value) catch unreachable;
            self.set.add(entity);
            self.construction.publish(entity);
        }

        /// Removes an entity from a storage
        pub fn remove(self: *Self, entity: EntityT) void {
            self.destruction.publish(entity);
            if (!is_empty_struct)
                _ = self.instances.swapRemove(self.set.index(entity));
            self.set.remove(entity);
        }

        /// Checks if a view contains an entity
        pub fn contains(self: Self, entity: EntityT) bool {
            return self.set.contains(entity);
        }

        pub fn len(self: Self) usize {
            return self.set.len();
        }

        pub usingnamespace if (is_empty_struct)
            struct {}
        else
            struct {
                /// Direct access to the array of objects
                pub fn raw(self: Self) []CompT {
                    return self.instances.items;
                }

                /// Replaces the given component for an entity
                pub fn replace(self: *Self, entity: EntityT, value: CompT) void {
                    self.get(entity).* = value;
                    self.update.publish(entity);
                }

                /// Returns the object associated with an entity
                pub fn get(self: *Self, entity: EntityT) *CompT {
                    std.debug.assert(self.contains(entity));
                    return &self.instances.items[self.set.index(entity)];
                }

                pub fn getConst(self: *Self, entity: EntityT) CompT {
                    return self.instances.items[self.set.index(entity)];
                }

                /// Returns a pointer to the object associated with an entity, if any.
                pub fn tryGet(self: *Self, entity: EntityT) ?*CompT {
                    return if (self.set.contains(entity)) &self.instances.items[self.set.index(entity)] else null;
                }

                pub fn tryGetConst(self: *Self, entity: EntityT) ?CompT {
                    return if (self.set.contains(entity)) self.instances.items[self.set.index(entity)] else null;
                }
            };

        /// Direct access to the array of entities
        pub fn data(self: Self) *const []EntityT {
            return self.set.data();
        }

        /// Swaps entities and objects in the internal packed arrays
        pub fn swap(self: *Self, lhs: EntityT, rhs: EntityT) void {
            self.safe_swap(self, lhs, rhs);
        }

        pub fn clear(self: *Self) void {
            if (!is_empty_struct)
                self.instances.items.len = 0;
            self.set.clear();
        }
    };
}

test "add/try-get/remove/clear" {
    var store = ComponentStorage(f32, u32).init(std.testing.allocator);
    defer store.deinit();

    store.add(3, 66.45);
    std.testing.expectEqual(store.tryGetConst(3).?, 66.45);
    if (store.tryGet(3)) |found| std.testing.expectEqual(@as(f32, 66.45), found.*);

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

    for (store.data().*) |entity, i| {
        if (i == 0)
            std.testing.expectEqual(entity, 3);
        if (i == 1)
            std.testing.expectEqual(entity, 5);
        if (i == 2)
            std.testing.expectEqual(entity, 7);
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
