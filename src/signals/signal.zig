const std = @import("std");
const Sink = @import("sink.zig").SinkFromTuple;
const Delegate = @import("delegate.zig").DelegateFromTuple;
const Tuple = @import("delegate.zig").Tuple;

pub fn Signal(comptime Params: anytype) type {
  return SignalFromTuple(Tuple(Params));
}

pub fn SignalFromTuple(comptime Params: type) type {
    return struct {
        const Self = @This();

        calls: std.ArrayList(Delegate(Params)),
        allocator: ?std.mem.Allocator = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            // we purposely do not store the allocator locally in this case so we know not to destroy ourself in deint!
            return Self{
                .calls = std.ArrayList(Delegate(Params)).init(allocator),
            };
        }

        /// heap allocates a Signal
        pub fn create(allocator: std.mem.Allocator) *Self {
            var signal = allocator.create(Self) catch unreachable;
            signal.calls = std.ArrayList(Delegate(Params)).init(allocator);
            signal.allocator = allocator;
            return signal;
        }

        pub fn deinit(self: *Self) void {
            self.calls.deinit();

            // optionally destroy ourself as well if we came from an allocator
            if (self.allocator) |allocator| allocator.destroy(self);
        }

        pub fn size(self: Self) usize {
            return self.calls.items.len;
        }

        pub fn empty(self: Self) bool {
            return self.size == 0;
        }

        /// Disconnects all the listeners from a signal
        pub fn clear(self: *Self) void {
            self.calls.items.len = 0;
        }

        pub fn publish(self: Self, arg: Params) void {
            for (self.calls.items) |call| {
                call.trigger(arg);
            }
        }

        /// Constructs a sink that is allowed to modify a given signal
        pub fn sink(self: *Self) Sink(Params) {
            return Sink(Params).init(self);
        }
    };
}

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
}

const Thing = struct {
    field: f32 = 0,

    pub fn tester(_: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
    }
};

test "Signal/Sink" {
    var signal = Signal(.{u32}).init(std.testing.allocator);
    defer signal.deinit();

    var sink = signal.sink();
    sink.connect(tester);
    try std.testing.expectEqual(@as(usize, 1), signal.size());

    // bound listener
    var thing = Thing{};
    sink.connectBound(&thing, Thing.tester);

    signal.publish(.{666});

    sink.disconnect(tester);
    signal.publish(.{666});
    try std.testing.expectEqual(@as(usize, 1), signal.size());

    sink.disconnectBound(&thing);
    try std.testing.expectEqual(@as(usize, 0), signal.size());
}

test "Sink Before null" {
    var signal = Signal(.{u32}).init(std.testing.allocator);
    defer signal.deinit();

    var sink = signal.sink();
    sink.connect(tester);
    try std.testing.expectEqual(@as(usize, 1), signal.size());

    var thing = Thing{};
    sink.before(null).connectBound(&thing, Thing.tester);
    try std.testing.expectEqual(@as(usize, 2), signal.size());
}
