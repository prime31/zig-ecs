const std = @import("std");
const warn = std.debug.warn;
const utils = @import("utils.zig");
const ReverseSliceIterator = @import("utils.zig").ReverseSliceIterator;

// TODO: fix entity_mask. it should come from EntityTraitsDefinition.
pub fn SparseSet(comptime SparseT: type) type {
    return struct {
        const Self = @This();
        const page_size: usize = 32768;
        const entity_per_page = page_size / @sizeOf(SparseT);

        sparse: std.ArrayList(?[]SparseT),
        dense: std.ArrayList(SparseT),
        entity_mask: SparseT,
        allocator: ?*std.mem.Allocator,

        pub fn initPtr(allocator: *std.mem.Allocator) *Self {
            var set = allocator.create(Self) catch unreachable;
            set.sparse = std.ArrayList(?[]SparseT).init(allocator);
            set.dense = std.ArrayList(SparseT).init(allocator);
            set.entity_mask = std.math.maxInt(SparseT);
            set.allocator = allocator;
            return set;
        }

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .sparse = std.ArrayList(?[]SparseT).init(allocator),
                .dense = std.ArrayList(SparseT).init(allocator),
                .entity_mask = std.math.maxInt(SparseT),
                .allocator = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.expandToCapacity();
            for (self.sparse.items) |array, i| {
                if (array) |arr| {
                    self.sparse.allocator.free(arr);
                }
            }

            self.dense.deinit();
            self.sparse.deinit();

            if (self.allocator) |allocator| {
                allocator.destroy(self);
            }
        }

        pub fn page(self: Self, sparse: SparseT) usize {
            return (sparse & self.entity_mask) / entity_per_page;
        }

        fn offset(self: Self, sparse: SparseT) usize {
            return sparse & (entity_per_page - 1);
        }

        fn assure(self: *Self, pos: usize) []SparseT {
            if (pos >= self.sparse.items.len) {
                const start_pos = self.sparse.items.len;
                self.sparse.resize(pos + 1) catch unreachable;
                self.sparse.expandToCapacity();
                std.mem.set(?[]SparseT, self.sparse.items[start_pos..], null);
            }

            if (self.sparse.items[pos]) |arr| {
                return arr;
            }

            var new_page = self.sparse.allocator.alloc(SparseT, entity_per_page) catch unreachable;
            std.mem.set(SparseT, new_page, std.math.maxInt(SparseT));
            self.sparse.items[pos] = new_page;

            return self.sparse.items[pos].?;
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

        pub fn data(self: Self) []const SparseT {
            return self.dense.items;
        }

        pub fn dataPtr(self: Self) *const []SparseT {
            return &self.dense.items;
        }

        pub fn contains(self: Self, sparse: SparseT) bool {
            const curr = self.page(sparse);
            return curr < self.sparse.items.len and self.sparse.items[curr] != null and self.sparse.items[curr].?[self.offset(sparse)] != std.math.maxInt(SparseT);
        }

        /// Returns the position of an entity in a sparse set
        pub fn index(self: Self, sparse: SparseT) SparseT {
            std.debug.assert(self.contains(sparse));
            return self.sparse.items[self.page(sparse)].?[self.offset(sparse)];
        }

        /// Assigns an entity to a sparse set
        pub fn add(self: *Self, sparse: SparseT) void {
            std.debug.assert(!self.contains(sparse));

            // assure(page(entt))[offset(entt)] = packed.size()
            self.assure(self.page(sparse))[self.offset(sparse)] = @intCast(SparseT, self.dense.items.len);
            _ = self.dense.append(sparse) catch unreachable;
        }

        /// Removes an entity from a sparse set
        pub fn remove(self: *Self, sparse: SparseT) void {
            std.debug.assert(self.contains(sparse));

            const curr = self.page(sparse);
            const pos = self.offset(sparse);
            const last_dense = self.dense.items[self.dense.items.len - 1];

            self.dense.items[self.sparse.items[curr].?[pos]] = last_dense;
            self.sparse.items[self.page(last_dense)].?[self.offset(last_dense)] = self.sparse.items[curr].?[pos];
            self.sparse.items[curr].?[pos] = std.math.maxInt(SparseT);

            _ = self.dense.pop();
        }

        /// Swaps two entities in the internal packed and sparse arrays
        pub fn swap(self: *Self, lhs: SparseT, rhs: SparseT) void {
            var from = &self.sparse.items[self.page(lhs)].?[self.offset(lhs)];
            var to = &self.sparse.items[self.page(rhs)].?[self.offset(rhs)];

            std.mem.swap(SparseT, &self.dense.items[from.*], &self.dense.items[to.*]);
            std.mem.swap(SparseT, from, to);
        }

        /// Sort elements according to the given comparison function
        pub fn sort(self: *Self, context: anytype, comptime lessThan: fn (@TypeOf(context), SparseT, SparseT) bool) void {
            std.sort.insertionSort(SparseT, self.dense.items, context, lessThan);

            for (self.dense.items) |sparse, i| {
                const item = @intCast(SparseT, i);
                self.sparse.items[self.page(self.dense.items[self.page(item)])].?[self.offset(self.dense.items[self.page(item)])] = @intCast(SparseT, i);
            }
        }

        /// Sort elements according to the given comparison function. Use this when a data array needs to stay in sync with the SparseSet
        /// by passing in a "swap_context" that contains a "swap" method with a sig of fn(ctx,SparseT,SparseT)void
        pub fn arrange(self: *Self, length: usize, context: anytype, comptime lessThan: fn (@TypeOf(context), SparseT, SparseT) bool, swap_context: anytype) void {
            std.sort.insertionSort(SparseT, self.dense.items[0..length], context, lessThan);

            for (self.dense.items[0..length]) |sparse, pos| {
                var curr = @intCast(SparseT, pos);
                var next = self.index(self.dense.items[curr]);

                while (curr != next) {
                    swap_context.swap(self.dense.items[curr], self.dense.items[next]);
                    self.sparse.items[self.page(self.dense.items[curr])].?[self.offset(self.dense.items[curr])] = curr;

                    curr = next;
                    next = self.index(self.dense.items[curr]);
                }
            }
        }

        /// Sort entities according to their order in another sparse set. Other is the master in this case.
        pub fn respect(self: *Self, other: *Self) void {
            var pos = @as(SparseT, 0);
            var i = @as(SparseT, 0);
            while (i < other.dense.items.len) : (i += 1) {
                if (self.contains(other.dense.items[i])) {
                    if (other.dense.items[i] != self.dense.items[pos]) {
                        self.swap(self.dense.items[pos], other.dense.items[i]);
                    }
                    pos += 1;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.sparse.expandToCapacity();
            for (self.sparse.items) |array, i| {
                if (array) |arr| {
                    self.sparse.allocator.free(arr);
                    self.sparse.items[i] = null;
                }
            }

            self.sparse.items.len = 0;
            self.dense.items.len = 0;
        }

        pub fn reverseIterator(self: *Self) ReverseSliceIterator(SparseT) {
            return ReverseSliceIterator(SparseT).init(self.dense.items);
        }
    };
}

fn printSet(set: *SparseSet(u32, u8)) void {
    std.debug.warn("\nsparse -----\n", .{});
    for (set.sparse.items) |sparse| {
        std.debug.warn("{}\t", .{sparse});
    }

    std.debug.warn("\ndense -----\n", .{});
    for (set.dense.items) |dense| {
        std.debug.warn("{}\t", .{dense});
    }
    std.debug.warn("\n\n", .{});
}

test "add/remove/clear" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(4);
    set.add(3);
    try std.testing.expectEqual(set.len(), 2);
    try std.testing.expectEqual(set.index(4), 0);
    try std.testing.expectEqual(set.index(3), 1);

    set.remove(4);
    try std.testing.expectEqual(set.len(), 1);

    set.clear();
    try std.testing.expectEqual(set.len(), 0);
}

test "grow" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    var i = @as(usize, std.math.maxInt(u8));
    while (i > 0) : (i -= 1) {
        set.add(@intCast(u32, i));
    }

    try std.testing.expectEqual(set.len(), std.math.maxInt(u8));
}

