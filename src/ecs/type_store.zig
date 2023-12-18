const std = @import("std");
const utils = @import("utils.zig");

/// stores a single object of type T for each T added
pub const TypeStore = struct {
    map: std.AutoHashMap(u32, []u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return TypeStore{
            .map = std.AutoHashMap(u32, []u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeStore) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |val_ptr| {
            self.allocator.free(val_ptr.*);
        }
        self.map.deinit();
    }

    /// adds instance, returning a pointer to the item as it lives in the store
    pub fn add(self: *TypeStore, instance: anytype) void {
        const bytes = self.allocator.alloc(u8, @sizeOf(@TypeOf(instance))) catch unreachable;
        @memcpy(bytes, std.mem.asBytes(&instance));
        _ = self.map.put(utils.typeId(@TypeOf(instance)), bytes) catch unreachable;
    }

    pub fn get(self: *TypeStore, comptime T: type) *T {
        if (self.map.get(utils.typeId(T))) |bytes| {
            return @as(*T, @ptrCast(@alignCast(bytes)));
        }
        unreachable;
    }

    pub fn getConst(self: *TypeStore, comptime T: type) T {
        return self.get(T).*;
    }

    pub fn getOrAdd(self: *TypeStore, comptime T: type) *T {
        if (!self.has(T)) {
            const instance = std.mem.zeroes(T);
            self.add(instance);
        }
        return self.get(T);
    }

    pub fn remove(self: *TypeStore, comptime T: type) void {
        if (self.map.get(utils.typeId(T))) |bytes| {
            self.allocator.free(bytes);
            _ = self.map.remove(utils.typeId(T));
        }
    }

    pub fn has(self: *TypeStore, comptime T: type) bool {
        return self.map.contains(utils.typeId(T));
    }
};

test "TypeStore" {
    const Vector = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };

    var store = TypeStore.init(std.testing.allocator);
    defer store.deinit();

    const orig = Vector{ .x = 5, .y = 6, .z = 8 };
    store.add(orig);
    try std.testing.expect(store.has(Vector));
    try std.testing.expectEqual(store.get(Vector).*, orig);

    const v = store.get(Vector);
    try std.testing.expectEqual(v.*, Vector{ .x = 5, .y = 6, .z = 8 });
    v.*.x = 666;

    const v2 = store.get(Vector);
    try std.testing.expectEqual(v2.*, Vector{ .x = 666, .y = 6, .z = 8 });

    store.remove(Vector);
    try std.testing.expect(!store.has(Vector));

    const v3 = store.getOrAdd(u32);
    try std.testing.expectEqual(v3.*, 0);
    v3.* = 777;

    _ = store.get(u32);
    try std.testing.expectEqual(v3.*, 777);
}
