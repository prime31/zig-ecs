const std = @import("std");
const ErasedPtr = @import("../ecs/utils.zig").ErasedPtr;

/// Simple cache for resources of a given type. If any resource has a deinit method it will be called when clear
/// or remove is called. Implementing a "loader" which is passed to "load" is a struct with one method:
/// - load(self: @This()) *T.
pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        safe_deinit: *const fn (*Self) void,
        resources: std.AutoHashMapUnmanaged(u32, *T),
        allocator: std.mem.Allocator,

        pub fn create(allocator: std.mem.Allocator) *Self {
            const cache = allocator.create(Self) catch unreachable;
            cache.* = Self.init(allocator);
            return cache;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .safe_deinit = struct {
                    fn deinit(self: *Self) void {
                        self.clear();
                        self.resources.deinit(self.allocator);
                    }
                }.deinit,
                .resources = std.AutoHashMapUnmanaged(u32, *T){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.safe_deinit(self);
        }

        pub fn load(self: *Self, id: u32, comptime loader: anytype) @typeInfo(@typeInfo(@TypeOf(@field(loader, "load"))).pointer.child).@"fn".return_type.? {
            if (self.resources.get(id)) |resource| {
                return resource;
            }

            const resource = loader.load(loader);
            _ = self.resources.put(self.allocator, id, resource) catch unreachable;
            return resource;
        }

        pub fn contains(self: *Self, id: u32) bool {
            return self.resources.contains(id);
        }

        pub fn remove(self: *Self, id: u32) void {
            if (self.resources.fetchRemove(id)) |kv| {
                if (@hasDecl(T, "deinit")) {
                    @call(.always_inline, T.deinit, .{kv.value});
                }
            }
        }

        pub fn clear(self: *Self) void {
            // optionally deinit any resources that have a deinit method
            if (@hasDecl(T, "deinit")) {
                var iter = self.resources.iterator();
                while (iter.next()) |kv| {
                    @call(.always_inline, T.deinit, .{kv.value_ptr.*});
                }
            }
            self.resources.clearAndFree(self.allocator);
        }

        pub fn size(self: Self) usize {
            return self.resources.count();
        }
    };
}

test "cache" {
    const utils = @import("../ecs/utils.zig");

    const Thing = struct {
        fart: i32,
        pub fn deinit(self: *@This()) void {
            std.testing.allocator.destroy(self);
        }
    };

    const ThingLoadArgs = struct {
        // Use actual field "load" as function pointer to avoid zig v0.10.0
        // compiler error: "error: no field named 'load' in struct '...'"
        load: *const fn (self: @This()) *Thing,
        pub fn loadFn(self: @This()) *Thing {
            _ = self;
            return std.testing.allocator.create(Thing) catch unreachable;
        }
    };

    var cache = Cache(Thing).init(std.testing.allocator);
    defer cache.deinit();

    _ = cache.load(utils.hashString("my/id"), ThingLoadArgs{ .load = ThingLoadArgs.loadFn });
    _ = cache.load(utils.hashString("another/id"), ThingLoadArgs{ .load = ThingLoadArgs.loadFn });
    try std.testing.expectEqual(cache.size(), 2);

    cache.remove(utils.hashString("my/id"));
    try std.testing.expectEqual(cache.size(), 1);

    cache.clear();
    try std.testing.expectEqual(cache.size(), 0);
}
