const std = @import("std");
const Dispatcher = @import("ecs").Dispatcher;

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param);
}

fn tester2(param: i32) void {
    std.testing.expectEqual(@as(i32, -543), param);
}

const Thing = struct {
    field: f32 = 0,

    pub fn testU32(self: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 666), param);
    }

    pub fn testI32(self: *Thing, param: i32) void {
        std.testing.expectEqual(@as(i32, -543), param);
    }
};

test "Dispatcher" {
    var thing = Thing{};

    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var sink = d.sink(u32);
    sink.connect(tester);
    sink.connectBound(&thing, "testU32");
    d.trigger(u32, 666);

    var sink2 = d.sink(i32);
    sink2.connect(tester2);
    sink2.connectBound(&thing, "testI32");
    d.trigger(i32, -543);
}
