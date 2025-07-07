const std = @import("std");
const utils = @import("utils.zig");
const registry = @import("registry.zig");
const ReverseSliceIterator = @import("utils.zig").ReverseSliceIterator;

/// NOTE: This is a copy of `std.sort.insertionSort` with fixed function pointer
/// syntax to avoid compilation errors.
///
/// Stable in-place sort. O(n) best case, O(pow(n, 2)) worst case.
/// O(1) memory (no allocator required).
/// This can be expressed in terms of `insertionSortContext` but the glue
/// code is slightly longer than the direct implementation.
fn std_sort_insertionSort_clone(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThan: *const fn (context: @TypeOf(context), lhs: T, rhs: T) bool,
) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        var j: usize = i;
        while (j > 0 and lessThan(context, x, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = x;
    }
}

pub fn SparseSet(comptime Entity: type) type {
    return struct {
        const Self = @This();

        // TODO: should we support configurable or runtime page sizes?
        const page_size: usize = 4096;

        /// stores an index into `dense`
        sparse: std.ArrayListUnmanaged(?*[page_size]Entity.Index),
        dense: std.ArrayListUnmanaged(Entity),

        allocator: std.mem.Allocator,

        const tombstone = std.math.maxInt(Entity.Index);

        pub fn create(allocator: std.mem.Allocator) *Self {
            const set = allocator.create(Self) catch unreachable;
            set.* = Self.init(allocator);
            return set;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .sparse = .empty,
                .dense = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.detectCorruption();

            for (self.sparse.items) |maybe_page| {
                if (maybe_page) |page| {
                    self.allocator.free(page);
                }
            }

            self.dense.deinit(self.allocator);
            self.sparse.deinit(self.allocator);
        }

        /// Computes the page of an entity, given as an index
        pub fn pageIndex(_: Self, entity: Entity) usize {
            return entity.index / page_size;
        }

        /// Computes an entity's offset within its page
        fn pageOffset(_: Self, entity: Entity) usize {
            return entity.index & (page_size - 1);
        }

        fn getOrCreatePage(self: *Self, page_index: usize) *[page_size]Entity.Index {
            // Allocate references to new pages if necessary
            if (page_index >= self.sparse.items.len) {
                const start_pos = self.sparse.items.len;
                self.sparse.resize(self.allocator, page_index + 1) catch unreachable;
                self.sparse.expandToCapacity();
                @memset(self.sparse.items[start_pos..], null);
            }

            // Allocate new page if necessary
            if (self.sparse.items[page_index] == null) {
                const new_page = self.allocator.alloc(Entity.Index, page_size) catch unreachable;
                @memset(new_page, tombstone);
                self.sparse.items[page_index] = @ptrCast(new_page.ptr);
            }

            return self.sparse.items[page_index].?;
        }

        /// Increases the capacity of a sparse sets index array
        pub fn reserve(self: *Self, cap: usize) void {
            self.sparse.resize(cap) catch unreachable;
        }

        /// Returns the number of dense elements that a sparse set has currently allocated space for
        pub fn capacity(self: *Self) usize {
            return self.dense.capacity;
        }

        /// Returns the number of dense elements in a sparse set
        pub fn len(self: Self) usize {
            return self.dense.items.len;
        }

        pub fn empty(self: *Self) bool {
            return self.dense.items.len == 0;
        }

        pub fn data(self: Self) []const Entity {
            return self.dense.items;
        }

        pub fn dataPtr(self: Self) *const []Entity {
            return &self.dense.items;
        }

        pub fn contains(self: Self, entity: Entity) bool {
            const page_index = self.pageIndex(entity);
            if (page_index >= self.sparse.items.len) return false;

            return if (self.sparse.items[page_index]) |page|
                page[self.pageOffset(entity)] != tombstone
            else
                false;
        }

        /// Returns the position of an entity in the dense array
        /// Invokes detectable illegal behavior if the entity is
        /// not present
        pub fn index(self: Self, entity: Entity) Entity.Index {
            std.debug.assert(self.contains(entity));
            const page = self.sparse.items[self.pageIndex(entity)].?;
            const offset = self.pageOffset(entity);
            return page[offset];
        }

        /// Assigns an entity to a sparse set
        /// Invokes detectable illegal behavior if the entity is
        /// already present
        pub fn add(self: *Self, entity: Entity) void {
            std.debug.assert(!self.contains(entity));

            // assure(page(entt))[offset(entt)] = packed.size()
            const page = self.getOrCreatePage(self.pageIndex(entity));
            const offset = self.pageOffset(entity);

            page[offset] = @intCast(self.dense.items.len);
            self.dense.append(self.allocator, entity) catch unreachable;
            self.detectCorruption();
        }

        /// Removes an entity from a sparse set using a swapRemove strategy.
        /// We move the last element in the dense array to the vacated spot,
        /// and adjust the moved element's spot in the sparse array to point
        /// at the spot it moved to. We then mark the removed element's slot
        /// in the sparse array as tombstoned. Finally, pop the dense array.
        /// ```
        /// |0 1 2 3 4 5 6 7 8 9| <- indices for reference
        /// [1 _ 5 2 _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 3 9 5 2]         <- dense array
        ///
        /// step 0: Begin removal of entity 3, at index 2 in the dense array:
        ///
        /// |0 1 2 3 4 5 6 7 8 9|
        ///        ↓
        /// [1 _ 5 2 _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 3 9 5 2]         <- dense array
        ///      ↑
        ///
        /// step 1: Swap the last element in the dense array (entity 2) into
        /// the position previously occupied by entity 3 in the dense array
        ///
        ///  0 1 2 3 4 5 6 7 8 9
        /// [1 _ 5 2 _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 2 9 5 _]         <- dense array
        ///      ↑-----↓
        ///
        /// step 2: Change the entry of entity 2 in the sparse array to
        /// point at entity 2's new position
        ///
        ///  0 1 2 3 4 5 6 7 8 9
        ///      ↓
        /// [1 _ 2 2 _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 2 9 5 _]         <- dense array
        ///
        /// step 3: Mark the entry of entity 3 in the sparse array as
        /// a tombstone
        ///
        ///  0 1 2 3 4 5 6 7 8 9
        ///        ↓
        /// [1 _ 2 _ _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 2 9 5 _]         <- dense array
        ///
        /// step 4: Shrink the dense array by 1 element
        ///
        ///  0 1 2 3 4 5 6 7 8 9
        /// [1 _ 2 _ _ 4 _ 0 _ 3] <- sparse array
        /// [7 0 2 9 5]         <- dense array
        /// ```
        pub fn remove(self: *Self, entity: Entity) void {
            std.debug.assert(self.contains(entity));

            const page_index = self.pageIndex(entity);
            const offset = self.pageOffset(entity);

            // position of the removed entity in the dense array
            const removed_entity_dense_pos = self.sparse.items[page_index].?[offset];
            // last entity in the dense array
            const last_dense = self.dense.items[self.dense.items.len - 1];

            // move the last entity in the dense array to the position of the removed entity
            self.dense.items[removed_entity_dense_pos] = last_dense;

            // point the sparse entry of the moved entity to its new position
            self.sparse.items[self.pageIndex(last_dense)].?[self.pageOffset(last_dense)] = removed_entity_dense_pos;
            // tombstone removed entity in sparse array
            self.sparse.items[page_index].?[offset] = tombstone;

            _ = self.dense.pop();
            self.detectCorruption();
        }

        /// Swaps two entities in the internal packed and sparse arrays
        pub fn swap(self: *Self, lhs: Entity, rhs: Entity) void {
            const from = &self.sparse.items[self.pageIndex(lhs)].?[self.pageOffset(lhs)];
            const to = &self.sparse.items[self.pageIndex(rhs)].?[self.pageOffset(rhs)];

            std.mem.swap(Entity, &self.dense.items[from.*], &self.dense.items[to.*]);
            std.mem.swap(Entity.Index, from, to);
            self.detectCorruption();
        }

        /// Sort elements according to the given comparison function
        pub fn sort(self: *Self, context: anytype, comptime lessThan: *const fn (@TypeOf(context), Entity, Entity) bool) void {
            std_sort_insertionSort_clone(Entity, self.dense.items, context, lessThan);

            for (self.dense.items, 0..) |entity, i| {
                self.sparse.items[
                    self.pageIndex(entity)
                ].?[
                    self.pageOffset(entity)
                ] = @intCast(i);
            }
            self.detectCorruption();
        }

        /// Sort elements according to the given comparison function. Use this when a data array needs to stay in sync with the SparseSet
        /// by passing in a "swap_context" that contains a "swap" method with a sig of fn(ctx,SparseT,SparseT)void
        /// We first sort the dense array, then use the sparse array as a reference to permute the data array.
        /// https://skypjack.github.io/2019-09-25-ecs-baf-part-5/
        pub fn arrange(
            self: *Self,
            /// swaps elements between 0..length (exclusive)
            length: usize,
            context: anytype,
            comptime lessThan: *const fn (@TypeOf(context), Entity, Entity) bool,
            swap_context: anytype,
        ) void {
            // first, sort dense array
            std_sort_insertionSort_clone(Entity, self.dense.items[0..length], context, lessThan);
            for (0..length) |i| {
                var curr: Entity.Index = @intCast(i);
                var next = self.index(self.dense.items[curr]);

                while (curr != next) {
                    swap_context.swap(self.dense.items[curr], self.dense.items[next]);
                    self.sparse.items[
                        self.pageIndex(self.dense.items[curr])
                    ].?[
                        self.pageOffset(self.dense.items[curr])
                    ] = curr;

                    curr = next;
                    next = self.index(self.dense.items[curr]);
                }
            }
            self.detectCorruption();
        }

        /// Sort entities according to their order in another sparse set. Other is the master in this case.
        pub fn respect(self: *Self, other: *Self) void {
            var pos: Entity.Index = 0;
            var i: Entity.Index = 0;
            while (i < other.dense.items.len) : (i += 1) {
                if (self.contains(other.dense.items[i])) {
                    if (other.dense.items[i] != self.dense.items[pos]) {
                        self.swap(self.dense.items[pos], other.dense.items[i]);
                    }
                    pos += 1;
                }
            }
            self.detectCorruption();
            other.detectCorruption();
        }

        pub fn clear(self: *Self) void {
            for (self.sparse.items, 0..) |maybe_page, i| {
                if (maybe_page) |page| {
                    self.allocator.free(page);
                    self.sparse.items[i] = null;
                }
            }

            self.sparse.items.len = 0;
            self.dense.items.len = 0;
            self.detectCorruption();
        }

        pub fn reverseIterator(self: *Self) ReverseSliceIterator(Entity) {
            return ReverseSliceIterator(Entity).init(self.dense.items);
        }

        pub fn detectCorruption(self: *Self) void {
            if (!@import("builtin").is_test) return;

            var entities: std.AutoHashMapUnmanaged(Entity, void) = .empty;
            defer entities.deinit(self.allocator);

            // make sure that all elements only exist once
            for (self.dense.items, 0..) |entity, i| {
                if (entities.fetchPut(self.allocator, entity, void{}) catch unreachable) |_| std.debug.panic("set corrupted: duplicate entry in dense list", .{});
                if (!self.contains(entity)) std.debug.panic("set corrupted: orphaned entry in dense list", .{});
                if (self.index(entity) != i) std.debug.panic("set corrupted: entry in sparse list points to wrong entity in dense list", .{});
            }

            var indices: std.AutoHashMapUnmanaged(Entity.Index, void) = .empty;
            defer indices.deinit(self.allocator);

            // make sure all elements are only pointed to once
            for (self.sparse.items) |maybe_page| {
                if (maybe_page) |page| {
                    for (page) |dense_index| {
                        if (dense_index == tombstone) continue;
                        if (indices.fetchPut(self.allocator, dense_index, void{}) catch unreachable) |_| std.debug.panic("set corrupted: two locations in sparse list point to same entry", .{});
                    }
                }
            }
        }
    };
}

