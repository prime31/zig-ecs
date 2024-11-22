const std = @import("std");
const registry = @import("registry.zig");

/// generates versioned "handles" (https://floooh.github.io/2018/06/17/handles-vs-pointers.html)
/// you choose the type of the handle (aka its size) and how much of that goes to the index and the version.
/// the bitsize of version + id must equal the handle size.
pub fn Handles(comptime HandleType: type, comptime IndexType: type, comptime VersionType: type) type {
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(HandleType)) == HandleType);
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IndexType)) == IndexType);
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(VersionType)) == VersionType);

    if (@bitSizeOf(IndexType) + @bitSizeOf(VersionType) != @bitSizeOf(HandleType))
        @compileError("IndexType and VersionType must sum to HandleType's bit count");

    return struct {
        const Self = @This();

        handles: []HandleType,
        append_cursor: IndexType = 0,
        last_destroyed: ?IndexType = null,
        allocator: std.mem.Allocator,

        const invalid_id = std.math.maxInt(IndexType);

        pub const Iterator = struct {
            hm: Self,
            index: usize = 0,

            pub fn init(hm: Self) @This() {
                return .{ .hm = hm };
            }

            pub fn next(self: *@This()) ?HandleType {
                if (self.index == self.hm.append_cursor) return null;

                for (self.hm.handles[self.index..self.hm.append_cursor]) |h| {
                    self.index += 1;
                    if (self.hm.alive(h)) {
                        return h;
                    }
                }
                return null;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithCapacity(allocator, 32);
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return Self{
                .handles = allocator.alloc(HandleType, capacity) catch unreachable,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.handles);
        }

        pub fn extractId(_: Self, handle: HandleType) IndexType {
            return @as(IndexType, @truncate(handle & registry.entity_traits.entity_mask));
        }

        pub fn extractVersion(_: Self, handle: HandleType) VersionType {
            return @as(VersionType, @truncate(handle >> registry.entity_traits.entity_shift));
        }

        fn forge(id: IndexType, version: VersionType) HandleType {
            return id | @as(HandleType, version) << registry.entity_traits.entity_shift;
        }

        pub fn create(self: *Self) HandleType {
            if (self.last_destroyed == null) {
                // ensure capacity and grow if needed
                if (self.handles.len - 1 == self.append_cursor) {
                    self.handles = self.allocator.realloc(self.handles, self.handles.len * 2) catch unreachable;
                }

                const id = self.append_cursor;
                const handle = forge(self.append_cursor, 0);
                self.handles[id] = handle;

                self.append_cursor += 1;
                return handle;
            }

            const version = self.extractVersion(self.handles[self.last_destroyed.?]);
            const destroyed_id = self.extractId(self.handles[self.last_destroyed.?]);

            const handle = forge(self.last_destroyed.?, version);
            self.handles[self.last_destroyed.?] = handle;

            self.last_destroyed = if (destroyed_id == invalid_id) null else destroyed_id;

            return handle;
        }

        pub fn remove(self: *Self, handle: HandleType) !void {
            const id = self.extractId(handle);
            if (id > self.append_cursor or self.handles[id] != handle)
                return error.RemovedInvalidHandle;

            const next_id = self.last_destroyed orelse invalid_id;
            if (next_id == id) return error.ExhaustedEntityRemoval;

            const version = self.extractVersion(handle);
            self.handles[id] = forge(next_id, version +% 1);

            self.last_destroyed = id;
        }

        pub fn alive(self: Self, handle: HandleType) bool {
            const id = self.extractId(handle);
            return id < self.append_cursor and self.handles[id] == handle;
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator.init(self);
        }
    };
}

test "handles" {
    var hm = Handles(u32, u20, u12).init(std.testing.allocator);
    defer hm.deinit();

    const e0 = hm.create();
    const e1 = hm.create();
    const e2 = hm.create();

    std.debug.assert(hm.alive(e0));
    std.debug.assert(hm.alive(e1));
    std.debug.assert(hm.alive(e2));

    hm.remove(e1) catch unreachable;
    std.debug.assert(!hm.alive(e1));

    try std.testing.expectError(error.RemovedInvalidHandle, hm.remove(e1));

    var e_tmp = hm.create();
    std.debug.assert(hm.alive(e_tmp));

    hm.remove(e_tmp) catch unreachable;
    std.debug.assert(!hm.alive(e_tmp));

    hm.remove(e0) catch unreachable;
    std.debug.assert(!hm.alive(e0));

    hm.remove(e2) catch unreachable;
    std.debug.assert(!hm.alive(e2));

    e_tmp = hm.create();
    std.debug.assert(hm.alive(e_tmp));

    e_tmp = hm.create();
    std.debug.assert(hm.alive(e_tmp));

    e_tmp = hm.create();
    std.debug.assert(hm.alive(e_tmp));
}
