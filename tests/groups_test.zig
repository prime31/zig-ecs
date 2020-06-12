const std = @import("std");
const warn = std.debug.warn;
const ecs = @import("ecs");
const Registry = @import("ecs").Registry;

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
        warn("e[{}] s[{}]{}", .{e, store.set.page(store.set.dense.items[i]), store.set.sparse.items[store.set.page(store.set.dense.items[i])]});
        warn(" ({d:.2})   ", .{store.instances.items[i]});
    }
    warn("\n", .{});
}


test "sort component" {
    var store = ecs.ComponentStorage(f32, u32).initPtr(std.testing.allocator);
    defer store.deinit();

    store.add(22, @as(f32, 2.2));
    store.add(11, @as(f32, 1.1));
    store.add(33, @as(f32, 3.3));

    comptime const desc_u32 = std.sort.desc(f32);
    store.sort(f32, desc_u32);

    var compare: f32 = 5;
    for (store.raw()) |val, i| {
        std.testing.expect(compare > val);
        compare = val;
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

    reg.add(1, Transform{.x = 1});

    // printStore(sprite_store, "Sprite");
    // printStore(transform_store, "Transform");
    // warn("group2.current: {}\n", .{group2.group_data.current});
}
