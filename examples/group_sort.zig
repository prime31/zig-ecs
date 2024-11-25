const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const EntityTraits = ecs.EntityTraitsType(.medium);

pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };

const total_entities: usize = 10000;

/// logs the timing for views vs non-owning groups vs owning groups with 1,000,000 entities
pub fn main() !void {
    var reg = ecs.Registry.init(std.heap.c_allocator);
    defer reg.deinit();

    createEntities(&reg);
    owningGroup(&reg);
}

fn createEntities(reg: *ecs.Registry) void {
    var r = std.Random.DefaultPrng.init(666);

    var timer = std.time.Timer.start() catch unreachable;
    var i: usize = 0;
    while (i < total_entities) : (i += 1) {
        const e1 = reg.create();
        reg.add(e1, Position{ .x = 1, .y = r.random().float(f32) * 100 });
        reg.add(e1, Velocity{ .x = 1, .y = r.random().float(f32) * 100 });
    }

    const end = timer.lap();
    std.debug.print("create {d} entities: {d}\n", .{ total_entities, @as(f64, @floatFromInt(end)) / 1000000000 });
}

fn owningGroup(reg: *ecs.Registry) void {
    var group = reg.group(.{ Velocity, Position }, .{}, .{});

    // var group_iter = group.iterator(struct { vel: *Velocity, pos: *Position });
    // while (group_iter.next()) |e| {
    //     std.debug.print("pos.y {d:.3}, ent: {}\n", .{e.pos.y, group_iter.entity()});
    // }

    const SortContext = struct {
        fn sort(_: void, a: Position, b: Position) bool {
            return a.y < b.y;
        }
    };

    var timer = std.time.Timer.start() catch unreachable;
    group.sort(Position, {}, SortContext.sort);
    var end = timer.lap();
    std.debug.print("group (sort): {d}\n", .{@as(f64, @floatFromInt(end)) / 1000000000});

    timer.reset();
    group.sort(Position, {}, SortContext.sort);
    end = timer.lap();
    std.debug.print("group (sort 2): {d}\n", .{@as(f64, @floatFromInt(end)) / 1000000000});

    // var group_iter2 = group.iterator(struct { vel: *Velocity, pos: *Position });
    // while (group_iter2.next()) |e| {
    //     std.debug.print("pos.y {d:.3}, ent: {}\n", .{e.pos.y, group_iter2.entity()});
    // }
}
