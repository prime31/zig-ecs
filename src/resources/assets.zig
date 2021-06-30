const std = @import("std");
const utils = @import("../ecs/utils.zig");
const Cache = @import("cache.zig").Cache;

pub const Assets = struct {
    caches: std.AutoHashMap(u32, usize),
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator) Assets {
        return Assets{
            .caches = std.AutoHashMap(u32, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Assets) void {
        var iter = self.caches.iterator();
        while (iter.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            @intToPtr(*Cache(u1), ptr.value_ptr.*).deinit();
        }

        self.caches.deinit();
    }

    pub fn get(self: *Assets, comptime AssetT: type) *Cache(AssetT) {
        if (self.caches.get(utils.typeId(AssetT))) |tid| {
            return @intToPtr(*Cache(AssetT), tid);
        }

        var cache = Cache(AssetT).initPtr(self.allocator);
        _ = self.caches.put(utils.typeId(AssetT), @ptrToInt(cache)) catch unreachable;
        return cache;
    }

    pub fn load(self: *Assets, id: u16, comptime loader: anytype) ReturnType(loader, false) {
        return self.get(ReturnType(loader, true)).load(id, loader);
    }

    fn ReturnType(comptime loader: anytype, strip_ptr: bool) type {
        var ret = @typeInfo(@TypeOf(@field(loader, "load"))).BoundFn.return_type.?;
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
        pub fn load(self: @This()) *OtherThing {
            return std.testing.allocator.create(OtherThing) catch unreachable;
        }
    };

    const ThingLoadArgs = struct {
        pub fn load(self: @This()) *Thing {
            return std.testing.allocator.create(Thing) catch unreachable;
        }
    };

    var assets = Assets.init(std.testing.allocator);
    defer assets.deinit();

    var thing = assets.get(Thing).load(6, ThingLoadArgs{});
    try std.testing.expectEqual(assets.get(Thing).size(), 1);

    var thing2 = assets.load(4, ThingLoadArgs{});
    try std.testing.expectEqual(assets.get(Thing).size(), 2);

    var other_thing = assets.get(OtherThing).load(6, OtherThingLoadArgs{});
    try std.testing.expectEqual(assets.get(OtherThing).size(), 1);

    var other_thing2 = assets.load(8, OtherThingLoadArgs{});
    try std.testing.expectEqual(assets.get(OtherThing).size(), 2);

    assets.get(OtherThing).clear();
    try std.testing.expectEqual(assets.get(OtherThing).size(), 0);
}
