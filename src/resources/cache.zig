const std = @import("std");
const ErasedPtr = @import("../ecs/utils.zig").ErasedPtr;

/// Simple cache for resources of a given type. TLoader should be a struct that implements a single
/// method: load(args: var) *T. If any resource has a deinit method it will be called when clear
/// or remove is called.
pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        safe_deinit: fn (*@This()) void,
        resources: std.AutoHashMap(u16, *T),
        loader: ErasedPtr,
        allocator: ?*std.mem.Allocator = null,

        pub fn initPtr(allocator: *std.mem.Allocator, comptime LoaderT: type) *@This() {
            const ptr = if (@sizeOf(LoaderT) > 0)
                ErasedPtr.init(allocator.create(LoaderT) catch unreachable)
            else
                ErasedPtr.init(LoaderT);

            var cache = allocator.create(@This()) catch unreachable;
            cache.safe_deinit = struct {
                fn deinit(self: *Self) void {
                    self.clear();
                    self.resources.deinit();
                    self.allocator.?.destroy(self);
                }
            }.deinit;
            cache.loader = ptr;
            cache.resources = std.AutoHashMap(u16, *T).init(allocator);
            cache.allocator = allocator;
            return cache;
        }

        pub fn init(allocator: *std.mem.Allocator, comptime LoaderT: type) @This() {
            const ptr = if (@sizeOf(LoaderT) > 0)
                ErasedPtr.init(std.testing.allocator.create(LoaderT) catch unreachable)
            else
                ErasedPtr.init(LoaderT);

            return .{
                .safe_deinit = struct {
                    fn deinit(self: *Self) void {
                        self.clear();
                        self.resources.deinit();
                    }
                }.deinit,
                .loader = ptr,
                .resources = std.AutoHashMap(u16, *T).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.safe_deinit(self);
        }

        fn load(self: *@This(), id: u16, comptime LoaderT: type, args: LoaderT.LoadArgs) *T {
            if (self.resources.getValue(id)) |resource| {
                return resource;
            }

            var resource = self.loader.as(LoaderT).load(args);
            _ = self.resources.put(id, resource) catch unreachable;
            return resource;
        }

        pub fn contains(self: *@This(), id: u16) bool {
            return self.resources.contains(id);
        }

        pub fn remove(self: *@This(), id: u16) void {
            if (self.resources.remove(id)) |kv| {
                if (@hasDecl(T, "deinit")) {
                    @call(.{ .modifier = .always_inline }, @field(kv.value, "deinit"), .{});
                }
            }
        }

        pub fn clear(self: *@This()) void {
            // optionally deinit any resources that have a deinit method
            if (@hasDecl(T, "deinit")) {
                var iter = self.resources.iterator();
                while (iter.next()) |kv| {
                    @call(.{ .modifier = .always_inline }, @field(kv.value, "deinit"), .{});
                }
            }
            self.resources.clear();
        }

        pub fn size(self: @This()) usize {
            return self.resources.size;
        }
    };
}

test "cache" {
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

    var cache = Cache(Thing).init(std.testing.allocator, ThingLoader);
    defer cache.deinit();

    var thing = cache.load(6, ThingLoader, ThingLoader.LoadArgs{});
    var thing2 = cache.load(2, ThingLoader, ThingLoader.LoadArgs{});
    std.testing.expectEqual(cache.size(), 2);

    cache.remove(2);
    std.testing.expectEqual(cache.size(), 1);

    cache.clear();
    std.testing.expectEqual(cache.size(), 0);
}
