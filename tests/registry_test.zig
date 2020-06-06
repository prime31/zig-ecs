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

test "context get/set/unset" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx, null);

    var pos = Position{ .x = 5, .y = 5 };
    reg.setContext(&pos);
    ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(Position);
    ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx, null);
}

// this test should fail
test "context not pointer" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var pos = Position{ .x = 5, .y = 5 };
    // reg.setContext(pos);
}

test "context get/set/unset" {
    const SomeType = struct { dummy: u1 };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx, null);

    var pos = SomeType{ .dummy = 0 };
    reg.setContext(&pos);
    ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(SomeType);
    ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx, null);
}

test "singletons" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var pos = Position{ .x = 5, .y = 5 };
    var inserted = reg.singletons.add(pos);
    std.testing.expect(reg.singletons.has(Position));
    std.testing.expectEqual(inserted.*, pos);

    reg.singletons.remove(Position);
    std.testing.expect(!reg.singletons.has(Position));
}

test "destroy" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var i = @as(u8, 0);
    while (i < 255) : (i += 1) {
        const e = reg.create();
        reg.add(e, Position{ .x = @intToFloat(f32, i), .y = @intToFloat(f32, i) });
    }

    reg.destroy(3);
    reg.destroy(4);

    i = 0;
    while (i < 6) : (i += 1) {
        if (i != 3 and i != 4)
            std.testing.expectEqual(Position{ .x = @intToFloat(f32, i), .y = @intToFloat(f32, i) }, reg.getConst(Position, i));
    }
}

test "remove all" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e = reg.create();
    reg.add(e, Position{ .x = 1, .y = 1 });
    reg.addTyped(u32, e, 666);

    std.testing.expect(reg.has(Position, e));
    std.testing.expect(reg.has(u32, e));

    reg.removeAll(e);

    std.testing.expect(!reg.has(Position, e));
    std.testing.expect(!reg.has(u32, e));
}