fn printSet(set: anytype) void {
    std.debug.print("\nsparse -----\n", .{});
    for (set.sparse) |page| {
        std.debug.print("{}\t", .{page});
    }

    std.debug.print("\ndense -----\n", .{});
    for (set.dense.items) |dense| {
        std.debug.print("{}\t", .{dense});
    }
    std.debug.print("\n\n", .{});
}

test "add/remove/clear" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    const e0: Entity = .{ .index = 4, .version = 0 };
    const e1: Entity = .{ .index = 3, .version = 0 };

    set.add(e0);
    set.add(e1);
    try std.testing.expectEqual(set.len(), 2);
    try std.testing.expectEqual(set.index(e0), 0);
    try std.testing.expectEqual(set.index(e1), 1);

    set.remove(e0);
    try std.testing.expectEqual(set.len(), 1);

    set.clear();
    try std.testing.expectEqual(set.len(), 0);
}

test "grow" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    var i: usize = std.math.maxInt(u8);
    while (i > 0) : (i -= 1) {
        set.add(.{ .index = @intCast(i), .version = 0 });
    }

    try std.testing.expectEqual(set.len(), std.math.maxInt(u8));
}

test "swap" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    const e0: Entity = .{ .index = 4, .version = 0 };
    const e1: Entity = .{ .index = 3, .version = 0 };

    set.add(e0);
    set.add(e1);
    try std.testing.expectEqual(set.index(e0), 0);
    try std.testing.expectEqual(set.index(e1), 1);

    set.swap(e0, e1);
    try std.testing.expectEqual(set.index(e1), 0);
    try std.testing.expectEqual(set.index(e0), 1);
}

