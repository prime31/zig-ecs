const std = @import("std");
const Dispatcher = @import("ecs").Dispatcher;

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
}

fn tester2(param: i32) void {
    std.testing.expectEqual(@as(i32, -543), param) catch unreachable;
}

const Thing = struct {
    field: f32 = 0,

    pub fn testU32(_: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
    }

    pub fn testI32(_: *Thing, param: i32) void {
        std.testing.expectEqual(@as(i32, -543), param) catch unreachable;
    }
};

test "Dispatcher" {
    var thing = Thing{};

    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var sink = d.sink(.{u32});
    sink.connect(tester);
    sink.connectBound(&thing, Thing.testU32);
    d.trigger(.{u32}, .{666});

    var sink2 = d.sink(.{i32});
    sink2.connect(tester2);
    sink2.connectBound(&thing, Thing.testI32);
    d.trigger(.{i32}, .{-543});
}
