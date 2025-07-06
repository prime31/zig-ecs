const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const Entity = ecs.EntityClass(.medium);

pub const Empty = struct {};
pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };
pub const EmptyB = struct {};

const total_entities: usize = 10000;

/// logs the timing for views vs non-owning groups vs owning groups with 1,000,000 entities
pub fn main() !void {
    var reg = ecs.Registry.init(std.heap.c_allocator);
    defer reg.deinit();

    const empty = reg.create();
    reg.addOrReplace(empty, Empty{});
    _ = reg.fetchRemove(Empty, empty);
    _ = reg.fetchReplace(empty, Empty{});

    createEntities(&reg);
    owningGroup(&reg);
}

fn createEntities(reg: *ecs.Registry) void {
    var r = std.Random.DefaultPrng.init(666);

    var i: usize = 0;
    while (i < total_entities) : (i += 1) {
        const e1 = reg.create();
        reg.add(e1, Empty{});
        reg.add(e1, Position{ .x = 1, .y = r.random().float(f32) * 100 });
        reg.add(e1, Velocity{ .x = 1, .y = r.random().float(f32) * 100 });
        reg.add(e1, EmptyB{});
    }
}

fn owningGroup(reg: *ecs.Registry) void {
    var group = reg.group(.{ Empty, Velocity, Position, EmptyB }, .{}, .{});

    const SortContext = struct {
        fn sort(_: void, a: Position, b: Position) bool {
            return a.y < b.y;
        }
    };

    group.sort(Position, {}, SortContext.sort);
    group.sort(Position, {}, SortContext.sort);
}
