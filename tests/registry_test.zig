const std = @import("std");
const ecs = @import("ecs");
const Registry = @import("ecs").Registry;

const Velocity = struct { x: f32, y: f32 };
const Position = struct { x: f32, y: f32 };
const Empty = struct {};
const BigOne = struct { pos: Position, vel: Velocity, accel: Velocity };

test "entity traits" {
    const traits = ecs.EntityTraitsType(.large).init();
}

test "Registry" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e1 = reg.create();

    reg.add(e1, Empty{});
    reg.add(e1, Position{ .x = 5, .y = 5 });
    reg.add(e1, BigOne{ .pos = Position{ .x = 5, .y = 5 }, .vel = Velocity{ .x = 5, .y = 5 }, .accel = Velocity{ .x = 5, .y = 5 } });

    std.testing.expect(reg.has(Empty, e1));

    reg.remove(Empty, e1);
    std.testing.expect(!reg.has(Empty, e1));
}
