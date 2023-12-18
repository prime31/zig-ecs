const std = @import("std");
const ecs = @import("ecs");
const Registry = @import("ecs").Registry;
const BasicGroup = @import("ecs").BasicGroup;
const OwningGroup = @import("ecs").OwningGroup;

const Velocity = struct { x: f32 = 0, y: f32 = 0 };
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Empty = struct {};
const Sprite = struct { x: f32 = 0 };
const Transform = struct { x: f32 = 0 };
const Renderable = struct { x: f32 = 0 };
const Rotation = struct { x: f32 = 0 };

fn printStore(store: anytype, name: []const u8) void {
    std.debug.print("--- {} ---\n", .{name});
    for (store.set.dense.items, 0..) |e, i| {
        std.debug.print("e[{}] s[{}]{}", .{ e, store.set.page(store.set.dense.items[i]), store.set.sparse.items[store.set.page(store.set.dense.items[i])] });
        std.debug.print(" ({d:.2})   ", .{store.instances.items[i]});
    }
    std.debug.print("\n", .{});
}

test "sort BasicGroup by Entity" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ Sprite, Renderable }, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });
    }

    const SortContext = struct {
        group: BasicGroup,

        fn sort(this: *@This(), a: ecs.Entity, b: ecs.Entity) bool {
            const real_a = this.group.getConst(Sprite, a);
            const real_b = this.group.getConst(Sprite, b);
            return real_a.x > real_b.x;
        }
    };

    var context = SortContext{ .group = group };
    group.sort(ecs.Entity, &context, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator();
    while (iter.next()) |entity| {
        try std.testing.expectEqual(val, group.getConst(Sprite, entity).x);
        val += 1;
    }
}

test "sort BasicGroup by Component" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ Sprite, Renderable }, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });
    }

    const SortContext = struct {
        fn sort(_: void, a: Sprite, b: Sprite) bool {
            return a.x > b.x;
        }
    };
    group.sort(Sprite, {}, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator();
    while (iter.next()) |entity| {
        try std.testing.expectEqual(val, group.getConst(Sprite, entity).x);
        val += 1;
    }
}

test "sort OwningGroup by Entity" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ Sprite, Renderable }, .{}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });
    }

    const SortContext = struct {
        group: OwningGroup,

        fn sort(this: @This(), a: ecs.Entity, b: ecs.Entity) bool {
            const sprite_a = this.group.getConst(Sprite, a);
            const sprite_b = this.group.getConst(Sprite, b);
            return sprite_a.x > sprite_b.x;
        }
    };
    const context = SortContext{ .group = group };
    group.sort(ecs.Entity, context, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator(struct { s: *Sprite, r: *Renderable });
    while (iter.next()) |entity| {
        try std.testing.expectEqual(val, entity.s.*.x);
        val += 1;
    }
}

test "sort OwningGroup by Component" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ Sprite, Renderable }, .{}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });
    }

    const SortContext = struct {
        fn sort(_: void, a: Sprite, b: Sprite) bool {
            return a.x > b.x;
        }
    };
    group.sort(Sprite, {}, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator(struct { s: *Sprite, r: *Renderable });
    while (iter.next()) |entity| {
        try std.testing.expectEqual(val, entity.s.*.x);
        val += 1;
    }
}

test "sort OwningGroup by Component ensure unsorted non-matches" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ Sprite, Renderable }, .{}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });

        const e2 = reg.create();
        reg.add(e2, Sprite{ .x = @as(f32, @floatFromInt(i + 1 * 50)) });
    }

    try std.testing.expectEqual(group.len(), 5);
    try std.testing.expectEqual(reg.len(Sprite), 10);

    const SortContext = struct {
        fn sort(_: void, a: Sprite, b: Sprite) bool {
            // sprites with x > 50 shouldnt match in the group
            std.testing.expect(a.x < 50 and b.x < 50) catch unreachable;
            return a.x > b.x;
        }
    };
    group.sort(Sprite, {}, SortContext.sort);

    // all the
    var view = reg.view(.{Sprite}, .{});
    var count: usize = 0;
    var iter = view.iterator();
    while (iter.next()) |sprite| {
        count += 1;

        // all sprite.x > 50 should be at the end and we iterate backwards
        if (count < 6) {
            try std.testing.expect(sprite.x >= 50);
        }
    }
}

test "nested OwningGroups add/remove components" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group1 = reg.group(.{Sprite}, .{Renderable}, .{});
    var group2 = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});
    var group3 = reg.group(.{ Sprite, Transform }, .{ Renderable, Rotation }, .{});

    try std.testing.expect(!reg.sortable(Sprite));
    try std.testing.expect(!reg.sortable(Transform));
    try std.testing.expect(reg.sortable(Renderable));

    const e1 = reg.create();
    reg.addTypes(e1, .{ Sprite, Renderable, Rotation });
    try std.testing.expectEqual(group1.len(), 1);
    try std.testing.expectEqual(group2.len(), 0);
    try std.testing.expectEqual(group3.len(), 0);

    reg.add(e1, Transform{});
    try std.testing.expectEqual(group3.len(), 1);

    reg.remove(Sprite, e1);
    try std.testing.expectEqual(group1.len(), 0);
    try std.testing.expectEqual(group2.len(), 0);
    try std.testing.expectEqual(group3.len(), 0);
}

test "nested OwningGroups entity order" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group1 = reg.group(.{Sprite}, .{Renderable}, .{});
    var group2 = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = reg.create();
        reg.add(e, Sprite{ .x = @as(f32, @floatFromInt(i)) });
        reg.add(e, Renderable{ .x = @as(f32, @floatFromInt(i)) });
    }

    try std.testing.expectEqual(group1.len(), 5);
    try std.testing.expectEqual(group2.len(), 0);

    _ = reg.assure(Sprite);
    _ = reg.assure(Transform);
    // printStore(sprite_store, "Sprite");

    reg.add(1, Transform{ .x = 1 });

    // printStore(sprite_store, "Sprite");
    // printStore(transform_store, "Transform");
    // std.debug.print("group2.current: {}\n", .{group2.group_data.current});
}