test "data() synced" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    const e0: Entity = .{ .index = 0, .version = 0 };
    const e1: Entity = .{ .index = 1, .version = 0 };
    const e2: Entity = .{ .index = 2, .version = 0 };
    const e3: Entity = .{ .index = 3, .version = 0 };

    set.add(e0);
    set.add(e1);
    set.add(e2);
    set.add(e3);

    const data = set.data();
    try std.testing.expectEqual(data[1], e1);
    try std.testing.expectEqual(set.len(), data.len);

    set.remove(e0);
    set.remove(e1);
    try std.testing.expectEqual(set.len(), set.data().len);
}

test "iterate" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    const e0: Entity = .{ .index = 0, .version = 0 };
    const e1: Entity = .{ .index = 1, .version = 0 };
    const e2: Entity = .{ .index = 2, .version = 0 };
    const e3: Entity = .{ .index = 3, .version = 0 };

    set.add(e0);
    set.add(e1);
    set.add(e2);
    set.add(e3);

    var i: u32 = @as(u32, @intCast(set.len())) - 1;
    var iter = set.reverseIterator();
    while (iter.next()) |entity| {
        try std.testing.expectEqual(@as(Entity, .{ .index = @intCast(i), .version = 0 }), entity);
        if (i > 0) i -= 1;
    }
}

