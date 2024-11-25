const std = @import("std");
const utils = @import("../ecs/utils.zig");
const Cache = @import("cache.zig").Cache;

pub const Assets = struct {
    caches: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Assets {
        return Assets{
            .caches = std.AutoHashMap(u32, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Assets) void {
        var iter = self.caches.iterator();
        while (iter.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            @as(*Cache(u1), @ptrFromInt(ptr.value_ptr.*)).deinit();
        }

        self.caches.deinit();
    }

    pub fn get(self: *Assets, comptime AssetT: type) *Cache(AssetT) {
        if (self.caches.get(utils.typeId(AssetT))) |tid| {
            return @as(*Cache(AssetT), @ptrFromInt(tid));
        }

        const cache = Cache(AssetT).initPtr(self.allocator);
        _ = self.caches.put(utils.typeId(AssetT), @intFromPtr(cache)) catch unreachable;
        return cache;
    }

    pub fn load(self: *Assets, id: u16, comptime loader: anytype) ReturnType(loader, false) {
        return self.get(ReturnType(loader, true)).load(id, loader);
    }

    fn ReturnType(comptime loader: anytype, comptime strip_ptr: bool) type {
        const ret = @typeInfo(@typeInfo(@TypeOf(@field(loader, "load"))).pointer.child).@"fn".return_type.?;
        if (strip_ptr) {
            return std.meta.Child(ret);
        }
        return ret;
    }
};

test "assets" {
    const Thing = struct {
        fart: i32,
        pub fn deinit(self: *@This()) void {
            std.testing.allocator.destroy(self);
        }
    };

    const OtherThing = struct {
        fart: i32,
        pub fn deinit(self: *@This()) void {
            std.testing.allocator.destroy(self);
        }
    };

    const OtherThingLoadArgs = struct {
        // Use actual field "load" as function pointer to avoid zig v0.10.0
        // compiler error: "error: no field named 'load' in struct '...'"
        load: *const fn (_: @This()) *OtherThing,
        pub fn loadFn(_: @This()) *OtherThing {
            return std.testing.allocator.create(OtherThing) catch unreachable;
        }
    };

    const ThingLoadArgs = struct {
        // Use actual field "load" as function pointer to avoid zig v0.10.0
        // compiler error: "error: no field named 'load' in struct '...'"
        load: *const fn (_: @This()) *Thing,
        pub fn loadFn(_: @This()) *Thing {
            return std.testing.allocator.create(Thing) catch unreachable;
        }
    };

    var assets = Assets.init(std.testing.allocator);
    defer assets.deinit();

    _ = assets.get(Thing).load(6, ThingLoadArgs{ .load = ThingLoadArgs.loadFn });
    try std.testing.expectEqual(assets.get(Thing).size(), 1);

    _ = assets.load(4, ThingLoadArgs{ .load = ThingLoadArgs.loadFn });
    try std.testing.expectEqual(assets.get(Thing).size(), 2);

    _ = assets.get(OtherThing).load(6, OtherThingLoadArgs{ .load = OtherThingLoadArgs.loadFn });
    try std.testing.expectEqual(assets.get(OtherThing).size(), 1);

    _ = assets.load(8, OtherThingLoadArgs{ .load = OtherThingLoadArgs.loadFn });
    try std.testing.expectEqual(assets.get(OtherThing).size(), 2);

    assets.get(OtherThing).clear();
    try std.testing.expectEqual(assets.get(OtherThing).size(), 0);
}
