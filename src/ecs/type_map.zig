const std = @import("std");
const utils = @import("utils.zig");

pub const TypeMap = struct {
    map: std.AutoHashMap(u32, u8),
    counter: u8 = 0,

    pub fn init(allocator: *std.mem.Allocator) TypeMap {
        return TypeMap{
            .map = std.AutoHashMap(u32, u8).init(allocator),
        };
    }

    pub fn deinit(self: TypeMap) void {
        self.map.deinit();
    }

    pub fn contains(self: TypeMap, comptime T: type) bool {
        return self.map.contains(@truncate(u32, utils.typeHash(T)));
    }

    /// gets the value for T. It MUST exist if you use this method to get it.
    pub fn get(self: *TypeMap, comptime T: type) u8 {
        return self.map.get(@truncate(u32, utils.typeHash(T))).?.value;
    }

    /// gets the value for T if it exists. If it doesnt, it is registered and the value returned.
    pub fn getOrPut(self: *TypeMap, comptime T: type, type_id: *u8) bool {
        // TODO: is it safe to truncate to u32 here?
        var res = self.map.getOrPut(@truncate(u32, utils.typeHash(T))) catch unreachable;
        if (!res.found_existing) {
            res.kv.value = self.counter;
            self.counter += 1;
        }
        type_id.* = res.kv.value;
        return res.found_existing;
    }
};

test "TypeMap" {
    var map = TypeMap.init(std.testing.allocator);
    defer map.deinit();

    var type_id: u8 = undefined;
    _ = map.getOrPut(usize, &type_id);
    std.testing.expectEqual(@as(u8, 0), type_id);

    _ = map.getOrPut(f32, &type_id);
    std.testing.expectEqual(@as(u8, 1), type_id);

    _ = map.getOrPut(usize, &type_id);
    std.testing.expectEqual(@as(u8, 0), type_id);
}