test "respect 1" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set1 = SparseSet(Entity).create(std.testing.allocator);
    defer set1.destroy();

    var set2 = SparseSet(Entity).create(std.testing.allocator);
    defer set2.destroy();

    set1.add(.{ .index = 3, .version = 0 });
    set1.add(.{ .index = 4, .version = 0 });
    set1.add(.{ .index = 5, .version = 0 });
    set1.add(.{ .index = 6, .version = 0 });
    set1.add(.{ .index = 7, .version = 0 });

    set2.add(.{ .index = 8, .version = 0 });
    set2.add(.{ .index = 6, .version = 0 });
    set2.add(.{ .index = 4, .version = 0 });

    set1.respect(set2);

    try std.testing.expectEqual(set1.dense.items[0], set2.dense.items[1]);
    try std.testing.expectEqual(set1.dense.items[1], set2.dense.items[2]);
}

test "respect 2" {
    const Entity = @import("entity.zig").DefaultEntity;
    var set = SparseSet(Entity).create(std.testing.allocator);
    defer set.destroy();

    set.add(.{ .index = 5, .version = 0 });
    set.add(.{ .index = 2, .version = 0 });
    set.add(.{ .index = 4, .version = 0 });
    set.add(.{ .index = 1, .version = 0 });
    set.add(.{ .index = 3, .version = 0 });

    set.sort({}, struct {
        pub fn desc(_: void, a: Entity, b: Entity) bool {
            return a.index > b.index;
        }
    }.desc);

    for (set.dense.items[0 .. set.dense.items.len - 1], 0..) |entity, i| {
        std.debug.assert(entity.index > set.dense.items[i + 1].index);
    }
}
