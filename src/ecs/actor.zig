const std = @import("std");
const Registry = @import("registry.zig").Registry;
const Entity = @import("registry.zig").Entity;

pub const Actor = struct {
    registry: *Registry,
    entity: Entity = undefined,

    pub fn init(registry: *Registry) Actor {
        var reg = registry;
        return .{
            .registry = registry,
            .entity = reg.create(),
        };
    }

    pub fn deinit(self: *Actor) void {
        self.registry.destroy(self.entity);
    }

    pub fn add(self: *Actor, value: anytype) void {
        self.registry.add(self.entity, value);
    }

    pub fn addTyped(self: *Actor, comptime T: type, value: T) void {
        self.registry.addTyped(T, self.entity, value);
    }

    pub fn remove(self: *Actor, comptime T: type) void {
        self.registry.remove(T, self.entity);
    }

    pub fn has(self: *Actor, comptime T: type) bool {
        return self.registry.has(T, self.entity);
    }

    pub fn get(self: *Actor, comptime T: type) *T {
        return self.registry.get(T, self.entity);
    }

    pub fn tryGet(self: *Actor, comptime T: type) ?*T {
        return self.registry.tryGet(T, self.entity);
    }
};

test "actor" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var actor = Actor.init(&reg);
    defer actor.deinit();

    std.debug.assert(!actor.has(f32));
    actor.addTyped(f32, 67.45);
    if (actor.tryGet(f32)) |val| {
        try std.testing.expectEqual(val.*, 67.45);
    }

    actor.addTyped(u64, 8888);
    try std.testing.expectEqual(actor.get(u64).*, 8888);
    std.debug.assert(actor.has(u64));

    actor.remove(u64);
    std.debug.assert(!actor.has(u64));
}

test "actor structs" {
    const Velocity = struct { x: f32, y: f32 };
    const Position = struct { x: f32 = 0, y: f32 = 0 };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var actor = Actor.init(&reg);
    defer actor.deinit();

    actor.add(Velocity{ .x = 5, .y = 10 });
    actor.add(Position{});

    const vel = actor.get(Velocity);
    const pos = actor.get(Position);

    pos.*.x += vel.x;
    pos.*.y += vel.y;

    try std.testing.expectEqual(actor.get(Position).*.x, 5);
    try std.testing.expectEqual(actor.get(Position).*.y, 10);
}
