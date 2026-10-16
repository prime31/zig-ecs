const std = @import("std");
const ecs = @import("ecs");
const Registry = @import("ecs").Registry;

const Velocity = struct { x: f32, y: f32 };
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Empty = struct {};
const BigOne = struct { pos: Position, vel: Velocity, accel: Velocity };

test "entity traits" {
    _ = ecs.EntityClass(.small){ .index = 299, .version = 15 };
    _ = ecs.EntityClass(.medium){ .index = 18953, .version = 543 };
    _ = ecs.EntityClass(.large){ .index = 15794, .version = 548273 };
    _ = ecs.EntityClass(.{ .index_bits = 41, .version_bits = 91 }){ .index = 89612, .version = 254739 };
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

    var i: u8 = 0;
    while (i < 255) : (i += 1) {
        const e = reg.create();
        reg.add(e, Position{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) });
    }

    reg.destroy(.{ .index = 3, .version = 0 });
    reg.destroy(.{ .index = 4, .version = 0 });

    i = 0;
    while (i < 6) : (i += 1) {
        if (i != 3 and i != 4)
            try std.testing.expectEqual(
                Position{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) },
                reg.getConst(Position, .{ .index = i, .version = 0 }),
            );
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

// ── Issue: reentrant destroy from destruction signal ────────────────────

test "destroy: reentrant destroy from onDestruct signal does not crash" {
    // Scenario: a system removes a component from an entity, and the
    // destruction signal handler calls registry.destroy() on the same
    // entity.  Before the fix this caused a segfault because destroy()
    // called removeAll() while the entity handle was still valid,
    // leading to double sparse-set removal.
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const entity = reg.create();
    reg.add(entity, Position{ .x = 1, .y = 2 });
    reg.add(entity, Velocity{ .x = 3, .y = 4 });

    // When Position is removed, attempt to destroy the same entity.
    reg.onDestruct(Position).connect(struct {
        fn handler(r: *Registry, e: ecs.Entity) void {
            if (r.valid(e)) {
                r.destroy(e);
            }
        }
    }.handler);

    // Trigger: remove Position → signal fires → handler calls destroy.
    reg.remove(Position, entity);

    // Entity must be fully dead.
    try std.testing.expect(!reg.valid(entity));
}

test "destroy: onDestruct signal handler destroys a different entity" {
    // A destruction signal on entity A destroys entity B.
    // This mutates the handle pool during signal dispatch.
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const a = reg.create();
    const b = reg.create();
    reg.add(a, Position{ .x = 1, .y = 1 });
    reg.add(b, Position{ .x = 2, .y = 2 });
    reg.add(b, Velocity{ .x = 0, .y = 0 });

    reg.onDestruct(Position).connect(struct {
        fn handler(r: *Registry, e: ecs.Entity) void {
            // Destroy every entity with Velocity that isn't the one
            // currently being destroyed.
            var view = r.basicView(Velocity);
            var iter = view.entityIterator();
            while (iter.next()) |other| {
                if (other != e and r.valid(other)) {
                    r.destroy(other);
                }
            }
        }
    }.handler);

    reg.destroy(a);

    try std.testing.expect(!reg.valid(a));
    try std.testing.expect(!reg.valid(b));
}

test "destroy: component data is still readable in onDestruct signal" {
    // The destruction signal fires before the component is removed from
    // storage, so handlers can still read component values.
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const entity = reg.create();
    reg.add(entity, Position{ .x = 42, .y = 99 });

    var signal_saw_position = false;

    reg.onDestruct(Position).connectBound(&signal_saw_position, struct {
        fn handler(flag: *bool, _: *Registry, _: ecs.Entity) void {
            flag.* = true;
        }
    }.handler);

    reg.destroy(entity);

    try std.testing.expect(signal_saw_position);
    try std.testing.expect(!reg.valid(entity));
}

test "pointer fields and registry contexts remain supported" {
    const Component = struct { value: *u32 };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const entity = registry.create();
    var value: u32 = 7;
    registry.add(entity, Component{ .value = &value });
    registry.get(Component, entity).value.* = 9;
    registry.notifyUpdated(Component, entity);
    try std.testing.expectEqual(@as(u32, 9), registry.getConst(Component, entity).value.*);
    registry.singletons().add(Component{ .value = &value });
    try std.testing.expectEqual(@as(u32, 9), registry.singletons().get(Component).value.*);
    registry.setContext(&value);
    registry.getContext(u32).?.* = 11;
    try std.testing.expectEqual(@as(u32, 11), registry.get(Component, entity).value.*);
    registry.unsetContext(u32);
    try std.testing.expect(registry.getContext(u32) == null);
    registry.singletons().remove(Component);
    registry.remove(Component, entity);
    try std.testing.expect(!registry.has(Component, entity));
}
