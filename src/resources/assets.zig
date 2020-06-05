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

    pub fn deinit(self: Assets) void {
        var it = self.caches.iterator();
        while (it.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            @intToPtr(*Cache(u1), ptr.value).deinit();
        }

        self.caches.deinit();
    }

    pub fn registerCache(self: *Assets, comptime AssetT: type, comptime LoaderT: type) *Cache(AssetT) {
        var cache = Cache(AssetT).initPtr(self.allocator, LoaderT);
        _ = self.caches.put(utils.typeId(AssetT), @ptrToInt(cache)) catch unreachable;
        return cache;
    }

    pub fn get(self: Assets, comptime AssetT: type) *Cache(AssetT) {
        if (self.caches.getValue(utils.typeId(AssetT))) |tid| {
            return @intToPtr(*Cache(AssetT), tid);
        }
        unreachable;
    }

    pub fn load(self: Assets, comptime AssetT: type, comptime LoaderT: type, args: LoaderT.LoadArgs) *AssetT {
        var cache = self.get(AssetT);
        return cache.load(666, LoaderT, args);
    }
};

test "assets" {
    const Thing = struct {
        fart: i32,
        pub fn deinit(self: *@This()) void {
            std.testing.allocator.destroy(self);
        }
    };

    const ThingLoader = struct {
        pub const LoadArgs = struct {};
        pub fn load(self: @This(), args: var) *Thing {
            return std.testing.allocator.create(Thing) catch unreachable;
        }
    };

    const OtherThing = struct {
        fart: i32,
        pub fn deinit(self: *@This()) void {
            std.testing.allocator.destroy(self);
        }
    };

    const OtherThingLoader = struct {
        pub const LoadArgs = struct {};
        pub fn load(self: @This(), args: var) *OtherThing {
            return std.testing.allocator.create(OtherThing) catch unreachable;
        }
    };

    var assets = Assets.init(std.testing.allocator);
    defer assets.deinit();

    var cache = assets.registerCache(Thing, ThingLoader);
    var thing = assets.get(Thing).load(6, ThingLoader, ThingLoader.LoadArgs{});
    std.testing.expectEqual(cache.size(), 1);

    var thing2 = assets.load(Thing, ThingLoader, ThingLoader.LoadArgs{});
    std.testing.expectEqual(cache.size(), 2);
}
