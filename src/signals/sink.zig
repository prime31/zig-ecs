const std = @import("std");
const Signal = @import("signal.zig").Signal;
const Delegate = @import("delegate.zig").Delegate;

/// helper used to connect and disconnect listeners on the fly from a Signal. Listeners are wrapped in Delegates
/// and can be either free functions or functions bound to a struct.
pub fn Sink(comptime Event: type) type {
    return struct {
        const Self = @This();

        insert_index: usize,

        /// the Signal this Sink is temporarily wrapping
        var owning_signal: *Signal(Event) = undefined;

        pub fn init(signal: *Signal(Event)) Self {
            owning_signal = signal;
            return Self{ .insert_index = owning_signal.calls.items.len };
        }

        pub fn before(self: Self, callback: ?*const fn (Event) void) Self {
            if (callback) |cb| {
                if (self.indexOf(cb)) |index| {
                    return Self{ .insert_index = index };
                }
            }
            return self;
        }

        pub fn beforeBound(self: Self, ctx: anytype) Self {
            if (@typeInfo(@TypeOf(ctx)) == .Pointer) {
                if (self.indexOfBound(ctx)) |index| {
                    return Self{ .insert_index = index };
                }
            }
            return self;
        }

        /// connects a callback `fn(Event) void` to this sink
        /// NOTE: each callback can only be connected ONCE to the same sink
        pub fn connect(self: Self, callback: *const fn (Event) void) void {
            std.debug.assert(self.indexOf(callback) == null);
            _ = owning_signal.calls.insert(self.insert_index, Delegate(Event).initFree(callback)) catch unreachable;
        }

        /// connects a context `fn ctx.fn_name(Event) void` to this sink
        /// NOTE: each context can only be connected ONCE to the same sink
        pub fn connectBound(self: Self, ctx: anytype, comptime fn_name: []const u8) void {
            std.debug.assert(self.indexOfBound(ctx) == null);
            _ = owning_signal.calls.insert(self.insert_index, Delegate(Event).initBound(ctx, fn_name)) catch unreachable;
        }

        pub fn disconnect(self: Self, callback: *const fn (Event) void) void {
            if (self.indexOf(callback)) |index| {
                _ = owning_signal.calls.swapRemove(index);
            }
        }

        pub fn disconnectBound(self: Self, ctx: anytype) void {
            if (self.indexOfBound(ctx)) |index| {
                _ = owning_signal.calls.swapRemove(index);
            }
        }

        fn indexOf(_: Self, callback: *const fn (Event) void) ?usize {
            for (owning_signal.calls.items, 0..) |call, i| {
                if (call.containsFree(callback)) {
                    return i;
                }
            }
            return null;
        }

        fn indexOfBound(_: Self, ctx: anytype) ?usize {
            for (owning_signal.calls.items, 0..) |call, i| {
                if (call.containsBound(ctx)) {
                    return i;
                }
            }
            return null;
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

test "Sink Before free" {
    var signal = Signal(u32).init(std.testing.allocator);
    defer signal.deinit();

    signal.sink().connect(tester);
    try std.testing.expectEqual(signal.sink().indexOf(tester).?, 0);

    var thing = Thing{};
    signal.sink().before(tester).connectBound(&thing, "tester");
    try std.testing.expectEqual(signal.sink().indexOfBound(&thing).?, 0);
}

test "Sink Before bound" {
    var signal = Signal(u32).init(std.testing.allocator);
    defer signal.deinit();

    var thing = Thing{};
    signal.sink().connectBound(&thing, "tester");
    try std.testing.expectEqual(signal.sink().indexOfBound(&thing).?, 0);

    signal.sink().beforeBound(&thing).connect(tester);
    try std.testing.expectEqual(signal.sink().indexOf(tester).?, 0);
}
