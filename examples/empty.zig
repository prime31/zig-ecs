const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const EntityTraits = ecs.EntityTraitsType(.medium);

pub const Empty = struct {};
pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };

/// logs the timing for views vs non-owning groups vs owning groups with 1,000,000 entities
pub fn main() !void {
    var reg = ecs.Registry.init(std.heap.c_allocator);
    defer reg.deinit();

    const empty = reg.create();
    reg.addOrReplace(empty, Empty{});
    _ = reg.fetchRemove(Empty, empty);
    _ = reg.fetchReplace(empty, Empty{});
}