test "swap" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(4);
    set.add(3);
    try std.testing.expectEqual(set.index(4), 0);
    try std.testing.expectEqual(set.index(3), 1);

    set.swap(4, 3);
    try std.testing.expectEqual(set.index(3), 0);
    try std.testing.expectEqual(set.index(4), 1);
}

test "data() synced" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(0);
    set.add(1);
    set.add(2);
    set.add(3);

    var data = set.data();
    try std.testing.expectEqual(data[1], 1);
    try std.testing.expectEqual(set.len(), data.len);

    set.remove(0);
    set.remove(1);
    try std.testing.expectEqual(set.len(), set.data().len);
}

test "iterate" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(0);
    set.add(1);
    set.add(2);
    set.add(3);

    var i: u32 = @intCast(u32, set.len()) - 1;
    var iter = set.reverseIterator();
    while (iter.next()) |entity| {
        try std.testing.expectEqual(i, entity);
        if (i > 0) i -= 1;
    }
}

test "respect 1" {
    var set1 = SparseSet(u32).initPtr(std.testing.allocator);
    defer set1.deinit();

    var set2 = SparseSet(u32).initPtr(std.testing.allocator);
    defer set2.deinit();

    set1.add(3);
    set1.add(4);
    set1.add(5);
    set1.add(6);
    set1.add(7);

    set2.add(8);
    set2.add(6);
    set2.add(4);

    set1.respect(set2);

    try std.testing.expectEqual(set1.dense.items[0], set2.dense.items[1]);
    try std.testing.expectEqual(set1.dense.items[1], set2.dense.items[2]);
}

const desc_u32 = std.sort.desc(u32);

test "respect 2" {
    var set = SparseSet(u32).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(5);
    set.add(2);
    set.add(4);
    set.add(1);
    set.add(3);

    set.sort({}, desc_u32);

    for (set.dense.items) |item, i| {
        if (i < set.dense.items.len - 1) {
            std.debug.assert(item > set.dense.items[i + 1]);
        }
    }
}
