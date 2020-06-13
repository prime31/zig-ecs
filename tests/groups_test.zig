const std = @import("std");
const warn = std.debug.warn;
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

fn printStore(store: var, name: []const u8) void {
    warn("--- {} ---\n", .{name});
    for (store.set.dense.items) |e, i| {
        warn("e[{}] s[{}]{}", .{ e, store.set.page(store.set.dense.items[i]), store.set.sparse.items[store.set.page(store.set.dense.items[i])] });
        warn(" ({d:.2})   ", .{store.instances.items[i]});
    }
    warn("\n", .{});
}

test "sort BasicGroup by Entity" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ Sprite, Renderable }, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var e = reg.create();
        reg.add(e, Sprite{ .x = @intToFloat(f32, i) });
        reg.add(e, Renderable{ .x = @intToFloat(f32, i) });
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
        std.testing.expectEqual(val, group.getConst(Sprite, entity).x);
        val += 1;
    }
}

test "sort BasicGroup by Component" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{}, .{ Sprite, Renderable }, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var e = reg.create();
        reg.add(e, Sprite{ .x = @intToFloat(f32, i) });
        reg.add(e, Renderable{ .x = @intToFloat(f32, i) });
    }

    const SortContext = struct {
        fn sort(this: void, a: Sprite, b: Sprite) bool {
            return a.x > b.x;
        }
    };
    group.sort(Sprite, {}, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator();
    while (iter.next()) |entity| {
        std.testing.expectEqual(val, group.getConst(Sprite, entity).x);
        val += 1;
    }
}

test "sort OwningGroup by Entity" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ Sprite, Renderable }, .{}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var e = reg.create();
        reg.add(e, Sprite{ .x = @intToFloat(f32, i) });
        reg.add(e, Renderable{ .x = @intToFloat(f32, i) });
    }

    const SortContext = struct {
        group: OwningGroup,

        fn sort(this: @This(), a: ecs.Entity, b: ecs.Entity) bool {
            const sprite_a = this.group.getConst(Sprite, a);
            const sprite_b = this.group.getConst(Sprite, b);
            return sprite_a.x > sprite_b.x;
        }
    };
    const context = SortContext{.group = group};
    group.sort(ecs.Entity, context, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator(struct {s: *Sprite, r: *Renderable});
    while (iter.next()) |entity| {
        std.testing.expectEqual(val, entity.s.*.x);
        val += 1;
    }
}

test "sort OwningGroup by Component" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group = reg.group(.{ Sprite, Renderable }, .{}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var e = reg.create();
        reg.add(e, Sprite{ .x = @intToFloat(f32, i) });
        reg.add(e, Renderable{ .x = @intToFloat(f32, i) });
    }

    const SortContext = struct {
        fn sort(this: void, a: Sprite, b: Sprite) bool {
            return a.x > b.x;
        }
    };
    group.sort(Sprite, {}, SortContext.sort);

    var val: f32 = 0;
    var iter = group.iterator(struct {s: *Sprite, r: *Renderable});
    while (iter.next()) |entity| {
        std.testing.expectEqual(val, entity.s.*.x);
        val += 1;
    }
}

test "nested OwningGroups add/remove components" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group1 = reg.group(.{Sprite}, .{Renderable}, .{});
    var group2 = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});
    var group3 = reg.group(.{ Sprite, Transform }, .{ Renderable, Rotation }, .{});

    std.testing.expect(!reg.sortable(Sprite));
    std.testing.expect(!reg.sortable(Transform));
    std.testing.expect(reg.sortable(Renderable));

    var e1 = reg.create();
    reg.addTypes(e1, .{ Sprite, Renderable, Rotation });
    std.testing.expectEqual(group1.len(), 1);
    std.testing.expectEqual(group2.len(), 0);
    std.testing.expectEqual(group3.len(), 0);

    reg.add(e1, Transform{});
    std.testing.expectEqual(group3.len(), 1);

    reg.remove(Sprite, e1);
    std.testing.expectEqual(group1.len(), 0);
    std.testing.expectEqual(group2.len(), 0);
    std.testing.expectEqual(group3.len(), 0);
}

test "nested OwningGroups entity order" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var group1 = reg.group(.{Sprite}, .{Renderable}, .{});
    var group2 = reg.group(.{ Sprite, Transform }, .{Renderable}, .{});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var e = reg.create();
        reg.add(e, Sprite{ .x = @intToFloat(f32, i) });
        reg.add(e, Renderable{ .x = @intToFloat(f32, i) });
    }

    std.testing.expectEqual(group1.len(), 5);
    std.testing.expectEqual(group2.len(), 0);

    var sprite_store = reg.assure(Sprite);
    var transform_store = reg.assure(Transform);
    // printStore(sprite_store, "Sprite");

    reg.add(1, Transform{ .x = 1 });

    // printStore(sprite_store, "Sprite");
    // printStore(transform_store, "Transform");
    // warn("group2.current: {}\n", .{group2.group_data.current});
}
