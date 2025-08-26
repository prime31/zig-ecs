const std = @import("std");
const registry = @import("registry.zig");

/// generates versioned "handles" (https://floooh.github.io/2018/06/17/handles-vs-pointers.html)
/// you choose the type of the handle (aka its size) and how much of that goes to the index and the version.
/// the bitsize of version + id must equal the handle size.
pub fn Handles(comptime HandleType: type) type {
    return struct {
        const Self = @This();

        handles: []HandleType,
        /// When creating a new entity, if there are no free slots (indicated by last_destroyed being null),
        /// create a new entity at this index
        append_cursor: HandleType.Index = 0,
        /// A linked list of unused slots
        /// This field points to the index of the latest freed slot
        /// The index of the next free slot is stored in the `index` field of the handle
        free_slot: ?HandleType.Index = null,
        allocator: std.mem.Allocator,

        pub const max_active_entities = std.math.maxInt(HandleType.Index);
        const invalid_id = std.math.maxInt(HandleType.Index);

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
            return .{
                .handles = allocator.alloc(HandleType, capacity) catch unreachable,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.handles);
        }

        pub fn create(self: *Self) !HandleType {
            // we have a free slot, consume it
            if (self.free_slot) |free_index| {
                const version = self.handles[free_index].version;
                // the index of the next free slot
                const next_free_index = self.handles[free_index].index;

                const handle: HandleType = .{ .index = free_index, .version = version };
                self.handles[free_index] = handle;

                // set the head of our linked list to point at the next free index
                self.free_slot = if (next_free_index == invalid_id) null else next_free_index;

                return handle;
            }

            // we have no free slots, so append to the end of array

            // we are out of handles that can be active at once
            if (self.append_cursor == invalid_id) return error.OutOfActiveHandles;

            // ensure capacity and grow if needed
            if (self.handles.len - 1 == self.append_cursor) {
                self.handles = self.allocator.realloc(self.handles, @min(max_active_entities, self.handles.len * 2)) catch unreachable;
            }

            const handle: HandleType = .{ .index = @intCast(self.append_cursor), .version = 0 };
            self.handles[self.append_cursor] = handle;

            self.append_cursor += 1;
            return handle;
        }

        pub fn remove(self: *Self, handle: HandleType) !void {
            const index = handle.index;
            if (!self.alive(handle)) return error.RemovedInvalidHandle;

            // point entry at next free slot
            // TODO: Do not allow overflow, permanently retire entity instead
            self.handles[index] = .{ .index = self.free_slot orelse invalid_id, .version = handle.version +% 1 };

            self.free_slot = index;
        }

        pub fn alive(self: Self, handle: HandleType) bool {
            return
            // we couldn't possibly have allocated this handle yet
            handle.index < self.append_cursor and
                // when we hand out a... handle, we always set the corresponding slot in the array to the handle
                // when we free it, we use the handle's index field as a index to the next free slot (or maxInt
                // if no other free slots exist), so double-frees are always caught
                self.handles[handle.index] == handle;
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator.init(self);
        }
    };
}

test "handles" {
    const entity = @import("entity.zig");

    var handles: Handles(entity.EntityClass(.{
        .index_bits = 4,
        .version_bits = 4,
    })) = .init(std.testing.allocator);
    defer handles.deinit();

    const e0 = try handles.create();
    const e1 = try handles.create();
    const e2 = try handles.create();

    std.debug.assert(handles.alive(e0));
    std.debug.assert(handles.alive(e1));
    std.debug.assert(handles.alive(e2));

    handles.remove(e1) catch unreachable;
    std.debug.assert(!handles.alive(e1));

    try std.testing.expectError(error.RemovedInvalidHandle, handles.remove(e1));

    var e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    handles.remove(e_tmp) catch unreachable;
    std.debug.assert(!handles.alive(e_tmp));

    handles.remove(e0) catch unreachable;
    std.debug.assert(!handles.alive(e0));

    handles.remove(e2) catch unreachable;
    std.debug.assert(!handles.alive(e2));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));

    e_tmp = try handles.create();
    std.debug.assert(handles.alive(e_tmp));
}
