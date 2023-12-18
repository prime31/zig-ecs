const std = @import("std");
const ecs = @import("ecs");
const Registry = @import("ecs").Registry;

const Velocity = struct { x: f32, y: f32 };
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Empty = struct {};
const BigOne = struct { pos: Position, vel: Velocity, accel: Velocity };

test "entity traits" {
    _ = ecs.EntityTraitsType(.large).init();
}

test "Registry" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e1 = reg.create();

    reg.addTypes(e1, .{ Empty, Position });
    reg.add(e1, BigOne{ .pos = Position{ .x = 5, .y = 5 }, .vel = Velocity{ .x = 5, .y = 5 }, .accel = Velocity{ .x = 5, .y = 5 } });

    try std.testing.expect(reg.has(Empty, e1));
    try std.testing.expect(reg.has(Position, e1));
    try std.testing.expect(reg.has(BigOne, e1));

    var iter = reg.entities();
    while (iter.next()) |e| try std.testing.expectEqual(e1, e);

    reg.remove(Empty, e1);
    try std.testing.expect(!reg.has(Empty, e1));
}

test "context get/set/unset" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(Position);
    try std.testing.expectEqual(ctx, null);

    var pos = Position{ .x = 5, .y = 5 };
    reg.setContext(&pos);
    ctx = reg.getContext(Position);
    try std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(Position);
    ctx = reg.getContext(Position);
    try std.testing.expectEqual(ctx, null);
}

// this test should fail
test "context not pointer" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const pos = Position{ .x = 5, .y = 5 };
    _ = pos;
    // reg.setContext(pos);
}

test "context get/set/unset typed" {
    const SomeType = struct { dummy: u1 };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(SomeType);
    try std.testing.expectEqual(ctx, null);

    var pos = SomeType{ .dummy = 0 };
    reg.setContext(&pos);
    ctx = reg.getContext(SomeType);
    try std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(SomeType);
    ctx = reg.getContext(SomeType);
    try std.testing.expectEqual(ctx, null);
}

test "singletons" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const pos = Position{ .x = 5, .y = 5 };
    reg.singletons().add(pos);
    try std.testing.expect(reg.singletons().has(Position));
    try std.testing.expectEqual(reg.singletons().get(Position).*, pos);

    reg.singletons().remove(Position);
    try std.testing.expect(!reg.singletons().has(Position));
}

test "destroy" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var i = @as(u8, 0);
    while (i < 255) : (i += 1) {
        const e = reg.create();
        reg.add(e, Position{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) });
    }

    reg.destroy(3);
    reg.destroy(4);

    i = 0;
    while (i < 6) : (i += 1) {
        if (i != 3 and i != 4)
            try std.testing.expectEqual(Position{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) }, reg.getConst(Position, i));
    }
}

test "remove all" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const e = reg.create();
    reg.add(e, Position{ .x = 1, .y = 1 });
    reg.addTyped(u32, e, 666);

    try std.testing.expect(reg.has(Position, e));
    try std.testing.expect(reg.has(u32, e));

    reg.removeAll(e);

    try std.testing.expect(!reg.has(Position, e));
    try std.testing.expect(!reg.has(u32, e));
}
