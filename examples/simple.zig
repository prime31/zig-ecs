const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const EntityTraits = ecs.EntityTraitsType(.small);

pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };

pub fn main() !void {
    var reg = ecs.Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e1 = reg.create();
    reg.add(e1, Position{ .x = 0, .y = 0 });
    reg.add(e1, Velocity{ .x = 5, .y = 7 });

    var e2 = reg.create();
    reg.add(e2, Position{ .x = 10, .y = 10 });
    reg.add(e2, Velocity{ .x = 15, .y = 17 });

    var view = reg.view(.{Velocity, Position});

    var iter = view.iterator();
    while (iter.next()) |entity| {
        var pos = view.get(Position, entity);
        const vel = view.getConst(Velocity, entity);
        std.debug.warn("entity: {}, pos: {d}, vel: {d}\n", .{entity, pos.*, vel});
        pos.*.x += vel.x;
        pos.*.y += vel.y;
    }

    std.debug.warn("---- resetting iter\n", .{});

    iter.reset();
    while (iter.next()) |entity| {
        const pos = view.getConst(Position, entity);
        const vel = view.getConst(Velocity, entity);
        std.debug.warn("entity: {}, pos: {d}, vel: {d}\n", .{entity, pos, vel});
    }
}