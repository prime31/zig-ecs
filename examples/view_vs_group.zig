const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const EntityTraits = ecs.EntityTraitsType(.medium);

pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };

/// logs the timing for views vs groups with 1,000,000 entities
pub fn main() !void {
    var reg = ecs.Registry.init(std.heap.c_allocator);
    defer reg.deinit();

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 1000000) : (i += 1) {
        var e1 = reg.create();
        reg.add(e1, Position{ .x = 1, .y = 1 });
        reg.add(e1, Velocity{ .x = 1, .y = 1 });
    }
    var end = timer.lap();
    std.debug.warn("create: \t{d}\n", .{@intToFloat(f64, end) / 1000000000});

    var view = reg.view(.{ Velocity, Position }, .{});

    timer.reset();
    var iter = view.iterator();
    while (iter.next()) |entity| {
        var pos = view.get(Position, entity);
        const vel = view.getConst(Velocity, entity);

        pos.*.x += vel.x;
        pos.*.y += vel.y;
    }

    end = timer.lap();
    std.debug.warn("view (iter): \t{d}\n", .{@intToFloat(f64, end) / 1000000000});

    var group = reg.group(.{ Velocity, Position }, .{}, .{});
    end = timer.lap();
    std.debug.warn("group (create): {d}\n", .{@intToFloat(f64, end) / 1000000000});

    timer.reset();
    var group_iter = group.iterator(struct { vel: *Velocity, pos: *Position });
    while (group_iter.next()) |e| {
        e.pos.*.x += e.vel.x;
        e.pos.*.y += e.vel.y;
    }

    end = timer.lap();
    std.debug.warn("group (iter): \t{d}\n", .{@intToFloat(f64, end) / 1000000000});

    timer.reset();
    group.each(each);
    end = timer.read();
    std.debug.warn("group (each): \t{d}\n", .{@intToFloat(f64, end) / 1000000000});
}

fn each(e: struct { vel: *Velocity, pos: *Position }) void {
    e.pos.*.x += e.vel.x;
    e.pos.*.y += e.vel.y;
}
